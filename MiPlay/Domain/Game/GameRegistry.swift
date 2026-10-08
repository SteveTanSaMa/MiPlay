//
//  GameRegistry.swift
//  MiPlay
//
//  Created by Steve Tan on 2026/7/7.
//

import Foundation

// Source: Architecture Design -> Service Contract -> GameRegistry
// Source: Architecture Design -> State Ownership -> Game state owner
// Source: Architecture Design -> Communication -> bookmark location flow

/// Actor owning the three fixed Game aggregates and their committed facts.
public actor GameRegistry {
    public enum RegistrationError: Error, LocalizedError {
        case gameAlreadyExists(GameType)
        case gameNotFound(String)
        case invalidPath(String)
        case permissionRequired(String)
        case persistenceFailed(String)
        case recoveryRequired(String)

        public var errorDescription: String? {
            switch self {
            case .gameAlreadyExists(let type): return "游戏已存在: \(type.displayName)"
            case .gameNotFound(let id): return "游戏未找到: \(id)"
            case .invalidPath(let path): return "无效路径: \(path)"
            case .permissionRequired(let detail): return "需要重新授权游戏目录: \(detail)"
            case .persistenceFailed(let detail): return "持久化失败: \(detail)"
            case .recoveryRequired(let detail): return "应用数据恢复未完成: \(detail)"
            }
        }
    }

    public enum LibraryState: Sendable, Equatable {
        case uninitialized
        case loaded
        case recoveryRequired(String)
        case loadingFailed(String)
    }

    public struct RegistryEvent: Sendable {
        public let sequence: UInt64
        public let game: Game
        public let occurredAt: Date

        public init(sequence: UInt64, game: Game, occurredAt: Date = Date()) {
            self.sequence = sequence
            self.game = game
            self.occurredAt = occurredAt
        }
    }

    internal var games: [Game] = []
    internal var libraryState: LibraryState = .uninitialized
    public let eventStream: AsyncStream<RegistryEvent>

    internal var eventContinuation: AsyncStream<RegistryEvent>.Continuation?
    internal var eventSubscribers: [UUID: AsyncStream<RegistryEvent>.Continuation] = [:]
    internal var sequence: UInt64 = 0
    internal var inMemoryRecoveryRecords: [String: RecoveryRecord] = [:]

    internal let persistenceStore: PersistenceStore
    internal let fileSystemRepository: GameFileSystemRepository
    internal let stateMachine: GameStateMachine
    internal let logWriter: LogWriter

    public init(
        persistenceStore: PersistenceStore,
        fileSystemRepository: GameFileSystemRepository,
        stateMachine: GameStateMachine,
        systemDetector: SystemEnvironmentDetector,
        logWriter: LogWriter
    ) {
        self.persistenceStore = persistenceStore
        self.fileSystemRepository = fileSystemRepository
        self.stateMachine = stateMachine
        self.logWriter = logWriter
        var continuation: AsyncStream<RegistryEvent>.Continuation!
        self.eventStream = AsyncStream { continuation = $0 }
        self.eventContinuation = continuation
    }

    // MARK: - Initialization and recovery

    public func initialize() async {
        do {
            let loaded = try await persistenceStore.loadAppData()
            guard let data = loaded.data else {
                if case .restoreAvailable(let path) = loaded.state {
                    libraryState = .recoveryRequired(path)
                } else {
                    libraryState = .recoveryRequired("AppData")
                }
                return
            }

            if data.games.isEmpty {
                games = Self.defaultGames()
                try await persistLibrary()
            } else {
                var needsMigrationWrite = false
                games = data.games.map { game in
                    var migrated = game
                    if game.location?.resolutionState == .migrationRequired {
                        needsMigrationWrite = true
                        migrated.state = .notInstalled
                    }
                    return migrated
                }
                if needsMigrationWrite { try await persistLibrary() }
            }
            let restartRecovery = try await reconcileInterruptedLaunches()
            if let firstRecovery = restartRecovery.first {
                libraryState = .recoveryRequired(firstRecovery.detail)
                await logWriter.error(
                    "发现未完成的游戏进程恢复: \(firstRecovery.detail)",
                    module: "GameRegistry"
                )
            } else {
                libraryState = .loaded
            }
            await logWriter.info("游戏库已加载: \(games.count) 款游戏", module: "GameRegistry")
        } catch let error as PersistenceStore.StoreError {
            libraryState = .recoveryRequired(error.localizedDescription)
            await logWriter.error("游戏库恢复失败: \(error.localizedDescription)", module: "GameRegistry")
        } catch {
            libraryState = .loadingFailed(error.localizedDescription)
            await logWriter.error("游戏库加载失败: \(error.localizedDescription)", module: "GameRegistry")
        }
    }

    public func resetLibrary() async throws {
        let oldGames = games
        games = Self.defaultGames()
        do {
            try await persistLibrary()
            libraryState = .loaded
        } catch {
            games = oldGames
            throw error
        }
    }

    public func getAllGames() -> [Game] { games }
    public func getGame(by id: String) -> Game? { games.first { $0.id == id } }
    public func getGame(by type: GameType) -> Game? { games.first { $0.type == type } }
    public func currentSnapshot() -> (games: [Game], sequence: UInt64, state: LibraryState) {
        (games, sequence, libraryState)
    }

    /// Creates an independent subscription for each UI projection.
    public func makeEventStream() -> AsyncStream<RegistryEvent> {
        let subscriptionID = UUID()
        var continuation: AsyncStream<RegistryEvent>.Continuation!
        let stream = AsyncStream<RegistryEvent> { continuation = $0 }
        continuation.onTermination = { @Sendable [weak self] _ in
            Task { await self?.removeEventSubscriber(subscriptionID) }
        }
        eventSubscribers[subscriptionID] = continuation
        return stream
    }

    // MARK: - Persistence and events

    internal func persistLibrary() async throws {
        do {
            let gamesSnapshot = games
            try await persistenceStore.updateAppData { appData in
                appData.games = gamesSnapshot
            }
        } catch {
            await logWriter.error("游戏库持久化失败: \(error.localizedDescription)", module: "GameRegistry")
            throw RegistrationError.persistenceFailed(error.localizedDescription)
        }
    }

    internal func emit(_ game: Game) {
        sequence += 1
        let event = RegistryEvent(sequence: sequence, game: game)
        eventContinuation?.yield(event)
        for continuation in eventSubscribers.values {
            continuation.yield(event)
        }
    }

    internal func removeEventSubscriber(_ id: UUID) {
        eventSubscribers.removeValue(forKey: id)
    }

    internal nonisolated static func defaultGames() -> [Game] {
        GameType.allCases.map {
            Game(id: $0.rawValue, type: $0, location: nil, state: .notInstalled, version: nil, lastLaunchDate: nil, solutionApplications: [])
        }
    }
}
