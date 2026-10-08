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
            themeIdentity: background.theme?.url
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

    /// Deletes only groups that are no longer in the current API collection,
    /// or whose resource identity changed. Groups missing from the persisted
    /// fingerprint are unknown and therefore kept.
    internal func pruneCacheForCollectionChange(
        gameId: String,
        currentBackgrounds: [HoyoPlayBackground],
        persisted: BackgroundCollectionFingerprint
    ) async {
        let currentByID = Dictionary(
            uniqueKeysWithValues: currentBackgrounds.map { ($0.id, backgroundGroupFingerprint($0)) }
        )
        let persistedByID = Dictionary(
            uniqueKeysWithValues: persisted.groups.map { ($0.groupID, $0) }
        )
        let groupNames = (try? await mediaCacheManager.groupDirectoryNames(forGameId: gameId)) ?? []
        for name in groupNames {
            let shouldRemove: Bool
            if let current = currentByID[name] {
                if let old = persistedByID[name], old != current {
                    shouldRemove = true
                } else {
                    shouldRemove = false
                }
            } else {
                shouldRemove = true
            }
            if shouldRemove {
                _ = try? await mediaCacheManager.clearCache(forGameId: gameId, backgroundId: name)
                await logWriter.info(
                    "按 API 背景集合 diff 清除旧缓存: \(gameId)/\(name)",
                    module: "BackgroundMediaService"
                )
            }
        }
    }

    /// 当前背景 ID：固定取 API 解析到的第一个可用背景条目
    /// （用户指令 2026-10-05：不再提供背景组切换）
    internal func resolveCurrentBackgroundId(from backgrounds: [HoyoPlayBackground]) -> String? {
        backgrounds.first(where: {
            ($0.background?.url ?? "").isEmpty == false || ($0.video?.url ?? "").isEmpty == false
        })?.id
    }

    /// 检查指定背景 ID 的所有缓存文件是否完整
    internal func allCacheFilesExist(for gameId: String, backgroundId: String) async -> Bool {
        let subdir = "\(gameId)/\(backgroundId)"
        // 动态模式需要 video.mp4 + background.png + theme.png
        // 静态模式只需 background.png
        let mode = backgroundModes[gameId] ?? .dynamic
        switch mode {
        case .dynamic:
            let hasVideo = await mediaCacheManager.hasCachedFile(for: subdir + "/video.mp4")
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
        return size > 0
    }

    /// 旧版扁平缓存键（向下兼容读已有缓存）
    internal func cacheKey(gameId: String, type: AssetType, ext: String) -> String {
        return "\(gameId)_\(type.rawValue).\(ext)"
    }

}
