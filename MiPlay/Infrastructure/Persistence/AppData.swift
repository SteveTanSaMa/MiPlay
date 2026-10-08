//
//  AppData.swift
//  MiPlay
//

import Foundation

// Source: Architecture Design -> Domain Model -> AppDataRecovery
// Source: Architecture Design -> Service Contract -> PersistenceStore

/// Schema 4 application snapshot. Domain facts are stored here only after validation.
public struct AppData: Codable, Sendable {
    // Source: Architecture Design -> ADR 037/038/041 -> fixed runtime/shared prefix
    nonisolated public static let currentSchemaVersion = 4

    public var schemaVersion: Int
    public var games: [Game]
    public var backgroundModes: [String: String]
    public var customImagePaths: [String: String]
    public var performanceOptions: [String: [PerformanceOptionDTO]]
    public var lastSelectedGame: String?
    public var selectedWineVersion: String?
    /// Product-approved Wine source ID. This is a source identity, never a URL.
    public var selectedWineSource: String?
    public var installedWineVersions: [String]
    public var perGameSettings: [String: PerGameSettings]
    public var lastCachedBackgroundIds: [String: String]
    public var taskHistory: [PersistedTaskRecord]
    public var recoveryRecords: [RecoveryRecord]
    /// Authoritative record for the single managed runtime. A nil value means
    /// setup has not committed a runtime pair yet.
    public var managedWineRuntime: ManagedWineRuntimeRecord?
    /// Authoritative record for the single prefix shared by all supported games.
    public var sharedWinePrefix: SharedWinePrefixRecord?
    /// 影响游戏运行的应用级设置（Metal HUD、帧率解锁、Retina、左 Command）。
    public var gameEnvironmentSettings: GameEnvironmentSettings

    nonisolated public init(
        schemaVersion: Int = AppData.currentSchemaVersion,
        games: [Game] = [],
        backgroundModes: [String: String] = [:],
        customImagePaths: [String: String] = [:],
        performanceOptions: [String: [PerformanceOptionDTO]] = [:],
        lastSelectedGame: String? = nil,
        selectedWineVersion: String? = nil,
        selectedWineSource: String? = nil,
        installedWineVersions: [String] = [],
        perGameSettings: [String: PerGameSettings] = [:],
        lastCachedBackgroundIds: [String: String] = [:],
        taskHistory: [PersistedTaskRecord] = [],
        recoveryRecords: [RecoveryRecord] = [],
        managedWineRuntime: ManagedWineRuntimeRecord? = nil,
        sharedWinePrefix: SharedWinePrefixRecord? = nil,
        gameEnvironmentSettings: GameEnvironmentSettings = GameEnvironmentSettings()
    ) {
        self.schemaVersion = schemaVersion
        self.games = games
        self.backgroundModes = backgroundModes
        self.customImagePaths = customImagePaths
        self.performanceOptions = performanceOptions
        self.lastSelectedGame = lastSelectedGame
        self.selectedWineVersion = selectedWineVersion
        self.selectedWineSource = selectedWineSource
        self.installedWineVersions = installedWineVersions
        self.perGameSettings = perGameSettings
        self.lastCachedBackgroundIds = lastCachedBackgroundIds
        self.taskHistory = taskHistory
        self.recoveryRecords = recoveryRecords
        self.managedWineRuntime = managedWineRuntime
        self.sharedWinePrefix = sharedWinePrefix
        self.gameEnvironmentSettings = gameEnvironmentSettings
    }

