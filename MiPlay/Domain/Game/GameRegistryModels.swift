// GameRegistryModels.swift
// MiPlay

import Foundation

// Source: Architecture Design -> Domain Model -> Game
/// Domain values persisted by GameRegistry.
// MARK: - Domain values

public struct Game: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let type: GameType
    public var location: GameLocation?
    public var state: GameBusinessState
    public var version: String?
    public var lastIntegrity: IntegritySummary?
    public var lastMetadata: GameMetadata?
    public var metadataFailure: String?
    /// Last launch diagnostic retained for the UI and support logs.
    public var lastLaunchFailure: String?
    public var lastLaunchDate: Date?
    public var solutionApplications: [SolutionApplication]

    nonisolated public var installPath: String? {
        get { location?.lastKnownPath }
        set {
            location = newValue.map { GameLocation.migrationRequired(gameID: id, path: $0) }
        }
    }

    nonisolated public init(
        id: String,
        type: GameType,
        installPath: String?,
        state: GameBusinessState,
        version: String?,
        lastIntegrity: IntegritySummary? = nil,
        lastMetadata: GameMetadata? = nil,
        metadataFailure: String? = nil,
        lastLaunchFailure: String? = nil,
        lastLaunchDate: Date?,
        solutionApplications: [SolutionApplication]
    ) {
        self.init(
            id: id,
            type: type,
            location: installPath.map { GameLocation.migrationRequired(gameID: id, path: $0) },
            state: state,
            version: version,
            lastIntegrity: lastIntegrity,
            lastMetadata: lastMetadata,
            metadataFailure: metadataFailure,
            lastLaunchFailure: lastLaunchFailure,
            lastLaunchDate: lastLaunchDate,
            solutionApplications: solutionApplications
        )
    }

    nonisolated public init(
        id: String,
        type: GameType,
        location: GameLocation?,
        state: GameBusinessState,
        version: String?,
        lastIntegrity: IntegritySummary? = nil,
        lastMetadata: GameMetadata? = nil,
        metadataFailure: String? = nil,
        lastLaunchFailure: String? = nil,
        lastLaunchDate: Date?,
        solutionApplications: [SolutionApplication]
    ) {
        self.id = id
        self.type = type
        self.location = location
        self.state = state
        self.version = version
        self.lastIntegrity = lastIntegrity
        self.lastMetadata = lastMetadata
        self.metadataFailure = metadataFailure
        self.lastLaunchFailure = lastLaunchFailure
        self.lastLaunchDate = lastLaunchDate
        self.solutionApplications = solutionApplications
    }

    nonisolated public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(String.self, forKey: .id)
        type = try container.decode(GameType.self, forKey: .type)
        if let decodedLocation = try container.decodeIfPresent(GameLocation.self, forKey: .location) {
            location = decodedLocation
        } else if let oldPath = try container.decodeIfPresent(String.self, forKey: .installPath) {
            location = GameLocation.migrationRequired(gameID: id, path: oldPath)
        } else {
            location = nil
        }
        state = try container.decodeIfPresent(GameBusinessState.self, forKey: .state) ?? .notInstalled
        version = try container.decodeIfPresent(String.self, forKey: .version)
        lastIntegrity = try container.decodeIfPresent(IntegritySummary.self, forKey: .lastIntegrity)
        lastMetadata = try container.decodeIfPresent(GameMetadata.self, forKey: .lastMetadata)
        metadataFailure = try container.decodeIfPresent(String.self, forKey: .metadataFailure)
        lastLaunchFailure = try container.decodeIfPresent(String.self, forKey: .lastLaunchFailure)
        lastLaunchDate = try container.decodeIfPresent(Date.self, forKey: .lastLaunchDate)
        solutionApplications = try container.decodeIfPresent([SolutionApplication].self, forKey: .solutionApplications) ?? []
    }

    nonisolated public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(type, forKey: .type)
        try container.encodeIfPresent(location, forKey: .location)
        try container.encode(state, forKey: .state)
        try container.encodeIfPresent(version, forKey: .version)
        try container.encodeIfPresent(lastIntegrity, forKey: .lastIntegrity)
        try container.encodeIfPresent(lastMetadata, forKey: .lastMetadata)
        try container.encodeIfPresent(metadataFailure, forKey: .metadataFailure)
        try container.encodeIfPresent(lastLaunchFailure, forKey: .lastLaunchFailure)
        try container.encodeIfPresent(lastLaunchDate, forKey: .lastLaunchDate)
        try container.encode(solutionApplications, forKey: .solutionApplications)
    }

    private enum CodingKeys: String, CodingKey {
        case id, type, location, installPath, state, version, lastIntegrity, lastMetadata, metadataFailure, lastLaunchFailure, lastLaunchDate, solutionApplications
    }

    nonisolated public static func == (lhs: Game, rhs: Game) -> Bool { lhs.id == rhs.id }
}

/// The last successfully committed metadata snapshot for one Game ID.
public struct GameMetadata: Codable, Sendable, Equatable {
    public let gameID: String
    public let locationRevision: Int?
    public let readAt: Date
    public let latestVersion: String?
    public let outcome: VersionChecker.Outcome
    public let localEvidence: VersionChecker.LocalEvidence
    public let conflictDetails: [String]

    nonisolated public init(
        gameID: String,
        latestVersion: String?,
        outcome: VersionChecker.Outcome,
        localEvidence: VersionChecker.LocalEvidence,
        conflictDetails: [String] = []
    ) {
        self.gameID = gameID
        self.locationRevision = localEvidence.locationRevision
        self.readAt = localEvidence.readAt
        self.latestVersion = latestVersion
        self.outcome = outcome
        self.localEvidence = localEvidence
        self.conflictDetails = conflictDetails
    }
}

public struct IntegritySummary: Codable, Sendable, Equatable {
    public let status: String
    public let checkedAt: Date
    public let totalFiles: Int
    public let verifiedFiles: Int
    public let missingFiles: [String]
    public let corruptedFiles: [String]

    nonisolated public init(
        status: String,
        checkedAt: Date,
        totalFiles: Int,
        verifiedFiles: Int,
        missingFiles: [String],
        corruptedFiles: [String]
    ) {
        self.status = status
        self.checkedAt = checkedAt
        self.totalFiles = totalFiles
        self.verifiedFiles = verifiedFiles
        self.missingFiles = missingFiles
        self.corruptedFiles = corruptedFiles
    }
}

public struct SolutionApplication: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let solutionId: String
    public let gameId: String
    public let appliedDate: Date
    public var state: SolutionApplicationState
    public var notes: String?

    nonisolated public init(id: String, solutionId: String, gameId: String, appliedDate: Date, state: SolutionApplicationState, notes: String? = nil) {
        self.id = id
        self.solutionId = solutionId
        self.gameId = gameId
        self.appliedDate = appliedDate
        self.state = state
        self.notes = notes
    }

    nonisolated public static func == (lhs: SolutionApplication, rhs: SolutionApplication) -> Bool { lhs.id == rhs.id }
}
