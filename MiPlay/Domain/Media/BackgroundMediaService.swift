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
        case icon = "icon"
        case iconHover = "icon-hover"
    }

    // MARK: - Published State（按游戏）

    internal var mediaStates: [String: MediaState] = [:]
    internal var backgroundModes: [String: BackgroundMode] = [:]
    internal var customImagePaths: [String: String] = [:]
    /// Theme 装饰图本地路径（带透明通道的 PNG，叠加在背景之上）
    internal var themeImagePaths: [String: String] = [:]
    /// 当前背景组的静态背景图（PNG）本地路径。视频背景播放时作为底层画面，
    /// 覆盖首帧加载与播放失败的场景。
    internal var backgroundStillImagePaths: [String: String] = [:]
    /// Source: ADR 019 — content-addressable 缓存追踪
    internal var lastCachedBackgroundIds: [String: String] = [:]
    /// HoyoPlay metadata cache is actor state and must remain stored on the type.
    internal var cachedEntries: [HoyoPlayGameEntry]?
    internal var cacheTimestamp: Date?
    /// An older asynchronous load must not publish retained assets after a
    /// newer load has selected a different collection for the same game.
    internal var backgroundLoadGenerations: [String: UUID] = [:]
    /// Retention runs independently of presentation but is owned by the
    /// service, so reloads, settings changes and cache clearing can cancel it.
    @ObservationIgnored internal var backgroundRetentionTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored internal var backgroundRetentionTokens: [String: UUID] = [:]

    // MARK: - Constants

    internal let hoyoPlayURL = URL(
        string: "https://hyp-api.mihoyo.com/hyp/hyp-connect/api/getAllGameBasicInfo?launcher_id=jGHBHlcOq1"
    )!
    /// Source identity used by the API collection fingerprint.
    internal let backgroundSourceID = "hoyoPlay"

    nonisolated public static let retainOutdatedBackgroundsKey = "retainOutdatedBackgrounds"
    nonisolated public static let retainOutdatedBackgroundsDefault = false
    /// Existing users who enabled the global option retain their previous
    /// behavior until they explicitly disable an individual game.
    nonisolated public static let retainOutdatedBackgroundsForGameDefault = true

    nonisolated public static func retentionPreferenceKey(forGameID gameID: String) -> String {
        "\(retainOutdatedBackgroundsKey).\(gameID)"
    }

    /// 默认不保留旧素材；每次维护缓存时读取，设置切换无需重启应用。
    public var retainOutdatedBackgrounds: Bool {
        userDefaults.object(forKey: Self.retainOutdatedBackgroundsKey) as? Bool ?? Self.retainOutdatedBackgroundsDefault
    }

    /// The global option remains the master switch; each game's setting is
    /// persisted independently and defaults on for existing installations.
    public func retainsOutdatedBackgrounds(for gameID: String) -> Bool {
        retainOutdatedBackgrounds &&
            (userDefaults.object(forKey: Self.retentionPreferenceKey(forGameID: gameID)) as? Bool
                ?? Self.retainOutdatedBackgroundsForGameDefault)
    }

    /// GameType → HoyoPlay game.biz 映射（国服版本）
    internal let gameKeyMap: [String: String] = Dictionary(
        uniqueKeysWithValues: GameType.allCases.map { ($0.rawValue, $0.definition.mainlandBiz) }
    )

    // MARK: - Dependencies

    internal let mediaTranscoder: MediaTranscoder
    internal let mediaCacheManager: MediaCacheManager
    internal let networkProvider: NetworkDownloadProvider
    internal let persistenceStore: PersistenceStore
    internal let logWriter: LogWriter
    internal let userDefaults: UserDefaults

    public init(
        mediaTranscoder: MediaTranscoder,
        mediaCacheManager: MediaCacheManager,
        networkProvider: NetworkDownloadProvider,
        persistenceStore: PersistenceStore,
        logWriter: LogWriter,
        userDefaults: UserDefaults = .standard
    ) {
        self.mediaTranscoder = mediaTranscoder
        self.mediaCacheManager = mediaCacheManager
        self.networkProvider = networkProvider
        self.persistenceStore = persistenceStore
        self.logWriter = logWriter
        self.userDefaults = userDefaults
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

    /// 获取当前背景组的静态背景图本地路径（视频背景的底层画面）
    public func getBackgroundStillImagePath(for gameId: String) -> String? {
        return backgroundStillImagePaths[gameId]
    }

    /// 刷新 API 背景元数据并重新加载媒体。
    /// Source: ADR 035 — 缓存失效仅由 API 集合指纹 diff 决定；
    /// lastCachedBackgroundIds 仅保留为诊断事实。
    public func refreshCache(for gameId: String) async {
        cachedEntries = nil
        cacheTimestamp = nil
        mediaStates[gameId] = .notLoaded
        await loadMedia(for: gameId)
    }

    public func clearAllCache() async {
        backgroundLoadGenerations.removeAll()
        let tasks = Array(backgroundRetentionTasks.values)
        cancelRetainedBackgrounds()
        for task in tasks { await task.value }
        _ = try? await mediaCacheManager.clearCache()
        mediaStates.removeAll()
    }
}
