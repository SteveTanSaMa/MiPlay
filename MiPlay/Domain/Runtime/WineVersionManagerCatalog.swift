// WineVersionManagerCatalog.swift
// MiPlay

import Foundation

// Source: Architecture Design -> WineVersionManager -> catalog and source selection
extension WineVersionManager {
    // MARK: - 获取可用版本列表

    /// 从当前用户选择的、产品批准来源获取目录。
    /// API/Release metadata 失败不会切换来源，也不会改变已安装运行时。
    public func fetchAvailableVersions() async throws -> [WineVersionInfo] {
        // Source: QA Report → F-003 — 60 分钟内存缓存
        if let cached = cachedVersions, let timestamp = cacheTimestamp {
            let elapsed = Date().timeIntervalSince(timestamp)
            if elapsed < 3600 {
                return cached
            }
        }

        guard let source = BuiltInWineVersions.sourceDescriptor(for: selectedSourceID) else {
            throw VersionManagerError.sourceInvalid(selectedSourceID)
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
                guard Self.managedWineTags.contains(release.tagName) else { return nil }
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
                    isSelected: selectedVersionTag == release.tagName
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

    // MARK: - 版本选中

    /// 选中指定版本为当前生效版本
    /// - Parameter tagName: 版本标签名
    public func selectVersion(tagName: String) async throws {
        guard Self.managedWineTags.contains(tagName) else {
            throw VersionManagerError.versionNotFound(tagName)
        }
        guard installedVersionTags.contains(tagName) else {
            throw VersionManagerError.versionNotFound(tagName)
        }

        selectedVersionTag = tagName
        var appData = try await persistenceStore.readAppData()
        appData.selectedWineVersion = tagName
        try await persistenceStore.writeAppData(appData)
        await logWriter.info("Wine 版本已选中: \(tagName)", module: "WineVersionManager")
    }

    /// 获取当前选中的版本标识
    public func getSelectedVersionTag() -> String? {
        return selectedVersionTag
    }

    public func getSelectedSourceID() -> String {
        selectedSourceID
    }

    public func availableSourceDescriptors() -> [BuiltInWineVersions.SourceDescriptor] {
        BuiltInWineVersions.approvedSources
    }

    /// Changes only the source identity. The previous source remains active if
    /// persistence or policy validation fails.
    public func selectSource(sourceID: String) async throws {
        guard let source = BuiltInWineVersions.sourceDescriptor(for: sourceID) else {
            throw VersionManagerError.sourceInvalid(sourceID)
        }
        let previous = selectedSourceID
        do {
            var appData = try await persistenceStore.readAppData()
            appData.selectedWineSource = source.sourceID
            try await persistenceStore.writeAppData(appData)
            let verified = try await persistenceStore.readAppData()
            guard verified.selectedWineSource == source.sourceID else {
                throw VersionManagerError.persistenceFailed("Wine 来源写回后重读不一致")
            }
            selectedSourceID = source.sourceID
            cachedVersions = nil
            cacheTimestamp = nil
        } catch {
            selectedSourceID = previous
            throw error
        }
    }

    // MARK: - 版本就绪检查

    /// Checks the managed runtime itself. A game-specific WineReady result is
    /// produced by `checkReadiness(for:)`, which also requires an existing
    /// verified prefix. This method intentionally has no side effects.
}
