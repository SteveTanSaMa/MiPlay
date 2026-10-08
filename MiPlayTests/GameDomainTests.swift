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

    func testGameTypeResolvesNestedExecutableAndDirectExecutableSelection() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let gameDirectory = root.appendingPathComponent("ZenlessZoneZero Game", isDirectory: true)
        try FileManager.default.createDirectory(at: gameDirectory, withIntermediateDirectories: true)
        let executable = gameDirectory.appendingPathComponent("ZenlessZoneZero.exe")
        try Data("fixture".utf8).write(to: executable)

        XCTAssertEqual(
            GameType.zenlessZoneZero.firstExistingExecutable(at: root.path),
            executable.path
        )
        XCTAssertEqual(
            GameType.zenlessZoneZero.resolvedInstallationDirectory(at: root),
            gameDirectory.standardizedFileURL
        )
        XCTAssertEqual(
            GameType.zenlessZoneZero.resolvedInstallationDirectory(at: executable),
            gameDirectory.standardizedFileURL
        )
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

    func testGameRegistryEventSubscribersReceiveCommittedLaunchStateAndDiagnostic() async throws {
        let baseURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: baseURL) }
        let fileSystem = GameFileSystemRepository(appSupportDirectory: try makeTemporaryDirectory())
        let store = PersistenceStore(baseURL: baseURL)
        let registry = GameRegistry(
            persistenceStore: store,
            fileSystemRepository: fileSystem,
            stateMachine: GameStateMachine(),
            systemDetector: SystemEnvironmentDetector(),
            logWriter: LogWriter(fileSystemRepository: fileSystem)
        )
        await registry.initialize()
        let stream = await registry.makeEventStream()
        try await registry.updateGamePath(id: GameType.genshinImpact.rawValue, newPath: "/Games/Genshin")
        try await registry.recordLaunchFailure(
            id: GameType.genshinImpact.rawValue,
            detail: "Wine 未能加载 HoYoKProtect/WDFLDR 内核驱动"
        )

        var events: [GameRegistry.RegistryEvent] = []
        for await event in stream {
            events.append(event)
            if event.game.lastLaunchFailure != nil { break }
        }
        XCTAssertEqual(events.last?.game.lastLaunchFailure, "Wine 未能加载 HoYoKProtect/WDFLDR 内核驱动")
        let persisted = try await store.readAppData()
        XCTAssertEqual(
            persisted.games.first(where: { $0.id == GameType.genshinImpact.rawValue })?.lastLaunchFailure,
            "Wine 未能加载 HoYoKProtect/WDFLDR 内核驱动"
        )
    }

    func testProcessExitCommitPersistsKnownWineDriverDiagnostic() async throws {
        let baseURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: baseURL) }
        let fileSystem = GameFileSystemRepository(appSupportDirectory: try makeTemporaryDirectory())
        let store = PersistenceStore(baseURL: baseURL)
        let gameID = GameType.genshinImpact.rawValue
        let game = Game(
            id: gameID,
            type: .genshinImpact,
            location: GameLocation(
                gameID: gameID,
                bookmarkData: Data([1]),
                lastKnownPath: "/Games/Genshin",
                resolutionState: .resolvable
            ),
            state: .installed,
            version: nil,
            lastLaunchDate: nil,
            solutionApplications: []
        )
        try await store.writeAppData(AppData(games: [game]))
        let registry = GameRegistry(
            persistenceStore: store,
            fileSystemRepository: fileSystem,
            stateMachine: GameStateMachine(),
            systemDetector: SystemEnvironmentDetector(),
            logWriter: LogWriter(fileSystemRepository: fileSystem)
        )
        await registry.initialize()
        try await registry.transitionGame(id: gameID, to: .launching)
        try await registry.recordLaunchConfirmed(id: gameID, date: Date())
        try await registry.commitProcessExit(
            gameID: gameID,
            processID: UUID(),
            statusCode: 1,
            terminatedBySignal: false,
            output: "Library WDFLDR.SYS HoYoKProtect.sys not found"
        )

        let updatedGame = await registry.getGame(by: gameID)
        XCTAssertEqual(updatedGame?.state, .installed)
        let persistedExit = try await store.readAppData()
        XCTAssertEqual(persistedExit.games.first(where: { $0.id == gameID })?.state, .installed)
        XCTAssertEqual(
            updatedGame?.lastLaunchFailure,
            "游戏进程异常退出（退出码 1）；本次日志显示反作弊驱动加载失败，可能存在 Wine 兼容问题"
        )

        // 即使本次日志出现驱动错误，终止信号和缺失状态也不能归因于反作弊。
        for (code, signalled, expected) in [(Int32(9), true, "被强制终止"), (6, true, "崩溃"), (-1, false, "无法区分")] {
            try await registry.transitionGame(id: gameID, to: .launching)
            try await registry.recordLaunchConfirmed(id: gameID, date: Date())
            try await registry.commitProcessExit(
                gameID: gameID, processID: UUID(), statusCode: code,
                terminatedBySignal: signalled, output: "Library WDFLDR.SYS HoYoKProtect.sys not found"
            )
            let exited = await registry.getGame(by: gameID)
            XCTAssertEqual(exited?.state, .installed)
            XCTAssertTrue(exited?.lastLaunchFailure?.contains(expected) == true)
            XCTAssertFalse(exited?.lastLaunchFailure?.contains("反作弊") == true)
        }

        try await registry.transitionGame(id: gameID, to: .launching)
        try await registry.recordLaunchConfirmed(id: gameID, date: Date())
        try await registry.commitProcessExit(
            gameID: gameID, processID: UUID(), statusCode: 0, terminatedBySignal: false
        )
        let normalExit = await registry.getGame(by: gameID)
        XCTAssertEqual(normalExit?.state, .installed)
        XCTAssertNil(normalExit?.lastLaunchFailure)
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
        let runtimeRoot = runtimeDirectory
            .appendingPathComponent("WineVersions", isDirectory: true)
            .appendingPathComponent(WineVersionManager.fixedRuntimeTag, isDirectory: true)
        let binaryDirectory = runtimeRoot.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binaryDirectory, withIntermediateDirectories: true)
        let fileSystem = GameFileSystemRepository(appSupportDirectory: runtimeDirectory)
        let provider = WineRuntimeProvider(processManager: ProcessManager(), fileSystemRepository: fileSystem)
        let gameID = "QA-\(UUID().uuidString)"
        let prefix = await provider.getPrefixPath(for: gameID)

        do {
            _ = try await provider.load(runtimePath: binaryDirectory.path)
            XCTFail("Expected missing Wine binary")
        } catch let error as WineRuntimeProvider.WineError {
            guard case .wineBinaryNotFound = error else {
                return XCTFail("Unexpected Wine error: \(error)")
            }
        }
        XCTAssertTrue(prefix.hasSuffix("WinePrefixes/shared"))
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
        XCTAssertTrue(published.isEmpty)

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

    // MARK: - Unified Wine runtime and shared prefix

    func testUnifiedWineRuntimeIgnoresLegacyPerGameOverrides() async throws {
        let appSupport = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: appSupport) }
        let store = PersistenceStore(baseURL: try makeTemporaryDirectory())
        let pair = try makeFixedWineRuntimePair(appSupport: appSupport)
        try await store.writeAppData(AppData(
            selectedWineVersion: "wine-devel-9.0",
            installedWineVersions: ["wine-devel-9.0"],
            perGameSettings: [
                GameType.genshinImpact.rawValue: PerGameSettings(
                    gameID: GameType.genshinImpact.rawValue,
                    wineVersionOverride: "wine-devel-9.0"
                )
            ],
            managedWineRuntime: pair.runtime,
            sharedWinePrefix: pair.prefix
        ))
        let manager = try makeWineManager(appSupport: appSupport, store: store)
        await manager.initialize()

        let global = await manager.globalWineVersion()
        let override = await manager.wineVersionOverride(for: GameType.genshinImpact.rawValue)
        let genshinEffective = await manager.effectiveVersion(for: GameType.genshinImpact.rawValue)
        let starRailEffective = await manager.effectiveVersion(for: GameType.honkaiStarRail.rawValue)
        XCTAssertEqual(global, WineVersionManager.fixedRuntimeTag)
        XCTAssertNil(override)
        XCTAssertEqual(genshinEffective, WineVersionManager.fixedRuntimeTag)
        XCTAssertEqual(starRailEffective, WineVersionManager.fixedRuntimeTag)

        let persisted = try await store.readAppData()
        XCTAssertNil(persisted.selectedWineVersion)
        XCTAssertTrue(persisted.installedWineVersions.isEmpty)
        XCTAssertNil(persisted.perGameSettings[GameType.genshinImpact.rawValue]?.wineVersionOverride)
    }

    func testAllGamesUseTheSameValidatedSharedWinePrefix() async throws {
        let appSupport = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: appSupport) }
        let store = PersistenceStore(baseURL: try makeTemporaryDirectory())
        let pair = try makeFixedWineRuntimePair(appSupport: appSupport)
        try await store.writeAppData(AppData(
            managedWineRuntime: pair.runtime,
            sharedWinePrefix: pair.prefix
        ))
        let manager = try makeWineManager(appSupport: appSupport, store: store)
        await manager.initialize()

        guard case .ready = await manager.checkReadiness() else {
            return XCTFail("Expected the fixed runtime/shared prefix pair to be ready")
        }
        let validatedPrefix = await manager.validatedSharedPrefix()
        let genshinEffective = await manager.effectiveVersion(for: GameType.genshinImpact.rawValue)
        let starRailEffective = await manager.effectiveVersion(for: GameType.honkaiStarRail.rawValue)
        let zzzEffective = await manager.effectiveVersion(for: GameType.zenlessZoneZero.rawValue)
        XCTAssertEqual(validatedPrefix?.path, pair.prefix.absolutePath)
        XCTAssertEqual(genshinEffective, WineVersionManager.fixedRuntimeTag)
        XCTAssertEqual(starRailEffective, WineVersionManager.fixedRuntimeTag)
        XCTAssertEqual(zzzEffective, WineVersionManager.fixedRuntimeTag)
    }

    func testFixedWineRuntimeDoesNotProvideADeletionPath() async throws {
        let appSupport = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: appSupport) }
        let store = PersistenceStore(baseURL: try makeTemporaryDirectory())
        let manager = try makeWineManager(appSupport: appSupport, store: store)
        await manager.initialize()

        do {
            try await manager.deleteVersion(tagName: WineVersionManager.fixedRuntimeTag)
            XCTFail("Expected the fixed runtime deletion path to be unavailable")
        } catch let error as WineVersionManager.VersionManagerError {
            guard case .recoveryRequired = error else {
                return XCTFail("Unexpected delete error: \(error)")
            }
        }
    }

    private func makeWineManager(
        appSupport: URL,
        store: PersistenceStore
    ) throws -> WineVersionManager {
        let fileSystem = GameFileSystemRepository(appSupportDirectory: appSupport)
        let logger = LogWriter(fileSystemRepository: fileSystem)
        let process = ProcessManager()
        let provider = WineRuntimeProvider(processManager: process, fileSystemRepository: fileSystem)
        return WineVersionManager(
            networkProvider: NetworkDownloadProvider(),
            fileSystemRepository: fileSystem,
            persistenceStore: store,
            wineVersionDownloader: WineVersionDownloader(
                networkProvider: NetworkDownloadProvider(),
                fileSystemRepository: fileSystem,
                processManager: process,
                logWriter: logger
            ),
            logWriter: logger,
            wineRuntimeProvider: provider
        )
    }

}
