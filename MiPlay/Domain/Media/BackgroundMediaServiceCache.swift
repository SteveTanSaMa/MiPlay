// BackgroundMediaServiceCache.swift
// MiPlay

@preconcurrency import Foundation

// Source: Architecture Design -> ADR 012 -> cache helpers
extension BackgroundMediaService {
    // MARK: - ADR-019 Content-Addressable Cache Helpers

    /// Derived cache identity for one API response collection. It contains
    /// source identity, group order, and per-group resource identity. It never
    /// contains the selected group ID or hover preview state.
    internal struct BackgroundCollectionFingerprint: Codable, Sendable, Equatable {
        let sourceID: String
        let groups: [BackgroundGroupFingerprint]
    }

    internal struct BackgroundGroupFingerprint: Codable, Sendable, Equatable {
        let groupID: String
        let type: String?
        let version: String?
        let backgroundIdentity: String?
        let videoIdentity: String?
        let themeIdentity: String?
        let iconIdentity: String?
        let iconHoverIdentity: String?
        /// Missing in cache metadata written before icon retention existed.
        let iconMetadataKnown: Bool?

        init(groupID: String, type: String?, version: String?, backgroundIdentity: String?,
             videoIdentity: String?, themeIdentity: String?, iconIdentity: String? = nil,
             iconHoverIdentity: String? = nil, iconMetadataKnown: Bool? = nil) {
            self.groupID = groupID
            self.type = type
            self.version = version
            self.backgroundIdentity = backgroundIdentity
            self.videoIdentity = videoIdentity
            self.themeIdentity = themeIdentity
            self.iconIdentity = iconIdentity
            self.iconHoverIdentity = iconHoverIdentity
            self.iconMetadataKnown = iconMetadataKnown
        }

        /// Do not archive or erase valid old assets solely because an older
        /// cache format could not record the newly retained icon fields.
        func matchesCurrent(_ current: BackgroundGroupFingerprint) -> Bool {
            guard groupID == current.groupID, type == current.type, version == current.version,
                  backgroundIdentity == current.backgroundIdentity, videoIdentity == current.videoIdentity,
                  themeIdentity == current.themeIdentity else { return false }
            guard iconMetadataKnown == true else { return true }
            return iconIdentity == current.iconIdentity && iconHoverIdentity == current.iconHoverIdentity
        }
    }

    internal func collectionFingerprint(
        from backgrounds: [HoyoPlayBackground],
        sourceID: String
    ) -> BackgroundCollectionFingerprint {
        BackgroundCollectionFingerprint(
            sourceID: sourceID,
            groups: backgrounds.map(backgroundGroupFingerprint)
        )
    }

    internal func backgroundGroupFingerprint(
        _ background: HoyoPlayBackground
    ) -> BackgroundGroupFingerprint {
        BackgroundGroupFingerprint(
            groupID: background.id,
            type: background.type,
            version: background.id,
            backgroundIdentity: background.background?.url,
            videoIdentity: background.video?.url,
            themeIdentity: background.theme?.url,
            iconIdentity: background.icon?.url,
            iconHoverIdentity: background.icon?.hoverURL,
            iconMetadataKnown: true
        )
    }

    /// Persists the fingerprint in the media cache directory. AppData keeps
    /// only the user's selected group ID.
    internal func persistCollectionFingerprint(
        _ fingerprint: BackgroundCollectionFingerprint,
        for gameId: String
    ) async {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let data = try? encoder.encode(fingerprint) else { return }
        _ = try? await mediaCacheManager.writeCacheMetadata(
            data,
            forGameId: gameId,
            filename: ".background-fingerprint.json"
        )
    }

    /// Reads the persisted fingerprint. Any read or decode failure is treated
    /// as "unknown collection": no destructive cleanup is allowed.
    internal func loadPersistedCollectionFingerprint(
        for gameId: String
    ) async -> BackgroundCollectionFingerprint? {
        guard let data = try? await mediaCacheManager.readCacheMetadata(
            forGameId: gameId,
            filename: ".background-fingerprint.json"
        ) else { return nil }
        return try? JSONDecoder().decode(BackgroundCollectionFingerprint.self, from: data)
    }

    /// 每组单独保存身份，防止背景组退出 API 集合后再次出现时复用过时文件。
    internal func persistGroupFingerprint(
        _ fingerprint: BackgroundGroupFingerprint,
        for gameId: String
    ) async throws {
        let data = try JSONEncoder().encode(fingerprint)
        try await mediaCacheManager.writeCacheMetadata(
            data,
            forGameId: "\(gameId)/\(fingerprint.groupID)",
            filename: ".background-group.json"
        )
    }

    internal func loadGroupFingerprint(
        for gameId: String,
        backgroundId: String
    ) async -> BackgroundGroupFingerprint? {
        guard let data = try? await mediaCacheManager.readCacheMetadata(
            forGameId: "\(gameId)/\(backgroundId)",
            filename: ".background-group.json"
        ) else { return nil }
        guard let fingerprint = try? JSONDecoder().decode(BackgroundGroupFingerprint.self, from: data),
              fingerprint.groupID == backgroundId else { return nil }
        return fingerprint
    }

