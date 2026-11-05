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

/// Actor owning the built-in Game aggregates and their committed facts.
public actor GameRegistry {
    /// Versions before catalog tracking shipped with exactly these games.
    /// Keep this baseline fixed when adding future games so users upgrading
    /// across multiple releases still receive newly introduced entries.
    private nonisolated static let legacyBuiltInGameTypes = [
        "GenshinImpact", "HonkaiStarRail", "ZenlessZoneZero"
    ]
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

            var catalogMigrationFailure: Error?
            // Other services can write an otherwise empty AppData before the
            // registry initializes. Preserve the original first-run behavior
            // for such legacy snapshots, while a tracked empty library means
            // the user deliberately removed every built-in game.
            if loaded.state == .initialData || (data.games.isEmpty && data.knownBuiltInGameTypes == nil) {
                let previousGames = games
                games = Self.defaultGames()
                do {
                    try await persistLibrary(knownBuiltInGameTypes: GameType.allCases.map(\.rawValue))
                } catch {
                    games = previousGames
                    throw error
                }
            } else {
                // Existing libraries may intentionally omit a supported game.
                // Only games introduced since the last recorded catalog are
                // appended; a deleted older game must stay deleted.
                let oldCatalog = data.knownBuiltInGameTypes ?? Self.legacyBuiltInGameTypes
                let seenTypes = Set(oldCatalog)
                let existingTypes = Set(data.games.map { $0.type.rawValue })
                let existingIDs = Set(data.games.map(\.id))
                let newDefaults = Self.defaultGames().filter {
                    !seenTypes.contains($0.type.rawValue) && !existingTypes.contains($0.type.rawValue)
                }
                if let collision = newDefaults.first(where: { existingIDs.contains($0.id) }) {
                    games = data.games
                    catalogMigrationFailure = RegistrationError.recoveryRequired("新游戏的标识已被现有记录占用：\(collision.id)")
                } else {
                    var needsMigrationWrite = data.knownBuiltInGameTypes == nil || !newDefaults.isEmpty
                    var updatedCatalog = oldCatalog
                    for game in Self.defaultGames() where !seenTypes.contains(game.type.rawValue) {
                        updatedCatalog.append(game.type.rawValue)
                        needsMigrationWrite = true
                    }
                    games = data.games.map { game in
                        var migrated = game
                        if game.location?.resolutionState == .migrationRequired {
                            needsMigrationWrite = true
                            migrated.state = .notInstalled
                        }
                        return migrated
                    }
                    games.append(contentsOf: newDefaults)
                    if needsMigrationWrite {
                        do { try await persistLibrary(knownBuiltInGameTypes: updatedCatalog) }
                        catch {
                            // Recovery of a previously running game is more
                            // urgent than catalog migration. Use only durable
                            // original facts while creating recovery guards,
                            // then surface this failure if recovery is clear.
                            games = data.games
                            catalogMigrationFailure = error
                        }
                    }
                }
            }
            let restartRecovery = try await reconcileInterruptedLaunches()
            if let firstRecovery = restartRecovery.first {
                libraryState = .recoveryRequired(firstRecovery.detail)
                await logWriter.error(
                    "发现未完成的游戏进程恢复: \(firstRecovery.detail)",
                    module: "GameRegistry"
                )
            } else if let catalogMigrationFailure {
                throw catalogMigrationFailure
            } else {
                libraryState = .loaded
            }
            await logWriter.info("游戏库已加载: \(games.count) 款游戏", module: "GameRegistry")
        } catch let error as RegistrationError {
            if case .recoveryRequired(let detail) = error {
                libraryState = .recoveryRequired(detail)
            } else {
                libraryState = .loadingFailed(error.localizedDescription)
            }
            await logWriter.error("游戏库加载失败: \(error.localizedDescription)", module: "GameRegistry")
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

    internal func persistLibrary(knownBuiltInGameTypes: [String]? = nil) async throws {
        do {
            let gamesSnapshot = games
            try await persistenceStore.updateAppData { appData in
                appData.games = gamesSnapshot
                if let knownBuiltInGameTypes {
                    appData.knownBuiltInGameTypes = knownBuiltInGameTypes
                }
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
