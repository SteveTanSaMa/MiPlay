// Source: Implementation maintenance split -> game state, location, registry, and solution domain
import XCTest
@testable import MiPlay

@MainActor extension MiPlayCoreTests {
    func testProcessManagerRejectsMissingExecutable() async throws {
        let manager = ProcessManager()

        do {
            _ = try await manager.launch(executablePath: "/tmp/miplay-no-such-executable")
            XCTFail("Expected missing executable error")
        } catch let error as ProcessManager.ProcessError {
            guard case .executableNotFound = error else {
                return XCTFail("Unexpected process error: \(error)")
            }
        }
    }

    func testGameStateMachineLegalTransitionsAndIllegalTransitions() throws {
        let machine = GameStateMachine()
        let legal: [(GameBusinessState, GameBusinessState)] = [
            (.notInstalled, .installed),
            (.installed, .updateAvailable),
            (.installed, .launching),
            (.installed, .notInstalled),
            (.updateAvailable, .gameUpdating),
            (.updateAvailable, .installed),
            (.updateAvailable, .notInstalled),
            (.gameUpdating, .installed),
            (.gameUpdating, .updateAvailable),
            (.launching, .running),
            (.launching, .launchFailed),
            (.launching, .installed),
            (.running, .installed),
            (.running, .launchFailed),
            (.launchFailed, .installed),
            (.launchFailed, .updateAvailable),
            (.launchFailed, .notInstalled),
            (.launchFailed, .launching)
        ]

        for (from, to) in legal {
            XCTAssertTrue(machine.canTransition(from: from, to: to), "Expected \(from) -> \(to)")
            XCTAssertEqual(try machine.transition(from: from, to: to), to)
        }

        let illegal: [(GameBusinessState, GameBusinessState)] = [
            (.notInstalled, .running),
            (.notInstalled, .launching),
            (.running, .running),
            (.launching, .updateAvailable),
            (.gameUpdating, .running)
        ]
        for (from, to) in illegal {
            XCTAssertFalse(machine.canTransition(from: from, to: to), "Expected \(from) -> \(to) to be rejected")
            XCTAssertThrowsError(try machine.transition(from: from, to: to))
        }
    }

    func testGameStateAndGameTypeDisplayFactsAreLocalized() {
        for state in GameBusinessState.allCases {
            XCTAssertFalse(state.rawValue.isEmpty)
            XCTAssertFalse(GameStateMachine().description(for: state).isEmpty)
            XCTAssertFalse(GameStateMachine().suggestedAction(for: state).isEmpty)
        }
        for gameType in GameType.allCases {
            XCTAssertFalse(gameType.displayName.isEmpty)
            XCTAssertFalse(gameType.englishName.isEmpty)
            XCTAssertFalse(gameType.executableRelativePaths.isEmpty)
        }
    }

    func testLegacyGamePathDecodesAsMigrationRequiredWithoutAuthorization() throws {
        let legacy = """
        {"id":"GenshinImpact","type":"GenshinImpact","installPath":"/Games/Genshin","state":"Installed"}
        """
        let game = try JSONDecoder().decode(Game.self, from: Data(legacy.utf8))

        XCTAssertEqual(game.installPath, "/Games/Genshin")
        XCTAssertEqual(game.location?.resolutionState, .migrationRequired)
        XCTAssertNil(game.location?.bookmarkData)
    }

    func testGameLocationRoundTripPreservesBookmarkAndScope() throws {
        let location = GameLocation(
            gameID: GameType.genshinImpact.rawValue,
            bookmarkData: Data([1, 2, 3]),
            lastKnownPath: "/Games/Genshin",
            scope: .readWrite,
            resolutionState: .resolvable,
            bookmarkVersion: 4
        )
        let data = try JSONEncoder().encode(location)
        let restored = try JSONDecoder().decode(GameLocation.self, from: data)

        XCTAssertEqual(restored, location)
    }