    nonisolated public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let version = try container.decodeIfPresent(Int.self, forKey: .schemaVersion) ?? 1
        guard version <= AppData.currentSchemaVersion else {
            throw DecodingError.dataCorruptedError(
                forKey: .schemaVersion,
                in: container,
                debugDescription: "不支持的 AppData schema: \(version)"
            )
        }
        self.schemaVersion = version
        self.games = try container.decodeIfPresent([Game].self, forKey: .games) ?? []
        self.backgroundModes = try container.decodeIfPresent([String: String].self, forKey: .backgroundModes) ?? [:]
        self.customImagePaths = try container.decodeIfPresent([String: String].self, forKey: .customImagePaths) ?? [:]
        self.performanceOptions = try container.decodeIfPresent([String: [PerformanceOptionDTO]].self, forKey: .performanceOptions) ?? [:]
        self.lastSelectedGame = try container.decodeIfPresent(String.self, forKey: .lastSelectedGame)
        self.selectedWineVersion = try container.decodeIfPresent(String.self, forKey: .selectedWineVersion)
        self.selectedWineSource = try container.decodeIfPresent(String.self, forKey: .selectedWineSource)
        self.installedWineVersions = try container.decodeIfPresent([String].self, forKey: .installedWineVersions) ?? []
        self.perGameSettings = try container.decodeIfPresent([String: PerGameSettings].self, forKey: .perGameSettings) ?? [:]
        self.lastCachedBackgroundIds = try container.decodeIfPresent([String: String].self, forKey: .lastCachedBackgroundIds) ?? [:]
        self.taskHistory = try container.decodeIfPresent([PersistedTaskRecord].self, forKey: .taskHistory) ?? []
        self.recoveryRecords = try container.decodeIfPresent([RecoveryRecord].self, forKey: .recoveryRecords) ?? []
        self.managedWineRuntime = try container.decodeIfPresent(ManagedWineRuntimeRecord.self, forKey: .managedWineRuntime)
        self.sharedWinePrefix = try container.decodeIfPresent(SharedWinePrefixRecord.self, forKey: .sharedWinePrefix)
        self.gameEnvironmentSettings = try container.decodeIfPresent(GameEnvironmentSettings.self, forKey: .gameEnvironmentSettings) ?? GameEnvironmentSettings()
    }

    nonisolated public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(games, forKey: .games)
        try container.encode(backgroundModes, forKey: .backgroundModes)
        try container.encode(customImagePaths, forKey: .customImagePaths)
        try container.encode(performanceOptions, forKey: .performanceOptions)
        try container.encodeIfPresent(lastSelectedGame, forKey: .lastSelectedGame)
        try container.encode(perGameSettings, forKey: .perGameSettings)
        try container.encode(lastCachedBackgroundIds, forKey: .lastCachedBackgroundIds)
        try container.encode(taskHistory, forKey: .taskHistory)
        try container.encode(recoveryRecords, forKey: .recoveryRecords)
        try container.encodeIfPresent(managedWineRuntime, forKey: .managedWineRuntime)
        try container.encodeIfPresent(sharedWinePrefix, forKey: .sharedWinePrefix)
        try container.encode(gameEnvironmentSettings, forKey: .gameEnvironmentSettings)
    }

    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case games
        case backgroundModes
        case customImagePaths
        case performanceOptions
        case lastSelectedGame
        case selectedWineVersion
        case selectedWineSource
        case installedWineVersions
        case perGameSettings
        case lastCachedBackgroundIds
        case taskHistory, recoveryRecords
        case managedWineRuntime, sharedWinePrefix
        case gameEnvironmentSettings
    }
}

