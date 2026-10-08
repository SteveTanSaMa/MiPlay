// WineVersionManagerCatalog.swift
// MiPlay

import Foundation

// Source: Architecture Design -> ADR 037 -> fixed catalog entry
extension WineVersionManager {
    // MARK: - 获取可用版本列表

    /// Reads and validates the single product-approved catalog entry.
    public func fetchAvailableVersions() async throws -> [WineVersionInfo] {
        // Source: QA Report → F-003 — 60 分钟内存缓存
        if let cached = cachedVersions, let timestamp = cacheTimestamp {
            let elapsed = Date().timeIntervalSince(timestamp)
            if elapsed < 3600 {
                return cached
            }
        }

        guard let source = BuiltInWineVersions.sourceDescriptor(for: BuiltInWineVersions.officialSource.sourceID) else {
            throw VersionManagerError.sourceInvalid("缺少固定 Wine 来源")
        }
        let operationID = UUID()
        await logWriter.record(.init(
            level: .info,
            module: "WineVersionManager",
            eventName: "wine.catalog.request",
            operationID: operationID,
            phase: "request",
            result: "inProgress",
            messageCode: "wine.catalog.refresh_started",
            fields: ["sourceID": source.sourceID, "policyRevision": source.policyRevision]
        ))

        do {
            let releases: [GitHubRelease] = try await networkProvider.request(
                [GitHubRelease].self,
                from: source.apiEndpoint,
                additionalHeaders: nil
            )

            let versionsDir = await wineVersionsDirectory()
            let versions = releases.compactMap { release -> WineVersionInfo? in
                guard release.tagName == Self.fixedRuntimeTag else { return nil }
                guard let asset = release.assets.first(where: {
                    $0.name.hasSuffix(".tar.xz") && source.supportsAssetName($0.name)
                }) else { return nil }

                guard let downloadURL = URL(string: asset.browserDownloadURL) else { return nil }
                guard downloadURL.scheme == "https",
                      downloadURL.host == source.allowedAssetHost,
                      downloadURL.path.hasPrefix(source.allowedAssetPathPrefix) else { return nil }

                let isoFormatter = ISO8601DateFormatter()
                let publishedDate = isoFormatter.date(from: release.publishedAt) ?? Date()

                let versionDir = versionsDir.appendingPathComponent(release.tagName)
                let isDownloaded = FileManager.default.fileExists(atPath: versionDir.path)

                return WineVersionInfo(
                    id: release.tagName,
                    tagName: release.tagName,
                    name: release.name.isEmpty ? release.tagName : release.name,
                    downloadURL: downloadURL,
                    fileSize: asset.size,
                    publishedAt: publishedDate,
                    sourceID: source.sourceID,
                    policyRevision: source.policyRevision,
                    assetName: asset.name,
                    isDownloaded: isDownloaded,
                    isSelected: runtimeRecord?.identity == release.tagName
                )
            }

            // 更新缓存
            cachedVersions = versions
            cacheTimestamp = Date()

            await logWriter.record(.init(
                level: .info,
                module: "WineVersionManager",
                eventName: "wine.catalog.response",
                operationID: operationID,
                phase: "response",
                result: versions.isEmpty ? "unavailable" : "completed",
                errorCategory: versions.isEmpty ? "resourceNotFound" : "none",
                messageCode: versions.isEmpty ? "wine.catalog.empty" : "wine.catalog.refresh_completed",
                fields: ["sourceID": source.sourceID, "policyRevision": source.policyRevision, "itemCount": String(versions.count)]
            ))

            return versions
        } catch let error as VersionManagerError {
            throw error
        } catch let error as NetworkDownloadProvider.NetworkError {
            if case .httpError(let statusCode, let message) = error, statusCode == 403 {
                await logWriter.record(.init(
                    level: .error,
                    module: "WineVersionManager",
                    eventName: "wine.catalog.response",
                    operationID: operationID,
                    phase: "response",
                    result: "failed",
                    errorCategory: "apiForbidden",
                    messageCode: "wine.catalog.forbidden",
                    fields: ["sourceID": source.sourceID, "statusCode": "403"]
                ))
                throw VersionManagerError.apiForbidden(sourceID: source.sourceID, detail: message)
            }
            if case .httpError(let statusCode, _) = error, statusCode == 429 {
                await logWriter.record(.init(
                    level: .warning,
                    module: "WineVersionManager",
                    eventName: "wine.catalog.response",
                    operationID: operationID,
                    phase: "response",
                    result: "failed",
                    errorCategory: "rateLimited",
                    messageCode: "wine.catalog.rate_limited",
                    fields: ["sourceID": source.sourceID, "statusCode": "429"]
                ))
                throw VersionManagerError.rateLimited(retryAfter: 60)
            }
            await logWriter.record(.init(
                level: .error,
                module: "WineVersionManager",
                eventName: "wine.catalog.response",
                operationID: operationID,
                phase: "response",
                result: "failed",
                errorCategory: "networkUnavailable",
                messageCode: "wine.catalog.request_failed",
                fields: ["sourceID": source.sourceID]
            ))
            throw VersionManagerError.apiUnavailable(error.localizedDescription)
        } catch {
            await logWriter.record(.init(
                level: .error,
                module: "WineVersionManager",
                eventName: "wine.catalog.response",
                operationID: operationID,
                phase: "response",
                result: "failed",
                errorCategory: "networkUnavailable",
                messageCode: "wine.catalog.request_failed",
                fields: ["sourceID": source.sourceID]
            ))
            throw VersionManagerError.apiUnavailable(error.localizedDescription)
        }
    }

