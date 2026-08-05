// Source: Implementation maintenance split -> bookmark, authorization, and launch validation
import XCTest
@testable import MiPlay

@MainActor extension MiPlayCoreTests {
    func testStaleBookmarkRefreshWritesBackAndPairsScope() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("YuanShen.exe")
        try Data(
            "printf '%s' \"$0\" > \"$WINEPREFIX/launch-arg\"\nsleep 0.2\nexit 0\n".utf8
        ).write(to: executable)
        try Data("[General]\ngame_version=1.2.3\nchannel=1\nsub_channel=0\ncps=test\n".utf8)
            .write(to: directory.appendingPathComponent("config.ini"))

        let counters = LockedBookmarkCounters()
        let resolver = BookmarkResolver(
            resolve: { _ in
                return .init(url: directory, isStale: true)
            },
            refresh: { url, scope in
                XCTAssertEqual(url, directory)
                XCTAssertEqual(scope, .readOnly)
                counters.incrementRefresh()
                return Data([2])
            },
            startAccessing: { _ in
                counters.incrementStart()
                return true
            },
            stopAccessing: { _ in
                counters.incrementStop()
            }
        )
        let fileSystem = GameFileSystemRepository(
            appSupportDirectory: try makeTemporaryDirectory(),
            bookmarkResolver: resolver
        )
        let store = PersistenceStore(baseURL: try makeTemporaryDirectory())
        let game = Game(
            id: GameType.genshinImpact.rawValue,
            type: .genshinImpact,
            location: GameLocation(
                gameID: GameType.genshinImpact.rawValue,
                bookmarkData: Data([1]),
                lastKnownPath: "/old/Genshin",
                resolutionState: .stale
            ),
            state: .installed,
            version: "1.2.3",
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

        let verifier = FileIntegrityVerifier(fileSystemRepository: fileSystem, gameRegistry: registry)
        _ = try await verifier.verify(game: game)
        let versionChecker = VersionChecker(
            fileSystemRepository: fileSystem,
            networkProvider: NetworkDownloadProvider(),
            logWriter: LogWriter(fileSystemRepository: fileSystem),
            latestVersions: [.genshinImpact: "1.3.0"],
            gameRegistry: registry
        )
        _ = try await versionChecker.checkVersion(for: game)
        await registry.refreshGameState(id: game.id)

        let updated = try await store.readAppData().games.first(where: { $0.id == game.id })
        XCTAssertEqual(updated?.location?.bookmarkData, Data([2]))
        XCTAssertEqual(updated?.location?.lastKnownPath, directory.path)
        let counts = counters.snapshot()
        XCTAssertEqual(counts.0, counts.1)
        XCTAssertGreaterThanOrEqual(counts.0, 3)
        XCTAssertGreaterThanOrEqual(counts.2, 1)
    }

    func testStaleBookmarkWriteFailureDoesNotUseLastKnownPath() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let resolver = BookmarkResolver(
            resolve: { _ in .init(url: directory, isStale: true) },
            refresh: { _, _ in Data([2]) },
            startAccessing: { _ in true },
            stopAccessing: { _ in }
        )
        let fileSystem = GameFileSystemRepository(bookmarkResolver: resolver)
        let store = PersistenceStore(baseURL: try makeTemporaryDirectory())
        let game = Game(
            id: GameType.genshinImpact.rawValue,
            type: .genshinImpact,
            location: GameLocation(
                gameID: GameType.genshinImpact.rawValue,
                bookmarkData: Data([1]),
                lastKnownPath: "/old/Genshin",
                resolutionState: .stale
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
        await store.injectWriteFailure("bookmark 写回失败")

        await registry.refreshGameState(id: game.id)

        let persisted = try await store.readAppData()
        XCTAssertEqual(persisted.games.first?.location?.bookmarkData, Data([1]))
        XCTAssertEqual(persisted.games.first?.location?.lastKnownPath, "/old/Genshin")
        XCTAssertEqual(persisted.games.first?.state, .installed)

        let verifier = FileIntegrityVerifier(fileSystemRepository: fileSystem, gameRegistry: registry)
        do {
            _ = try await verifier.verify(game: game)
            XCTFail("Integrity must not publish a result when bookmark writeback fails")
        } catch let error as FileIntegrityVerifier.VerificationError {
            guard case .bookmarkRefreshPersistenceFailed = error else {
                return XCTFail("Unexpected integrity error: \(error)")
            }
        }

        let checker = VersionChecker(
            fileSystemRepository: fileSystem,
            networkProvider: NetworkDownloadProvider(),
            logWriter: LogWriter(fileSystemRepository: fileSystem),
            latestVersions: [.genshinImpact: "1.3.0"],
            gameRegistry: registry
        )
        do {
            _ = try await checker.checkVersion(for: game)
            XCTFail("Version check must not publish a result when bookmark writeback fails")
        } catch let error as VersionChecker.VersionError {
            guard case .bookmarkRefreshPersistenceFailed = error else {
                return XCTFail("Unexpected version error: \(error)")
            }
        }
    }

    func testRevokedBookmarkDoesNotFallbackAndReauthorizationRestoresState() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("exe".utf8).write(to: directory.appendingPathComponent("YuanShen.exe"))

        let accessState = LockedAccessState(isAllowed: false)
        let counters = LockedBookmarkCounters()
        let resolver = BookmarkResolver(
            resolve: { _ in .init(url: directory, isStale: false) },
            refresh: { _, _ in Data([2]) },
            startAccessing: { _ in
                counters.incrementStart()
                return accessState.value
            },
            stopAccessing: { _ in counters.incrementStop() }
        )
        let fileSystem = GameFileSystemRepository(bookmarkResolver: resolver)
        let store = PersistenceStore(baseURL: try makeTemporaryDirectory())
        let game = Game(
            id: GameType.genshinImpact.rawValue,
            type: .genshinImpact,
            location: GameLocation(
                gameID: GameType.genshinImpact.rawValue,
                bookmarkData: Data([1]),
                lastKnownPath: "/old/Genshin",
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

        await registry.refreshGameState(id: game.id)
        let deniedData = try await store.readAppData()
        let denied = deniedData.games.first(where: { $0.id == game.id })
        XCTAssertEqual(denied?.state, .notInstalled)
        XCTAssertEqual(denied?.location?.resolutionState, .accessDenied)
        XCTAssertEqual(denied?.location?.lastKnownPath, "/old/Genshin")

        accessState.value = true
        await registry.refreshGameState(id: game.id)
        let restoredData = try await store.readAppData()
        let restored = restoredData.games.first(where: { $0.id == game.id })
        XCTAssertEqual(restored?.state, .installed)
        XCTAssertEqual(restored?.location?.resolutionState, .resolvable)
        XCTAssertEqual(restored?.location?.lastKnownPath, directory.path)

        let counts = counters.snapshot()
        XCTAssertEqual(counts.0, 2)
        XCTAssertEqual(counts.1, 1)
    }

}