// Source: Architecture Design -> Revision 2026-08-03 -> PerGameSettings
nonisolated public struct PerGameSettings: Codable, Sendable, Equatable {
    public let gameID: String
    public var metadataDisplayEnabled: Bool
    /// Legacy migration input only. Canonical schema 4 encoding omits it.
    public var wineVersionOverride: String?
    public var compatibilityCapabilityStatus: [String: String]
    public var lastFailure: String?

    public init(
        gameID: String,
        metadataDisplayEnabled: Bool = true,
        wineVersionOverride: String? = nil,
        compatibilityCapabilityStatus: [String: String] = [:],
        lastFailure: String? = nil
    ) {
        self.gameID = gameID
        self.metadataDisplayEnabled = metadataDisplayEnabled
        self.wineVersionOverride = wineVersionOverride
        self.compatibilityCapabilityStatus = compatibilityCapabilityStatus
        self.lastFailure = lastFailure
    }

    private enum CodingKeys: String, CodingKey {
        case gameID
        case metadataDisplayEnabled
        case wineVersionOverride
        case compatibilityCapabilityStatus
        case lastFailure
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.gameID = try container.decode(String.self, forKey: .gameID)
        self.metadataDisplayEnabled = try container.decodeIfPresent(Bool.self, forKey: .metadataDisplayEnabled) ?? true
        self.wineVersionOverride = try container.decodeIfPresent(String.self, forKey: .wineVersionOverride)
        self.compatibilityCapabilityStatus = try container.decodeIfPresent([String: String].self, forKey: .compatibilityCapabilityStatus) ?? [:]
        self.lastFailure = try container.decodeIfPresent(String.self, forKey: .lastFailure)
    }

    /// The old override remains decodable for schema migration, but never
    /// appears in canonical schema 4 JSON.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(gameID, forKey: .gameID)
        try container.encode(metadataDisplayEnabled, forKey: .metadataDisplayEnabled)
        try container.encode(compatibilityCapabilityStatus, forKey: .compatibilityCapabilityStatus)
        try container.encodeIfPresent(lastFailure, forKey: .lastFailure)
    }
}

// Source: Architecture Design -> Domain Model -> ManagedWineRuntime
nonisolated public struct ManagedWineRuntimeRecord: Codable, Sendable, Equatable {
    public var identity: String
    public var sourceID: String
    public var assetName: String
    public var rootPath: String
    public var binaryPath: String
    public var architecture: String
    public var revision: String
    public var state: String
    public var verifiedAt: Date?

    public init(
        identity: String,
        sourceID: String,
        assetName: String,
        rootPath: String,
        binaryPath: String,
        architecture: String = "arm64",
        revision: String = "1",
        state: String = "ready",
        verifiedAt: Date? = Date()
    ) {
        self.identity = identity
        self.sourceID = sourceID
        self.assetName = assetName
        self.rootPath = rootPath
        self.binaryPath = binaryPath
        self.architecture = architecture
        self.revision = revision
        self.state = state
        self.verifiedAt = verifiedAt
    }
}

// Source: Architecture Design -> Domain Model -> SharedWinePrefix
nonisolated public struct SharedWinePrefixRecord: Codable, Sendable, Equatable {
    public var identity: String
    public var relativePath: String
    public var absolutePath: String
    public var runtimeIdentity: String
    public var schemaRevision: String
    public var state: String
    public var verifiedAt: Date?

    public init(
        identity: String,
        relativePath: String,
        absolutePath: String,
        runtimeIdentity: String,
        schemaRevision: String = "1",
        state: String = "ready",
        verifiedAt: Date? = Date()
    ) {
        self.identity = identity
        self.relativePath = relativePath
        self.absolutePath = absolutePath
        self.runtimeIdentity = runtimeIdentity
        self.schemaRevision = schemaRevision
        self.state = state
        self.verifiedAt = verifiedAt
    }
}

/// Persisted task outcome. It intentionally contains no Error or Process object.
public struct PersistedTaskRecord: Codable, Sendable, Identifiable {
    public let id: String
    public let type: String
    public let gameID: String?
    public var status: String
    public var phase: String
    public var progress: Double?
    public var outcome: String?
    public var error: String?
    public var recovery: String?
    public let createdAt: Date
    public var startedAt: Date?
    public var endedAt: Date?
    public let intentID: UUID?
    public let context: [String: String]
    public let resourceKeys: [String]

    nonisolated public init(
        id: String,
        type: String,
        gameID: String?,
        status: String,
        phase: String,
        progress: Double?,
        outcome: String?,
        error: String?,
        recovery: String?,
        createdAt: Date,
        startedAt: Date? = nil,
        endedAt: Date? = nil,
        intentID: UUID? = nil,
        context: [String: String] = [:],
        resourceKeys: [String] = []
    ) {
        self.id = id
        self.type = type
        self.gameID = gameID
        self.status = status
        self.phase = phase
        self.progress = progress
        self.outcome = outcome
        self.error = error
        self.recovery = recovery
        self.createdAt = createdAt
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.intentID = intentID
        self.context = context
        self.resourceKeys = resourceKeys
    }
}

