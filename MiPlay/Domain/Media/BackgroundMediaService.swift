//
//  BackgroundMediaService.swift
//  MiPlay
//
//  Created by Steve Tan on 2026/7/7.
//

@preconcurrency import Foundation

// Source: Architecture Design → Service Contract → BackgroundMediaService
// Source: Architecture Design → ADR 012 → 背景素材懒加载 + 磁盘缓存 + TTL 过期策略
// Source: UI Design → View Responsibility → BackgroundView
// Source: HoyoPlay API → hyp-connect/api/getAllGameBasicInfo

/// 背景素材服务。管理背景素材的全生命周期。
/// 包括从 HoyoPlay API 获取素材元数据、协调转码和缓存策略、
/// 按游戏背景模式选择素材来源。
@Observable
public final class BackgroundMediaService {
    public struct BackgroundGroup: Codable, Sendable, Identifiable, Equatable {
        public let groupID: String
        public let gameID: String
        public let sourceID: String
        public let version: String?
        public let type: String?
        public let backgroundURL: URL?
        public let videoURL: URL?
        public let themeURL: URL?

        public var id: String { groupID }

        public init(
            groupID: String,
            gameID: String,
            sourceID: String,
            version: String? = nil,
            type: String? = nil,
            backgroundURL: URL?,
            videoURL: URL?,
            themeURL: URL?
        ) {
            self.groupID = groupID
            self.gameID = gameID
            self.sourceID = sourceID
            self.version = version
            self.type = type
            self.backgroundURL = backgroundURL
            self.videoURL = videoURL
            self.themeURL = themeURL
        }
    }

    public enum BackgroundError: Error, LocalizedError, Sendable {
        case unavailable(String)
        case persistenceFailed(String)

        public var errorDescription: String? {
            switch self {
            case .unavailable(let detail): return "背景组不可用: \(detail)"
            case .persistenceFailed(let detail): return "背景组选择持久化失败: \(detail)"
            }
        }
    }

    // MARK: - 背景模式

    public enum BackgroundMode: String, Codable, Sendable, CaseIterable {
        case dynamic = "Dynamic"
        case `static` = "Static"
        case custom = "Custom"

        public var displayName: String {
            switch self {
            case .dynamic: return "默认动态"
            case .static: return "默认静态"
            case .custom: return "自定义图片"
            }
        }
    }

    /// 素材就绪状态
    public enum MediaState: Sendable {
        case loading
        case ready(localPath: String, isVideo: Bool)
        case failed(String)
        case notLoaded
    }

    /// 素材类型（用于缓存键，扩展名均为转码后的目标格式）
    internal enum AssetType: String {
        case background = "background"   // .webp → .png
        case video = "video"             // .webm → .mp4
        case theme = "theme"             // .webp → .png
    }

    // MARK: - Published State（按游戏）

    internal var mediaStates: [String: MediaState] = [:]
    internal var backgroundModes: [String: BackgroundMode] = [:]
    internal var customImagePaths: [String: String] = [:]
    /// Theme 装饰图本地路径（带透明通道的 PNG，叠加在背景之上）
    internal var themeImagePaths: [String: String] = [:]
    internal var backgroundGroups: [String: [BackgroundGroup]] = [:]
    internal var selectedBackgroundGroupIDs: [String: String] = [:]
    internal var backgroundGroupErrors: [String: String] = [:]
    /// Source: ADR 019 — content-addressable 缓存追踪
    internal var lastCachedBackgroundIds: [String: String] = [:]
    /// HoyoPlay metadata cache is actor state and must remain stored on the type.
    internal var cachedEntries: [HoyoPlayGameEntry]?
    internal var cacheTimestamp: Date?

    // MARK: - Constants

    internal let hoyoPlayURL = URL(
        string: "https://hyp-api.mihoyo.com/hyp/hyp-connect/api/getAllGameBasicInfo?launcher_id=jGHBHlcOq1"
    )!

    /// GameType → HoyoPlay game.biz 映射（国服版本）
    internal let gameKeyMap: [String: String] = [
        GameType.genshinImpact.rawValue: "hk4e_cn",
        GameType.honkaiStarRail.rawValue: "hkrpg_cn",
        GameType.zenlessZoneZero.rawValue: "nap_cn",
    ]

    // MARK: - Dependencies

    internal let mediaTranscoder: MediaTranscoder
    internal let mediaCacheManager: MediaCacheManager
    internal let networkProvider: NetworkDownloadProvider
    internal let persistenceStore: PersistenceStore
    internal let logWriter: LogWriter

    public init(
        mediaTranscoder: MediaTranscoder,
        mediaCacheManager: MediaCacheManager,
        networkProvider: NetworkDownloadProvider,
        persistenceStore: PersistenceStore,
        logWriter: LogWriter
    ) {
        self.mediaTranscoder = mediaTranscoder
        self.mediaCacheManager = mediaCacheManager
        self.networkProvider = networkProvider
        self.persistenceStore = persistenceStore
        self.logWriter = logWriter
    }

    // MARK: - Initialization

    /// 加载各游戏的背景模式设置（从 AppData）
    public func loadSettings() async {
        do {
            let appData = try await persistenceStore.readAppData()
            for (gameId, modeRaw) in appData.backgroundModes {
                if let mode = BackgroundMode(rawValue: modeRaw) {
                    backgroundModes[gameId] = mode
                }
            }
            customImagePaths = appData.customImagePaths
            // Source: ADR 019 — 恢复 lastCachedBackgroundIds
            lastCachedBackgroundIds = appData.lastCachedBackgroundIds
            selectedBackgroundGroupIDs = appData.backgroundGroupSelections
            for (gameID, settings) in appData.perGameSettings {
                if selectedBackgroundGroupIDs[gameID] == nil,
                   let groupID = settings.selectedBackgroundGroupID {
                    selectedBackgroundGroupIDs[gameID] = groupID
                }
            }
        } catch {
            await logWriter.warning("背景设置加载失败: \(error.localizedDescription)", module: "BackgroundMediaService")
        }

        for gameType in GameType.allCases {
            if backgroundModes[gameType.rawValue] == nil {
                backgroundModes[gameType.rawValue] = .dynamic
            }
        }
    }

    // MARK: - HoyoPlay API（带 5 分钟内存缓存）

    /// API 响应缓存
    // MARK: - Public State Queries

    public func getMediaState(for gameId: String) -> MediaState {
        return mediaStates[gameId] ?? .notLoaded
    }

    /// 获取 Theme 装饰图本地路径
    public func getThemeImagePath(for gameId: String) -> String? {
        return themeImagePaths[gameId]
    }

    /// 强制刷新缓存
    /// Source: ADR 019 — 清除子目录缓存后重新加载
    public func refreshCache(for gameId: String) async {
        if let bgId = lastCachedBackgroundIds[gameId] {
            _ = try? await mediaCacheManager.clearCache(forGameId: gameId, backgroundId: bgId)
        }
        lastCachedBackgroundIds.removeValue(forKey: gameId)
        mediaStates[gameId] = .notLoaded
        await loadMedia(for: gameId)
    }

    public func clearAllCache() async {
        _ = try? await mediaCacheManager.clearCache()
        mediaStates.removeAll()
    }
}
