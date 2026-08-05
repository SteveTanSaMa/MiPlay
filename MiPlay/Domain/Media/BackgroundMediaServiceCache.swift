// BackgroundMediaServiceCache.swift
// MiPlay

@preconcurrency import Foundation

// Source: Architecture Design -> ADR 012 -> cache helpers
extension BackgroundMediaService {
    // MARK: - ADR-019 Content-Addressable Cache Helpers

    /// 当前模式下的有效背景 ID（从 API 背景列表中解析）
    internal func resolveCurrentBackgroundId(
        from backgrounds: [HoyoPlayBackground],
        for mode: BackgroundMode,
        gameId: String
    ) -> String? {
        if let selected = selectedBackgroundGroupIDs[gameId],
           backgrounds.contains(where: { $0.id == selected }) {
            return selected
        }
        switch mode {
        case .dynamic:
            // 动态模式：取视频背景条目的 id
            return backgrounds.first(where: {
                $0.type == "BACKGROUND_TYPE_VIDEO" && ($0.video?.url ?? "").isEmpty == false
            })?.id
        case .static:
            // 静态模式：取第一个有背景图的条目 id
            return backgrounds.first(where: { ($0.background?.url ?? "").isEmpty == false })?.id
        case .custom:
            return nil
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
    internal func hasSubCache(for gameId: String, backgroundId: String, type: AssetType, ext: String) async -> Bool {
        let subdirectory = "\(gameId)/\(backgroundId)"
        let filename = "\(type.rawValue).\(ext)"
        return await mediaCacheManager.hasCachedFile(for: subdirectory + "/" + filename)
    }

    /// 旧版扁平缓存键（向下兼容读已有缓存）
    internal func cacheKey(gameId: String, type: AssetType, ext: String) -> String {
        return "\(gameId)_\(type.rawValue).\(ext)"
    }

}