/// 影响游戏运行的应用级设置（对照 YAAGL 的全局开关）。
///
/// 用户指令（2026-10-07）：Metal HUD、Retina、超帧率、按键映射统一放到「通用设置」。
/// - `metalHUD` / `fpsUnlock` 通过启动环境变量下发；
/// - `retinaMode` / `leftCommandIsCtrl` 写入共享 prefix 的
///   `HKCU\Software\Wine\Mac Driver`，在准备 prefix 与每次启动游戏前生效。
nonisolated public struct GameEnvironmentSettings: Codable, Sendable, Equatable {
    /// 显示 Metal 性能面板（`MTL_HUD_ENABLED=1`，使用系统默认的 Lite 布局）。
    public var metalHUD: Bool
    /// 解除帧率上限（等待解锁工具接入后生效）。
    public var fpsUnlock: Bool
    /// `RetinaMode`：true（`y`）= Wine 按屏幕设备像素渲染，画面更锐利、界面偏小；
    /// false（`n`）= 按 macOS 逻辑分辨率渲染（YAAGL 的默认值）。
    public var retinaMode: Bool
    /// `LeftCommandIsCtrl`：把左 Command 键映射为 Control（游戏内快捷键）。
    public var leftCommandIsCtrl: Bool

    public init(
        metalHUD: Bool = false,
        fpsUnlock: Bool = false,
        retinaMode: Bool = true,
        leftCommandIsCtrl: Bool = false
    ) {
        self.metalHUD = metalHUD
        self.fpsUnlock = fpsUnlock
        self.retinaMode = retinaMode
        self.leftCommandIsCtrl = leftCommandIsCtrl
    }

    /// 需要写入注册表的值（`REG_SZ`，Wine 认 `y`/`n`）。
    nonisolated public var registryValues: [String: String] {
        [
            "RetinaMode": retinaMode ? "y" : "n",
            "LeftCommandIsCtrl": leftCommandIsCtrl ? "y" : "n",
        ]
    }

    /// 启动时需要注入的环境变量。
    ///
    /// 只开启 HUD，不再覆盖 `MTL_HUD_ELEMENTS` / `MTL_HUD_SCALE`（用户指令 2026-10-08：
    /// 「面板设置为正常的，不再修改为最小尺寸与 fps only」）。让 Metal HUD 使用系统默认的
    /// **Lite** 布局：设备名、图层分辨率与 present 模式、内存占用、FPS / GPU 时间 / 帧间隔图表。
    nonisolated public var environmentVariables: [String: String] {
        guard metalHUD else { return [:] }
        return ["MTL_HUD_ENABLED": "1"]
    }
}

/// A durable protection fact for work whose side effects or business state did
/// not converge. It is intentionally separate from the five task states.
nonisolated public struct RecoveryRecord: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let kind: String
    public let taskID: String?
    public let gameID: String?
    public let target: String?
    public let phase: String
    public let detail: String
    public let payload: [String: String]
    public let createdAt: Date
    public var resolvedAt: Date?

    nonisolated public init(
        id: String = UUID().uuidString,
        kind: String,
        taskID: String? = nil,
        gameID: String? = nil,
        target: String? = nil,
        phase: String,
        detail: String,
        payload: [String: String] = [:],
        createdAt: Date = Date(),
        resolvedAt: Date? = nil
    ) {
        self.id = id
        self.kind = kind
        self.taskID = taskID
        self.gameID = gameID
        self.target = target
        self.phase = phase
        self.detail = detail
        self.payload = payload
        self.createdAt = createdAt
        self.resolvedAt = resolvedAt
    }
}