    /// 获取可用版本列表（优先缓存，不抛出错误）
    public func getAvailableVersions() async -> [WineVersionInfo] {
        do {
            return try await fetchAvailableVersions()
        } catch {
            await logWriter.error("获取 Wine 版本列表失败: \(error.localizedDescription)", module: "WineVersionManager")
            return cachedVersions ?? []
        }
    }

    /// Returns an entry from the last policy-validated catalog.
    /// Downloads must be initiated by the scheduler after a catalog query;
    /// this accessor intentionally never performs network I/O.
    public func cachedAvailableVersion(tagName: String) -> WineVersionInfo? {
        cachedVersions?.first { $0.tagName == tagName }
    }

    /// Returns the last policy-validated catalog without initiating I/O.
    public func cachedAvailableVersions() -> [WineVersionInfo] {
        cachedVersions ?? []
    }

    /// Clears only in-memory catalog metadata. It never deletes a runtime,
    /// prefix, or cache file.
    public func clearCatalogCache() {
        cachedVersions = nil
        cacheTimestamp = nil
    }

    // MARK: - 版本选中

    /// Compatibility entry point. The fixed runtime has no selectable version;
    /// this succeeds only when the fixed runtime is already installed.
    public func selectVersion(tagName: String) async throws {
        guard tagName == Self.fixedRuntimeTag else {
            throw VersionManagerError.versionNotFound(tagName)
        }
        guard runtimeRecord != nil else {
            throw VersionManagerError.versionNotFound("固定 Wine 尚未安装")
        }
        selectedVersionTag = tagName
    }

    public func globalWineVersion() -> String? {
        runtimeRecord?.identity
    }

    /// 获取当前选中的全局版本标识（无 Game 上下文语义）。
    public func getSelectedVersionTag() -> String? {
        runtimeRecord?.identity
    }

    public func wineVersionOverride(for gameID: String) -> String? {
        nil
    }

    /// Resolves every game to the same fixed runtime. Legacy overrides are
    /// intentionally ignored, including values decoded from older AppData.
    public func effectiveVersion(for gameID: String) -> String? {
        _ = gameID
        return globalWineVersion()
    }

    /// The per-game Wine product path was removed. Keep this compatibility seam
    /// explicit so old callers cannot silently reintroduce it.
    public func setWineVersionOverride(gameID: String, tagName: String) async throws {
        _ = gameID
        _ = tagName
        throw VersionManagerError.sourceInvalid("按游戏选择 Wine 已移除")
    }

    /// Removes only the target Game's override so it falls back to global.
    public func removeWineVersionOverride(gameID: String) async throws {
        _ = gameID
    }

    public func selectVersion(tagName: String, for gameID: String) async throws {
        try await setWineVersionOverride(gameID: gameID, tagName: tagName)
    }

    public func getSelectedSourceID() -> String {
        selectedSourceID
    }

    public func availableSourceDescriptors() -> [BuiltInWineVersions.SourceDescriptor] {
        [BuiltInWineVersions.officialSource]
    }

    /// Source selection was removed. The fixed approved source is the only
    /// accepted value and changing it is never persisted.
    public func selectSource(sourceID: String) async throws {
        guard sourceID == BuiltInWineVersions.officialSource.sourceID else {
            throw VersionManagerError.sourceInvalid("Wine 来源选择已移除")
        }
    }

    // MARK: - 版本就绪检查

    /// Checks the managed runtime itself. A game-specific WineReady result is
    /// produced by `checkReadiness(for:)`, which also requires an existing
    /// verified prefix. This method intentionally has no side effects.
}