    /// 保留退出集合的背景组；同组资源更新时先归档，避免新下载覆盖旧文件。
    /// 关闭保留时每次加载都检查过时文件，包括集合指纹未变化的情况。
    internal func reconcileBackgroundCache(
        gameId: String,
        currentBackgrounds: [HoyoPlayBackground],
        persisted: BackgroundCollectionFingerprint?
    ) async throws {
        let currentByID = Dictionary(
            currentBackgrounds.map { ($0.id, backgroundGroupFingerprint($0)) },
            uniquingKeysWith: { first, _ in first }
        )
        let persistedByID = Dictionary(
            (persisted?.groups ?? []).map { ($0.groupID, $0) },
            uniquingKeysWith: { first, _ in first }
        )
        let retainOutdated = retainsOutdatedBackgrounds(for: gameId)
        let groupNames = try await mediaCacheManager.groupDirectoryNames(forGameId: gameId)
        for name in groupNames {
            let stored = await loadGroupFingerprint(for: gameId, backgroundId: name)
            let old = stored ?? persistedByID[name]
            if let current = currentByID[name] {
                if let old, !old.matchesCurrent(current) {
                    if retainOutdated {
                        try await persistGroupFingerprint(old, for: gameId)
                        try await mediaCacheManager.archiveCache(forGameId: gameId, backgroundId: name)
                    } else {
                        try await mediaCacheManager.clearCache(forGameId: gameId, backgroundId: name)
                    }
                    await logWriter.info(
                        "\(retainOutdated ? "归档" : "清除")已更新的背景缓存: \(gameId)/\(name)",
                        module: "BackgroundMediaService"
                    )
                }
                try await persistGroupFingerprint(current, for: gameId)
            } else if retainOutdated {
                // 把旧集合身份迁移到组内，后续集合指纹不再包含该组时仍可校验。
                if let old { try await persistGroupFingerprint(old, for: gameId) }
            } else if persisted != nil {
                try await mediaCacheManager.clearCache(forGameId: gameId, backgroundId: name)
                await logWriter.info(
                    "清除过时背景缓存: \(gameId)/\(name)",
                    module: "BackgroundMediaService"
                )
            }
        }

        // 缺少可信集合指纹时保留未知缓存，沿用原有恢复策略。
        if !retainOutdated, persisted != nil {
            try await mediaCacheManager.clearArchivedCache(forGameId: gameId)
        }
        if let selected = resolveCurrentBackground(from: currentBackgrounds),
           !groupNames.contains(selected.id) {
            try await persistGroupFingerprint(backgroundGroupFingerprint(selected), for: gameId)
        }
    }

    /// 检查指定背景 ID 的所有缓存文件是否完整
    internal func allCacheFilesExist(for gameId: String, backgroundId: String) async -> Bool {
        let subdir = "\(gameId)/\(backgroundId)"
        // 动态模式需要 video.mp4 + background.png + theme.png
        // 静态模式只需 background.png
        let mode = backgroundModes[gameId] ?? .dynamic
        switch mode {
        case .dynamic:
            let hasVideo = await hasSubCache(for: gameId, backgroundId: backgroundId, type: .video, ext: "mp4")
            let hasBg = await mediaCacheManager.hasCachedFile(for: subdir + "/background.png")
            return hasVideo && hasBg
        case .static:
            return await mediaCacheManager.hasCachedFile(for: subdir + "/background.png")
        case .custom:
            return false
        }
    }

    /// ADR-019: 基于子目录的缓存路径 MediaCache/{gameId}/{backgroundId}/{type}.ext
    internal func cacheURL(gameId: String, backgroundId: String, type: AssetType, ext: String) async -> URL {
        let subdirectory = "\(gameId)/\(backgroundId)"
        let filename = "\(type.rawValue).\(ext)"
        return await mediaCacheManager.cachedFileURL(forKey: filename, inDirectory: subdirectory)
    }

    /// ADR-019: 检查子目录缓存文件是否存在
    /// 0 字节文件视为无效（中断写入可能留下空文件），必须重新获取
    internal func hasSubCache(for gameId: String, backgroundId: String, type: AssetType, ext: String) async -> Bool {
        let subdirectory = "\(gameId)/\(backgroundId)"
        let filename = "\(type.rawValue).\(ext)"
        let url = await mediaCacheManager.cachedFileURL(forKey: filename, inDirectory: subdirectory)
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = attributes?[.size] as? Int64 ?? 0
        guard size > 0 else { return false }
        if type == .video, ext == "mp4" {
            let marker = await Task.detached(priority: .utility) {
                try? String(contentsOfFile: url.path + ".quality", encoding: .utf8)
            }.value
            return marker == MediaTranscoder.videoQualityProfile
        }
        return true
    }

    /// 旧版扁平缓存键（向下兼容读已有缓存）
    internal func cacheKey(gameId: String, type: AssetType, ext: String) -> String {
        return "\(gameId)_\(type.rawValue).\(ext)"
    }

}
