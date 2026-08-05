//
//  TaskSchedulerModels.swift
//  MiPlay
//

import Foundation

// Source: Architecture Design -> Task Queue -> TaskScheduler
// Source: Architecture Design -> ADR 008 -> task facts are separate from business outcome

public enum ScheduledTaskType: String, Codable, Sendable, CaseIterable {
    case gameLaunch = "GameLaunch"
    case solutionApply = "SolutionApply"
    case solutionRevert = "SolutionRevert"
    case versionCheck = "VersionCheck"
    case integrityVerification = "IntegrityVerification"
    case wineVersionDownload = "WineVersionDownload"
    case wineCatalogQuery = "WineCatalogQuery"
    case backgroundMediaLoad = "BackgroundMediaLoad"
    case logExport = "LogExport"

    nonisolated var isBackground: Bool {
        self == .versionCheck || self == .integrityVerification || self == .backgroundMediaLoad || self == .wineCatalogQuery
    }

    nonisolated var isCancellable: Bool { self != .solutionRevert }

    nonisolated var priority: ScheduledPriority {
        switch self {
        case .gameLaunch: return .userBlocking
        case .solutionApply, .solutionRevert, .wineVersionDownload, .logExport: return .userInitiated
        case .versionCheck, .integrityVerification, .backgroundMediaLoad, .wineCatalogQuery: return .background
        }
    }
}

public enum ScheduledPriority: Int, Codable, Sendable {
    case background = 0
    case userInitiated = 1
    case userBlocking = 2
}

public enum ScheduledTaskState: String, Codable, Sendable {
    case pending
    case running
    case completed
    case failed
    case cancelled
}

nonisolated public struct ScheduledTaskID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let id: String

    nonisolated public init(_ id: String = UUID().uuidString) { self.id = id }
    nonisolated public var description: String { id }
    nonisolated public static func == (lhs: ScheduledTaskID, rhs: ScheduledTaskID) -> Bool { lhs.id == rhs.id }
    nonisolated public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

public enum TaskCancellationPolicy: String, Codable, Sendable {
    case beforeSideEffect
    case cleanupAfterSideEffect
    case notCancellable
}

public struct ScheduledTask: Codable, Sendable, Identifiable, Equatable {
    public let id: ScheduledTaskID
    public let intentID: UUID
    public let type: ScheduledTaskType
    public let gameId: String?
    public let priority: ScheduledPriority
    public let context: [String: String]
    public let createdAt: Date
    public var startedAt: Date?
    public var endedAt: Date?
    public var state: ScheduledTaskState
    public var phaseDescription: String
    public var progress: Double?
    public var outcome: String?
    public var error: String?
    public var recovery: String?
    public var revision: UInt64

    nonisolated public var cancellationPolicy: TaskCancellationPolicy {
        switch type {
        case .solutionRevert: return .notCancellable
        case .gameLaunch, .solutionApply, .wineVersionDownload: return .cleanupAfterSideEffect
        case .versionCheck, .integrityVerification, .backgroundMediaLoad, .wineCatalogQuery, .logExport: return .beforeSideEffect
        }
    }

    nonisolated public init(
        id: ScheduledTaskID = ScheduledTaskID(),
        intentID: UUID = UUID(),
        type: ScheduledTaskType,
        gameId: String?,
        priority: ScheduledPriority? = nil,
        context: [String: String] = [:],
        createdAt: Date = Date()
    ) {
        self.id = id
        self.intentID = intentID
        self.type = type
        self.gameId = gameId
        self.priority = priority ?? type.priority
        self.context = context
        self.createdAt = createdAt
        self.startedAt = nil
        self.endedAt = nil
        self.state = .pending
        self.phaseDescription = "等待执行"
        self.progress = nil
        self.outcome = nil
        self.error = nil
        self.recovery = nil
        self.revision = 0
    }
}

public struct TaskDownloadProgress: Sendable, Equatable {
    public let bytesReceived: Int64
    public let totalBytes: Int64
    public let speed: Double

    nonisolated public init(bytesReceived: Int64, totalBytes: Int64, speed: Double) {
        self.bytesReceived = bytesReceived
        self.totalBytes = totalBytes
        self.speed = speed
    }
}

public struct TaskProgress: Sendable, Equatable {
    public let taskId: ScheduledTaskID
    public let phase: String
    public let progress: Double?
    public let statusText: String
    public let download: TaskDownloadProgress?

    nonisolated public init(
        taskId: ScheduledTaskID,
        phase: String,
        progress: Double? = nil,
        statusText: String,
        download: TaskDownloadProgress? = nil
    ) {
        self.taskId = taskId
        self.phase = phase
        self.progress = progress
        self.statusText = statusText
        self.download = download
    }
}

public struct TaskEvent: Sendable {
    public let sequence: UInt64
    public let snapshot: ScheduledTask
    public let persistence: PersistenceMarker

    public enum PersistenceMarker: String, Sendable, Equatable {
        case committed
        case memoryOnly
        case recoveryRequired
    }
}

/// A task receipt is returned only after the pending record has been written
/// and read back by PersistenceStore.
public struct TaskReceipt: Sendable, Equatable {
    public let taskID: ScheduledTaskID
    public let intentID: UUID
    public let eventCursor: UInt64
    public let resourceKeys: [String]
    public let cancellationPolicy: TaskCancellationPolicy
    public let persistence: TaskEvent.PersistenceMarker

    nonisolated public init(
        taskID: ScheduledTaskID,
        intentID: UUID,
        eventCursor: UInt64,
        resourceKeys: [String],
        cancellationPolicy: TaskCancellationPolicy,
        persistence: TaskEvent.PersistenceMarker
    ) {
        self.taskID = taskID
        self.intentID = intentID
        self.eventCursor = eventCursor
        self.resourceKeys = resourceKeys
        self.cancellationPolicy = cancellationPolicy
        self.persistence = persistence
    }
}