    func testGameRegistryLegacyPathIsNotInstalledUntilBookmarkMigration() async throws {
        let baseURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: baseURL) }
        let store = PersistenceStore(baseURL: baseURL)
        let fileSystem = GameFileSystemRepository(appSupportDirectory: try makeTemporaryDirectory())
        let logger = LogWriter(fileSystemRepository: fileSystem)
        let registry = GameRegistry(
            persistenceStore: store,
            fileSystemRepository: fileSystem,
            stateMachine: GameStateMachine(),
            systemDetector: SystemEnvironmentDetector(),
            logWriter: logger
        )

        await registry.initialize()
        try await registry.updateGamePath(id: GameType.genshinImpact.rawValue, newPath: "/Legacy/Genshin")

        let game = await registry.getGame(by: GameType.genshinImpact)
        XCTAssertEqual(game?.state, .notInstalled)
        XCTAssertEqual(game?.location?.resolutionState, .migrationRequired)
        XCTAssertNil(game?.location?.bookmarkData)

        let persisted = try await store.readAppData()
        XCTAssertEqual(persisted.games.first(where: { $0.type == .genshinImpact })?.state, .notInstalled)
    }

    func testPersistenceRejectsUnsupportedSchemaAndInvalidFilename() async throws {
        let baseURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: baseURL) }
        let store = PersistenceStore(baseURL: baseURL)
        let appDataURL = baseURL.appendingPathComponent("AppData.json")
        try Data("{\"schemaVersion\":999}".utf8).write(to: appDataURL)

        do {
            _ = try await store.loadAppData()
            XCTFail("Expected unsupported schema")
        } catch let error as PersistenceStore.StoreError {
            guard case .unsupportedSchema(999) = error else {
                return XCTFail("Unexpected persistence error: \(error)")
            }
        }

        do {
            try await store.write(AppData(), to: "../AppData")
            XCTFail("Expected invalid filename rejection")
        } catch let error as PersistenceStore.StoreError {
            guard case .writeFailed = error else {
                return XCTFail("Unexpected persistence error: \(error)")
            }
        }
    }

    func testPersistenceWriteFailsWhenBasePathIsAFile() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileURL = root.appendingPathComponent("not-a-directory")
        try Data("file".utf8).write(to: fileURL)
        let store = PersistenceStore(baseURL: fileURL)

        do {
            try await store.writeAppData(AppData())
            XCTFail("Expected write failure")
        } catch let error as PersistenceStore.StoreError {
            guard case .writeFailed = error else {
                return XCTFail("Unexpected persistence error: \(error)")
            }
        }
    }

    func testIntegrityVerifierRejectsManifestPathEscape() async throws {
        let baseURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: baseURL) }
        let outsideURL = baseURL.deletingLastPathComponent().appendingPathComponent("outside.bin")
        defer { try? FileManager.default.removeItem(at: outsideURL) }
        try Data("outside".utf8).write(to: outsideURL)

        let manifest = FileIntegrityVerifier.Manifest(
            gameID: GameType.genshinImpact.rawValue,
            files: ["../outside.bin": "irrelevant"]
        )
        let verifier = FileIntegrityVerifier(
            fileSystemRepository: GameFileSystemRepository(),
            manifests: [.genshinImpact: manifest]
        )
        let result = try await verifier.verify(gameType: .genshinImpact, installPath: baseURL.path)

        XCTAssertEqual(result.status, .failed)
        XCTAssertEqual(result.missingFiles, ["../outside.bin"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: baseURL.appendingPathComponent("outside.bin").path))
    }

    func testWineRuntimeProviderRejectsMissingBinaryAndBuildsStablePrefixPath() async throws {
        let runtimeDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: runtimeDirectory) }
        let fileSystem = GameFileSystemRepository()
        let provider = WineRuntimeProvider(processManager: ProcessManager(), fileSystemRepository: fileSystem)
        let gameID = "QA-\(UUID().uuidString)"
        let prefix = await provider.getPrefixPath(for: gameID)

        do {
            _ = try await provider.load(runtimePath: runtimeDirectory.path)
            XCTFail("Expected missing Wine binary")
        } catch let error as WineRuntimeProvider.WineError {
            guard case .wineBinaryNotFound = error else {
                return XCTFail("Unexpected Wine error: \(error)")
            }
        }
        XCTAssertTrue(prefix.contains("WinePrefixes/\(gameID)"))
    }

    func testSolutionEngineOnlyExposesPublishedManifestAndFailsBeforeSideEffect() async throws {
        let fileSystem = GameFileSystemRepository()
        let engine = SolutionEngine(
            fileSystemRepository: fileSystem,
            processManager: ProcessManager(),
            systemDetector: SystemEnvironmentDetector(),
            logWriter: LogWriter(fileSystemRepository: fileSystem)
        )
        let game = Game(
            id: GameType.genshinImpact.rawValue,
            type: .genshinImpact,
            installPath: nil,
            state: .installed,
            version: nil,
            lastLaunchDate: nil,
            solutionApplications: []
        )

        let published = await engine.getSolutions(for: game)
        XCTAssertEqual(Set(published.map(\.id)), ["modify_hostname"])

        do {
            _ = try await engine.applySolution(solutionId: "block_network_anticheat", for: game)
            XCTFail("Expected deferred solution rejection")
        } catch let error as SolutionEngine.SolutionError {
            guard case .solutionNotFound = error else {
                return XCTFail("Unexpected solution error: \(error)")
            }
        }
    }

    func testSolutionEngineRejectsRollbackFromRolledBackState() async throws {
        let fileSystem = GameFileSystemRepository()
        let engine = SolutionEngine(
            fileSystemRepository: fileSystem,
            processManager: ProcessManager(),
            systemDetector: SystemEnvironmentDetector(),
            logWriter: LogWriter(fileSystemRepository: fileSystem)
        )
        let game = Game(
            id: GameType.genshinImpact.rawValue,
            type: .genshinImpact,
            installPath: nil,
            state: .installed,
            version: nil,
            lastLaunchDate: nil,
            solutionApplications: []
        )
        let application = SolutionApplication(
            id: "application-1",
            solutionId: "modify_hostname",
            gameId: game.id,
            appliedDate: Date(),
            state: .rolledBack
        )

        do {
            try await engine.rollbackSolution(application: application, game: game)
            XCTFail("Expected invalid rollback state")
        } catch let error as SolutionEngine.SolutionError {
            guard case .invalidState = error else {
                return XCTFail("Unexpected solution error: \(error)")
            }
        }
    }

}
