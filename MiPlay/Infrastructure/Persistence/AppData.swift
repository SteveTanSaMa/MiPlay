//
//  AppData.swift
//  MiPlay
//

import Foundation

// Source: Architecture Design -> Domain Model -> AppDataRecovery
// Source: Architecture Design -> Service Contract -> PersistenceStore

/// Schema 2 application snapshot. Domain facts are stored here only after validation.
public struct AppData: Codable, Sendable {
    nonisolated public static let currentSchemaVersion = 2

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
    public var backgroundGroupSelections: [String: String]
    public var lastCachedBackgroundIds: [String: String]
    public var taskHistory: [PersistedTaskRecord]
    public var recoveryRecords: [RecoveryRecord]

    nonisolated public init(
        schemaVersion: Int = AppData.currentSchemaVersion,
        games: [Game] = [],
        backgroundModes: [String: String] = [:],
        customImagePaths: [String: String] = [:],
        performanceOptions: [String: [PerformanceOptionDTO]] = [:],
        lastSelectedGame: String? = nil,
        selectedWineVersion: String? = nil,
        selectedWineSource: String? = "officialGitHub",
        installedWineVersions: [String] = [],
        perGameSettings: [String: PerGameSettings] = [:],
        backgroundGroupSelections: [String: String] = [:],
        lastCachedBackgroundIds: [String: String] = [:],
        taskHistory: [PersistedTaskRecord] = [],
        recoveryRecords: [RecoveryRecord] = []
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
        self.backgroundGroupSelections = backgroundGroupSelections
        self.lastCachedBackgroundIds = lastCachedBackgroundIds
        self.taskHistory = taskHistory
        self.recoveryRecords = recoveryRecords
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
        self.selectedWineSource = try container.decodeIfPresent(String.self, forKey: .selectedWineSource) ?? "officialGitHub"
        self.installedWineVersions = try container.decodeIfPresent([String].self, forKey: .installedWineVersions) ?? []
        self.perGameSettings = try container.decodeIfPresent([String: PerGameSettings].self, forKey: .perGameSettings) ?? [:]
        self.backgroundGroupSelections = try container.decodeIfPresent([String: String].self, forKey: .backgroundGroupSelections) ?? [:]
        self.lastCachedBackgroundIds = try container.decodeIfPresent([String: String].self, forKey: .lastCachedBackgroundIds) ?? [:]
        self.taskHistory = try container.decodeIfPresent([PersistedTaskRecord].self, forKey: .taskHistory) ?? []
        self.recoveryRecords = try container.decodeIfPresent([RecoveryRecord].self, forKey: .recoveryRecords) ?? []
    }

    nonisolated public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(schemaVersion, forKey: .schemaVersion)
        try container.encode(games, forKey: .games)
        try container.encode(backgroundModes, forKey: .backgroundModes)
        try container.encode(customImagePaths, forKey: .customImagePaths)
        try container.encode(performanceOptions, forKey: .performanceOptions)
        try container.encodeIfPresent(lastSelectedGame, forKey: .lastSelectedGame)
        try container.encodeIfPresent(selectedWineVersion, forKey: .selectedWineVersion)
        try container.encodeIfPresent(selectedWineSource, forKey: .selectedWineSource)
        try container.encode(installedWineVersions, forKey: .installedWineVersions)
        try container.encode(perGameSettings, forKey: .perGameSettings)
        try container.encode(backgroundGroupSelections, forKey: .backgroundGroupSelections)
        try container.encode(lastCachedBackgroundIds, forKey: .lastCachedBackgroundIds)
        try container.encode(taskHistory, forKey: .taskHistory)
        try container.encode(recoveryRecords, forKey: .recoveryRecords)
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
        case backgroundGroupSelections
        case lastCachedBackgroundIds
        case taskHistory, recoveryRecords
    }
}

// Source: Architecture Design -> Revision 2026-08-03 -> PerGameSettings
public struct PerGameSettings: Codable, Sendable, Equatable {
    public let gameID: String
    public var metadataDisplayEnabled: Bool
    public var selectedBackgroundGroupID: String?
    public var compatibilityCapabilityStatus: [String: String]
    public var lastFailure: String?

    public init(
        gameID: String,
        metadataDisplayEnabled: Bool = true,
        selectedBackgroundGroupID: String? = nil,
        compatibilityCapabilityStatus: [String: String] = [:],
        lastFailure: String? = nil
    ) {
        self.gameID = gameID
        self.metadataDisplayEnabled = metadataDisplayEnabled
        self.selectedBackgroundGroupID = selectedBackgroundGroupID
        self.compatibilityCapabilityStatus = compatibilityCapabilityStatus
        self.lastFailure = lastFailure
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
