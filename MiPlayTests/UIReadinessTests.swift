// Source: Implementation maintenance split -> UI state and accessibility contracts
import XCTest
@testable import MiPlay

@MainActor extension MiPlayCoreTests {
    func testPredownloadDiscoveryAndSubmissionKeepInstalledGameState() async throws {
        let game = gameForDownloadPresentation()
        let fixture = try await makeScheduler(games: [game])
        let model = LibraryViewModel(gameRegistry: fixture.registry, launchOrchestrator: fixture.launchOrchestrator,
                                     persistenceStore: fixture.persistence, taskScheduler: fixture.scheduler,
                                     logWriter: fixture.logger, predownloadLookup: { type in
            type == .genshinImpact ? "2.0.0" : nil
        })
        await model.refreshGames()
        await model.refreshPredownloadAvailability(for: .genshinImpact)
        XCTAssertEqual(model.gamePredownloadVersions[game.id], "2.0.0")
        XCTAssertTrue(model.canStartPredownload(for: game.id))
        await model.startPredownload(for: game.id)
        let tasks = await fixture.scheduler.allTaskSnapshots()
        let task = try XCTUnwrap(tasks.first { $0.type == .gamePredownload })
        XCTAssertEqual(task.context["predownloadVersion"], "2.0.0")
        let snapshot = await fixture.registry.getGame(by: game.id)
        XCTAssertEqual(snapshot?.state, .installed)
        XCTAssertEqual(snapshot?.version, "1.0.0")
        var running = game
        running.state = .running
        XCTAssertTrue(GameDownloadPresentation.canPredownload(running))
        var interrupted = task
        interrupted.state = .failed
        XCTAssertTrue(GameDownloadPresentation.canResume(interrupted, for: running))
    }

    func testPredownloadHistoryIsBoundToTheSelectedDirectory() throws {
        var game = gameForDownloadPresentation()
        let bookmark = try XCTUnwrap(game.location?.bookmarkData)
        let path = try XCTUnwrap(game.location?.lastKnownPath)
        var task = ScheduledTask(type: .gamePredownload, gameId: game.id, context: [
            "predownloadVersion": "2.0.0", "predownloadLocationPath": path,
            "predownloadLocationBookmark": bookmark.base64EncodedString()
        ])
        task.state = .completed
        task.outcome = "gamePredownloaded"
        XCTAssertTrue(GameDownloadPresentation.resultConfirmed(for: task, game: game))
        game.location?.lastKnownPath = "/other-game-directory"
        XCTAssertFalse(GameDownloadPresentation.resultConfirmed(for: task, game: game))
        task.state = .failed
        game.location?.bookmarkData = Data("different-bookmark".utf8)
        XCTAssertFalse(GameDownloadPresentation.canResume(task, for: game))
    }
    func testLocateInterruptedTransactionRegistersRecoveryWithoutExecutable() async throws {
        let parent = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: parent) }
        let otherDirectory = parent.appendingPathComponent("Another Game", isDirectory: true)
        let otherTransaction = otherDirectory.appendingPathComponent(SophonInstaller.transactionDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: otherTransaction, withIntermediateDirectories: true)
        let otherJournal: [String: Any] = ["version": 1, "game": GameType.genshinImpact.rawValue,
                                           "destination": otherDirectory.resolvingSymlinksInPath().path,
                                           "committed": false, "operations": [], "createdDirectories": []]
        try JSONSerialization.data(withJSONObject: otherJournal).write(to: otherTransaction.appendingPathComponent("journal.json"))
        let gameDirectory = parent.appendingPathComponent("ZenlessZoneZero Game", isDirectory: true)
        let transaction = gameDirectory.appendingPathComponent(SophonInstaller.transactionDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: transaction, withIntermediateDirectories: true)
        let journal: [String: Any] = ["version": 1, "game": GameType.zenlessZoneZero.rawValue,
                                      "destination": gameDirectory.resolvingSymlinksInPath().path,
                                      "committed": false, "operations": [], "createdDirectories": []]
        try JSONSerialization.data(withJSONObject: journal).write(to: transaction.appendingPathComponent("journal.json"))
        let selected = try directoryURLWithNativeSecurityScope(parent)
        var game = gameForDownloadPresentation(type: .zenlessZoneZero)
        game.state = .notInstalled
        game.location = nil
        let store = PersistenceStore(baseURL: try makeTemporaryDirectory())
        let registry = try await registryForDirectoryAuthorizationTests(game: game, store: store)
        let registered = try await registry.locateGame(type: .zenlessZoneZero, selectedURL: selected)
        XCTAssertEqual(registered.state, .gameUpdating)
        let registeredPath = try XCTUnwrap(registered.location?.lastKnownPath)
        let registeredAttributes = try FileManager.default.attributesOfItem(atPath: registeredPath)
        let expectedAttributes = try FileManager.default.attributesOfItem(atPath: gameDirectory.path)
        let registeredFileID = try XCTUnwrap(registeredAttributes[.systemFileNumber] as? NSNumber)
        let expectedFileID = try XCTUnwrap(expectedAttributes[.systemFileNumber] as? NSNumber)
        XCTAssertEqual(registeredFileID, expectedFileID)
        XCTAssertEqual(registeredAttributes[.systemNumber] as? NSNumber, expectedAttributes[.systemNumber] as? NSNumber)
        XCTAssertNotNil(registered.location?.bookmarkData)
        XCTAssertTrue(FileManager.default.fileExists(atPath: transaction.path), "定位不得绕过调度器恢复事务")
        XCTAssertTrue(FileManager.default.fileExists(atPath: otherTransaction.path), "其他游戏事务必须保留")
        let persisted = try await store.readAppData().games.first { $0.id == game.id }
        XCTAssertEqual(persisted?.state, .gameUpdating)
    }

    func testLocateRejectsUnrecognizedTransactionWithoutChangingGame() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data().write(to: directory.appendingPathComponent("ZenlessZoneZero.exe"))
        let transaction = directory.appendingPathComponent(SophonInstaller.transactionDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: transaction, withIntermediateDirectories: true)
        let selected = try directoryURLWithNativeSecurityScope(directory)
        var game = gameForDownloadPresentation(type: .zenlessZoneZero)
        game.state = .notInstalled
        game.location = nil
        let store = PersistenceStore(baseURL: try makeTemporaryDirectory())
        let registry = try await registryForDirectoryAuthorizationTests(game: game, store: store)
        do {
            _ = try await registry.locateGame(type: .zenlessZoneZero, selectedURL: selected)
            XCTFail("未知事务不能当作游戏已安装或覆盖")
        } catch let error as GameRegistry.RegistrationError {
            guard case .recoveryRequired = error else { return XCTFail("Unexpected error: \(error)") }
        }
        let current = await registry.getGame(by: game.id)
        XCTAssertEqual(current?.state, .notInstalled)
        XCTAssertNil(current?.location)
        XCTAssertTrue(FileManager.default.fileExists(atPath: transaction.path))
    }

    func testLocatedInterruptedGameRecoversThroughScheduler() async throws {
        for scenario in ["restore", "missing", "modified"] {
            let parent = try makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: parent) }
            let directory = parent.appendingPathComponent("ZenlessZoneZero Game", isDirectory: true)
            let transaction = directory.appendingPathComponent(SophonInstaller.transactionDirectoryName, isDirectory: true)
            let backup = transaction.appendingPathComponent("backup", isDirectory: true)
            try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
            var operations: [[String: Any]] = []
            if scenario != "missing" {
                let original = Data("original executable".utf8)
                try original.write(to: backup.appendingPathComponent("ZenlessZoneZero.exe"))
                if scenario == "modified" {
                    try Data("user changed".utf8).write(to: directory.appendingPathComponent("ZenlessZoneZero.exe"))
                }
                operations = [["path": "ZenlessZoneZero.exe", "hadExisting": true,
                               "installedMD5": SophonMetadataClient.md5(Data("updated executable".utf8))]]
            }
            let journal: [String: Any] = ["version": 1, "game": GameType.zenlessZoneZero.rawValue,
                                          "destination": directory.resolvingSymlinksInPath().path,
                                          "committed": false, "operations": operations, "createdDirectories": []]
            try JSONSerialization.data(withJSONObject: journal).write(to: transaction.appendingPathComponent("journal.json"))
            var game = gameForDownloadPresentation(type: .zenlessZoneZero)
            game.state = .notInstalled
            game.location = nil
            let fixture = try await makeScheduler(games: [game])
            let selected = try directoryURLWithNativeSecurityScope(parent)
            let registered = try await fixture.registry.locateGame(type: .zenlessZoneZero, selectedURL: selected)
            XCTAssertEqual(registered.state, .gameUpdating)
            let taskID = try await fixture.scheduler.enqueue(type: .gameUpdate, gameId: game.id,
                                                             context: ["recoveryOnly": "true"])
            let result = try await waitForTask(taskID, scheduler: fixture.scheduler)
            let after = await fixture.registry.getGame(by: game.id)
            if scenario == "modified" {
                XCTAssertEqual(result.state, .failed)
                XCTAssertEqual(after?.state, .gameUpdating)
                XCTAssertTrue(FileManager.default.fileExists(atPath: transaction.path))
                XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("ZenlessZoneZero.exe"), encoding: .utf8), "user changed")
            } else {
                XCTAssertEqual(result.state, .completed)
                XCTAssertEqual(result.outcome, "gameRecovered")
                XCTAssertEqual(after?.state, scenario == "restore" ? .installed : .notInstalled)
                XCTAssertFalse(FileManager.default.fileExists(atPath: transaction.path))
                if scenario == "restore" {
                    XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("ZenlessZoneZero.exe"), encoding: .utf8), "original executable")
                }
            }
        }
    }

    func testUnitTestHostIsolationIsEnabledOnlyByTestEnvironment() {
        XCTAssertTrue(UnitTestHost.isEnabled(), "Test scheme must mark its application host as a test process")
        XCTAssertTrue(UnitTestHost.isEnabled(environment: ["MIPLAY_UNIT_TEST_HOST": "1"]))
        XCTAssertFalse(UnitTestHost.isEnabled(environment: [:]))
        XCTAssertFalse(UnitTestHost.isEnabled(environment: ["MIPLAY_UNIT_TEST_HOST": "0"]))
    }

    func testIntegrityPresentationNeverShowsOldEvidenceForUnfinishedOrFailedTask() {
        var task = ScheduledTask(type: .versionCheck, gameId: GameType.genshinImpact.rawValue,
                                 context: ["fileVerification": "true"])
        XCTAssertEqual(IntegrityCheckPresentation.status(for: nil), .showEvidence)
        XCTAssertEqual(IntegrityCheckPresentation.status(for: task), .inProgress)
        task.state = .running
        XCTAssertEqual(IntegrityCheckPresentation.status(for: task), .inProgress)
        task.state = .failed
        task.error = "读取清单失败"
        XCTAssertEqual(IntegrityCheckPresentation.status(for: task), .failed("读取清单失败"))
        task.state = .cancelled
        XCTAssertEqual(IntegrityCheckPresentation.status(for: task), .cancelled)
        task.state = .completed
        XCTAssertEqual(IntegrityCheckPresentation.status(for: task), .showEvidence)
    }

    func testRefreshPreservesInterruptedUpdateWithRevokedScopeOrMissingExecutable() async throws {
        for revoked in [true, false] {
            let directory = try makeTemporaryDirectory()
            defer { try? FileManager.default.removeItem(at: directory) }
            let executable = directory.appendingPathComponent("YuanShen.exe")
            if revoked { try Data("fixture, never launched".utf8).write(to: executable) }
            XCTAssertEqual(FileManager.default.fileExists(atPath: executable.path), revoked)
            let counts = LockedBookmarkCounters()
            let repository = GameFileSystemRepository(
                appSupportDirectory: try makeTemporaryDirectory(),
                bookmarkResolver: BookmarkResolver(
                    resolve: { _ in .init(url: directory, isStale: false) },
                    refresh: { _, _ in Data([2]) },
                    startAccessing: { _ in counts.incrementStart(); return !revoked },
                    stopAccessing: { _ in counts.incrementStop() }
                )
            )
            var game = gameForDownloadPresentation()
            game.state = .gameUpdating
            game.location?.lastKnownPath = directory.path
            game.location?.bookmarkData = Data([1])
            let store = PersistenceStore(baseURL: try makeTemporaryDirectory())
            try await store.writeAppData(AppData(games: [game]))
            let registry = GameRegistry(persistenceStore: store, fileSystemRepository: repository,
                                        stateMachine: GameStateMachine(), systemDetector: SystemEnvironmentDetector(),
                                        logWriter: LogWriter(fileSystemRepository: repository))
            await registry.initialize()
            let originalSnapshot = await registry.getGame(by: game.id)
            let before = try XCTUnwrap(originalSnapshot)
            await registry.refreshGameState(id: game.id)
            let refreshedSnapshot = await registry.getGame(by: game.id)
            let after = try XCTUnwrap(refreshedSnapshot)
            let persisted = try await store.readAppData().games.first(where: { $0.id == game.id })
            XCTAssertEqual(after, before, revoked ? "撤销授权不能抹去更新恢复状态" : "提交中的可执行文件暂缺不能变成未安装")
            XCTAssertEqual(after.state, .gameUpdating)
            XCTAssertEqual(after.location?.lastKnownPath, directory.path)
            XCTAssertEqual(after.location?.bookmarkData, Data([1]))
            XCTAssertEqual(persisted, before)
            XCTAssertTrue(GameDownloadPresentation.canReauthorizeDirectory(for: after))
            XCTAssertEqual(counts.snapshot().0, 0, "中断更新不能进入常规游戏就绪扫描")
        }
    }

    func testPendingGameReauthorizationRejectsInstalledOrMissingOriginalPathWithoutMutation() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        for missingPath in [false, true] {
            var game = gameForDownloadPresentation()
            if missingPath {
                game.state = .gameUpdating
                game.location?.lastKnownPath = nil
            }
            let store = PersistenceStore(baseURL: try makeTemporaryDirectory())
            let registry = try await registryForDirectoryAuthorizationTests(game: game, store: store)
            let before = await registry.getGame(by: game.id)
            let persistedBefore = try await store.readAppData().games
            do {
                try await registry.reauthorizePendingGame(id: game.id, selectedURL: directory)
                XCTFail("Expected reauthorization rejection")
            } catch let error as GameRegistry.RegistrationError {
                guard case .recoveryRequired = error else { return XCTFail("Unexpected error: \(error)") }
            }
            let after = await registry.getGame(by: game.id)
            let persistedAfter = try await store.readAppData().games
            XCTAssertEqual(after, before)
            XCTAssertEqual(persistedAfter, persistedBefore)
        }
    }

    func testPendingGameReauthorizationRejectsDifferentDirectoryWithoutMutation() async throws {
        let original = try makeTemporaryDirectory()
        let other = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: original); try? FileManager.default.removeItem(at: other) }
        let selected = try directoryURLWithNativeSecurityScope(other)
        var game = gameForDownloadPresentation()
        game.state = .gameUpdating
        game.location?.lastKnownPath = original.path
        let store = PersistenceStore(baseURL: try makeTemporaryDirectory())
        let registry = try await registryForDirectoryAuthorizationTests(game: game, store: store)
        let before = await registry.getGame(by: game.id)
        let persistedBefore = try await store.readAppData().games
        do {
            try await registry.reauthorizePendingGame(id: game.id, selectedURL: selected)
            XCTFail("Expected a different directory to be rejected")
        } catch let error as GameRegistry.RegistrationError {
            guard case .invalidPath = error else { return XCTFail("Unexpected error: \(error)") }
        }
        let after = await registry.getGame(by: game.id)
        let persistedAfter = try await store.readAppData().games
        XCTAssertEqual(after, before)
        XCTAssertEqual(persistedAfter, persistedBefore)
    }

    func testLocateGameCommitsInstalledVersionWithLocationAtomicallyAndRollsBackOnFailure() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("fixture executable, never launched".utf8).write(to: directory.appendingPathComponent("YuanShen.exe"))
        let selected = try directoryURLWithNativeSecurityScope(directory)
        for failWrite in [false, true] {
            var game = gameForDownloadPresentation()
            game.state = .notInstalled
            game.location = nil
            game.version = nil
            game.lastMetadata = nil
            let store = PersistenceStore(baseURL: try makeTemporaryDirectory())
            let registry = try await registryForDirectoryAuthorizationTests(game: game, store: store)
            let before = await registry.getGame(by: game.id)
            let persistedBefore = try await store.readAppData().games
            let stream = await registry.makeEventStream()
            if failWrite { await store.injectWriteFailure("atomic registration fixture") }
            do {
                let installed = try await registry.locateGame(type: game.type, selectedURL: selected, installedVersion: "9.9.9")
                XCTAssertFalse(failWrite)
                XCTAssertEqual(installed.state, .installed)
                XCTAssertEqual(installed.version, "9.9.9")
                XCTAssertNotNil(installed.location?.bookmarkData)
                let persisted = try await store.readAppData().games.first(where: { $0.id == game.id })
                XCTAssertEqual(persisted?.state, .installed)
                XCTAssertEqual(persisted?.version, "9.9.9")
                XCTAssertEqual(persisted?.location?.bookmarkData, installed.location?.bookmarkData)
                var events = stream.makeAsyncIterator()
                let event = await events.next()
                XCTAssertEqual(event?.game.state, .installed)
                XCTAssertEqual(event?.game.version, "9.9.9", "不得先发布已安装但版本仍为空的中间状态")
            } catch {
                guard failWrite else { throw error }
                let after = await registry.getGame(by: game.id)
                let persistedAfter = try await store.readAppData().games
                XCTAssertEqual(after, before)
                XCTAssertEqual(persistedAfter, persistedBefore)
            }
        }
    }

    private func registryForDirectoryAuthorizationTests(game: Game, store: PersistenceStore) async throws -> GameRegistry {
        try await store.writeAppData(AppData(games: [game]))
        let repository = GameFileSystemRepository(appSupportDirectory: try makeTemporaryDirectory())
        let registry = GameRegistry(persistenceStore: store, fileSystemRepository: repository,
                                    stateMachine: GameStateMachine(), systemDetector: SystemEnvironmentDetector(),
                                    logWriter: LogWriter(fileSystemRepository: repository))
        await registry.initialize()
        return registry
    }

    /// These commands require a real user-selected URL before the injectable
    /// bookmark resolver is reached. Never manufacture a successful scope.
    private func directoryURLWithNativeSecurityScope(_ directory: URL) throws -> URL {
        do {
            let bookmark = try directory.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
            var stale = false
            let selected = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale)
            guard selected.startAccessingSecurityScopedResource() else {
                throw XCTSkip("测试宿主无法为临时目录取得原生security scope；需要可授权的macOS测试宿主。")
            }
            selected.stopAccessingSecurityScopedResource()
            return selected
        } catch let skipped as XCTSkip { throw skipped }
        catch { throw XCTSkip("测试宿主无法创建原生目录授权：\(error.localizedDescription)") }
    }

    func testGameDirectoryReauthorizationOnlyAvailableForInactiveInterruptedUpdate() {
        var game = gameForDownloadPresentation()
        for state in GameBusinessState.allCases {
            game.state = state
            XCTAssertEqual(GameDownloadPresentation.canReauthorizeDirectory(for: game), state == .gameUpdating)
        }
        game.state = .gameUpdating
        for state in [ScheduledTaskState.pending, .running, .completed, .failed, .cancelled] {
            var task = ScheduledTask(type: .gameUpdate, gameId: game.id)
            task.state = state
            XCTAssertEqual(GameDownloadPresentation.canReauthorizeDirectory(for: game, task: task), state != .pending && state != .running)
        }
        game.location?.bookmarkData = nil
        XCTAssertTrue(GameDownloadPresentation.canReauthorizeDirectory(for: game), "旧授权丢失时仍可通过原目录重新授权")
        game.location?.lastKnownPath = nil
        XCTAssertFalse(GameDownloadPresentation.canReauthorizeDirectory(for: game), "没有原目录事实时不能把新目录当作原目录")
    }

    func testMainlandConfirmationRejectsRelocatedGameBeforeEnqueue() async throws {
        let game = gameForDownloadPresentation(type: .honkaiStarRail)
        let capturedBookmark = game.location?.bookmarkData
        let store = PersistenceStore(baseURL: try makeTemporaryDirectory())
        let oldID = "old-confirmation-update"
        let record = PersistedTaskRecord(
            id: oldID, type: ScheduledTaskType.gameUpdate.rawValue, gameID: game.id,
            status: ScheduledTaskState.cancelled.rawValue, phase: "已取消", progress: nil,
            outcome: "downloadInterrupted", error: nil, recovery: nil, createdAt: Date(timeIntervalSince1970: 1)
        )
        try await store.writeAppData(AppData(games: [game], taskHistory: [record]))
        let fixture = try await makeScheduler(store: store)
        let model = makeDownloadSettingsModel(fixture: fixture, repository: GameFileSystemRepository())
        await model.loadSettings()
        var relocated = try XCTUnwrap(game.location)
        relocated.bookmarkData = Data("different-directory-bookmark".utf8)
        relocated.lastKnownPath = "/tmp/different-directory"
        try await fixture.registry.updateResolvedLocation(id: game.id, location: relocated)

        await model.updateGame(for: game.id, confirmedMainland: true, confirmedLocationBookmark: capturedBookmark)
        XCTAssertTrue(model.errorMessage?.contains("目录已变化") == true)
        await model.resumeGameDownload(for: game.id, confirmedMainland: true, confirmedLocationBookmark: capturedBookmark)
        XCTAssertTrue(model.errorMessage?.contains("目录已变化") == true)
        let tasks = await fixture.scheduler.allTaskSnapshots()
        XCTAssertEqual(tasks.filter { $0.type == .gameUpdate }.count, 1, "旧弹窗确认不能授权新目录")
        XCTAssertEqual(tasks.first(where: { $0.type == .gameUpdate })?.id.id, oldID)
    }

    func testGameDownloadResumeRequiresInterruptedMatchingTaskAndStoredAuthorization() {
        var game = gameForDownloadPresentation()
        game.state = .notInstalled
        let context = ["installBookmark": Data([1]).base64EncodedString(), "installPath": "/display-only"]
        for state in [ScheduledTaskState.pending, .running, .completed, .failed, .cancelled] {
            var task = ScheduledTask(type: .gameInstall, gameId: game.id, context: context)
            task.state = state
            XCTAssertEqual(GameDownloadPresentation.canResume(task, for: game), state == .failed || state == .cancelled)
        }
        var missingBookmark = ScheduledTask(type: .gameInstall, gameId: game.id, context: ["installPath": "/display-only"])
        missingBookmark.state = .failed
        XCTAssertFalse(GameDownloadPresentation.canResume(missingBookmark, for: game))
        var wrongGame = ScheduledTask(type: .gameInstall, gameId: "another-game", context: context)
        wrongGame.state = .cancelled
        XCTAssertFalse(GameDownloadPresentation.canResume(wrongGame, for: game))
    }

    func testGameInstallResumeRefreshesBookmarkWithoutTrustingHistoricalPath() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let counters = LockedBookmarkCounters()
        let repository = GameFileSystemRepository(bookmarkResolver: BookmarkResolver(
            resolve: { data in
                XCTAssertEqual(data, Data([1]))
                return .init(url: directory, isStale: true)
            },
            refresh: { _, scope in
                XCTAssertEqual(scope, .readWrite)
                counters.incrementRefresh()
                return Data([2])
            },
            startAccessing: { _ in counters.incrementStart(); return true },
            stopAccessing: { _ in counters.incrementStop() }
        ))
        var game = gameForDownloadPresentation()
        game.state = .notInstalled
        var task = ScheduledTask(type: .gameInstall, gameId: game.id, context: [
            "installBookmark": Data([1]).base64EncodedString(), "installPath": "/untrusted-display-path", "preserved": "yes"
        ])
        task.state = .cancelled
        let context = try GameDownloadPresentation.refreshedInstallContext(from: task, game: game, repository: repository)
        XCTAssertEqual(context["installBookmark"], Data([2]).base64EncodedString())
        XCTAssertEqual(context["installPath"], directory.path)
        XCTAssertEqual(context["preserved"], "yes")
        let counts = counters.snapshot()
        XCTAssertEqual(counts.0, 1)
        XCTAssertEqual(counts.1, 1)
        XCTAssertEqual(counts.2, 1)
    }

    func testGameInstallResumeRejectsRevokedAuthorizationWithoutPathFallback() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let repository = GameFileSystemRepository(bookmarkResolver: BookmarkResolver(
            resolve: { _ in .init(url: directory, isStale: false) },
            refresh: { _, _ in Data([2]) }, startAccessing: { _ in false }, stopAccessing: { _ in }
        ))
        var game = gameForDownloadPresentation()
        game.state = .notInstalled
        var task = ScheduledTask(type: .gameInstall, gameId: game.id, context: [
            "installBookmark": Data([1]).base64EncodedString(), "installPath": directory.path
        ])
        task.state = .failed
        XCTAssertThrowsError(try GameDownloadPresentation.refreshedInstallContext(from: task, game: game, repository: repository))
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    func testInterruptedUpdateWithoutMetadataRequiresConfirmationAndRejectsKnownConflicts() {
        for type in GameType.allCases {
            var game = gameForDownloadPresentation(type: type)
            game.state = .gameUpdating
            game.lastMetadata = nil
            game.metadataFailure = "更新中断后无法读取版本证据"
            XCTAssertEqual(GameDownloadPresentation.mainlandEligibility(for: game), .requiresConfirmation)
            XCTAssertTrue(GameDownloadPresentation.canSubmitUpdate(for: game))
            game.state = .installed
            XCTAssertEqual(GameDownloadPresentation.mainlandEligibility(for: game), .unsupported)
        }
        var global = gameForDownloadPresentation(type: .honkaiStarRail, uapc: "{\"hkrpg_global\":{}}")
        global.state = .gameUpdating
        global.metadataFailure = "当前证据读取失败"
        XCTAssertEqual(GameDownloadPresentation.mainlandEligibility(for: global), .unsupported)
        var conflict = gameForDownloadPresentation()
        conflict.state = .gameUpdating
        conflict.lastMetadata = GameMetadata(gameID: conflict.id, latestVersion: nil, outcome: .versionEvidenceConflict,
                                             localEvidence: .empty, conflictDetails: ["国服与国际服证据冲突"])
        XCTAssertEqual(GameDownloadPresentation.mainlandEligibility(for: conflict), .unsupported)
    }

    func testInterruptedInstallResumesFromHistoryWithRefreshedBookmarkAndNewIntent() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = PersistenceStore(baseURL: try makeTemporaryDirectory())
        var game = gameForDownloadPresentation()
        game.state = .notInstalled
        game.location = nil
        let oldIntent = UUID()
        let oldID = "interrupted-ui-install"
        let record = PersistedTaskRecord(
            id: oldID, type: ScheduledTaskType.gameInstall.rawValue, gameID: game.id,
            status: ScheduledTaskState.running.rawValue, phase: "下载中", progress: 0.4,
            outcome: nil, error: nil, recovery: nil, createdAt: Date(timeIntervalSince1970: 1), intentID: oldIntent,
            context: ["installBookmark": Data([1]).base64EncodedString(), "installPath": "/old-display-path", "preserved": "yes"]
        )
        try await store.writeAppData(AppData(games: [game], taskHistory: [record]))
        let fixture = try await makeScheduler(store: store)
        let repository = GameFileSystemRepository(bookmarkResolver: BookmarkResolver(
            resolve: { _ in .init(url: directory, isStale: true) }, refresh: { _, _ in Data([2]) },
            startAccessing: { _ in true }, stopAccessing: { _ in }
        ))
        let model = makeDownloadSettingsModel(fixture: fixture, repository: repository)
        await model.loadSettings()
        XCTAssertTrue(model.canResumeGameDownload(for: game.id))
        await model.resumeGameDownload(for: game.id)
        let tasks = await fixture.scheduler.allTaskSnapshots()
        let resumed = try XCTUnwrap(tasks.first(where: { $0.type == .gameInstall && $0.id.id != oldID }))
        XCTAssertNotEqual(resumed.intentID, oldIntent)
        XCTAssertEqual(resumed.context["installBookmark"], Data([2]).base64EncodedString())
        XCTAssertEqual(resumed.context["installPath"], directory.path)
        XCTAssertEqual(resumed.context["preserved"], "yes")
        XCTAssertEqual(tasks.first(where: { $0.id.id == oldID })?.state, .failed)
        XCTAssertNotEqual(resumed.state, .completed, "无效测试书签在调度器实际访问前失败，不会启动网络下载")
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
    }

    func testUpdateResumeRequiresFreshConfirmationDespiteHistoricalApproval() async throws {
        var game = gameForDownloadPresentation(type: .honkaiStarRail)
        game.state = .gameUpdating
        game.lastMetadata = nil
        let store = PersistenceStore(baseURL: try makeTemporaryDirectory())
        let oldID = "cancelled-ui-update"
        let record = PersistedTaskRecord(
            id: oldID, type: ScheduledTaskType.gameUpdate.rawValue, gameID: game.id,
            status: ScheduledTaskState.cancelled.rawValue, phase: "已取消", progress: nil,
            outcome: "downloadInterrupted", error: nil, recovery: "可继续下载", createdAt: Date(timeIntervalSince1970: 1),
            context: ["confirmedMainland": "true", "preserved": "yes"]
        )
        try await store.writeAppData(AppData(games: [game], taskHistory: [record]))
        let fixture = try await makeScheduler(store: store)
        let model = makeDownloadSettingsModel(fixture: fixture, repository: GameFileSystemRepository())
        await model.loadSettings()
        XCTAssertTrue(model.canResumeGameDownload(for: game.id))
        await model.resumeGameDownload(for: game.id)
        let before = await fixture.scheduler.allTaskSnapshots()
        XCTAssertEqual(before.filter { $0.type == .gameUpdate }.count, 1)
        XCTAssertTrue(model.errorMessage?.contains("确认") == true)
        await model.resumeGameDownload(for: game.id, confirmedMainland: true, confirmedLocationBookmark: game.location?.bookmarkData)
        let after = await fixture.scheduler.allTaskSnapshots()
        let resumed = try XCTUnwrap(after.first(where: { $0.type == .gameUpdate && $0.id.id != oldID }))
        XCTAssertEqual(resumed.context["confirmedMainland"], "true")
        XCTAssertEqual(resumed.context["confirmedLocationBookmark"], game.location?.bookmarkData?.base64EncodedString())
        XCTAssertEqual(resumed.context["preserved"], "yes")
        XCTAssertNotEqual(resumed.state, .completed)
    }

    private func makeDownloadSettingsModel(fixture: SchedulerFixture, repository: GameFileSystemRepository) -> SettingsViewModel {
        SettingsViewModel(systemDetector: SystemEnvironmentDetector(), wineVersionManager: fixture.wineManager,
                          gameRegistry: fixture.registry, fileSystemRepository: repository, taskScheduler: fixture.scheduler,
                          performanceOptionManager: PerformanceOptionManager(persistenceStore: fixture.persistence, logWriter: fixture.logger))
    }

    func testGameDownloadUIRejectsExplicitGlobalAndConflictingIdentity() {
        for (gameType, cnBiz, globalBiz) in [
            (GameType.genshinImpact, "hk4e_cn", "hk4e_global"),
            (.honkaiStarRail, "hkrpg_cn", "hkrpg_global"),
            (.zenlessZoneZero, "nap_cn", "nap_global")
        ] {
            let mainland = gameForDownloadPresentation(type: gameType, uapc: "{\"\(cnBiz)\":{}}")
            XCTAssertEqual(GameDownloadPresentation.mainlandEligibility(for: mainland), .confirmed)
            let global = gameForDownloadPresentation(type: gameType, uapc: "{\"\(globalBiz)\":{}}")
            XCTAssertEqual(GameDownloadPresentation.mainlandEligibility(for: global), .unsupported)
            let mixed = gameForDownloadPresentation(type: gameType, uapc: "{\"\(cnBiz)\":{},\"\(globalBiz)\":{}}")
            XCTAssertEqual(GameDownloadPresentation.mainlandEligibility(for: mixed), .unsupported)
        }
        var conflicting = gameForDownloadPresentation()
        conflicting.metadataFailure = "区服证据冲突"
        XCTAssertEqual(GameDownloadPresentation.mainlandEligibility(for: conflicting), .unsupported)
        let channelGame = gameForDownloadPresentation(channel: "14", cps: "bilibili")
        XCTAssertEqual(GameDownloadPresentation.mainlandEligibility(for: channelGame), .unsupported)
    }

    func testGameDownloadUIRequiresConfirmationForAmbiguousStarRail() {
        let ambiguous = gameForDownloadPresentation(type: .honkaiStarRail)
        XCTAssertEqual(GameDownloadPresentation.mainlandEligibility(for: ambiguous), .requiresConfirmation)
        XCTAssertTrue(GameDownloadPresentation.canSubmitUpdate(for: ambiguous))
        let malformed = gameForDownloadPresentation(type: .honkaiStarRail, uapc: "not-json")
        XCTAssertEqual(GameDownloadPresentation.mainlandEligibility(for: malformed), .unsupported)
        let unknown = gameForDownloadPresentation(type: .honkaiStarRail, channel: "")
        XCTAssertEqual(GameDownloadPresentation.mainlandEligibility(for: unknown), .unsupported)
    }

    func testGameDownloadUICanRecoverInterruptedUpdateButBlocksActiveOrRunningGame() {
        var game = gameForDownloadPresentation()
        game.state = .gameUpdating
        XCTAssertTrue(GameDownloadPresentation.canSubmitUpdate(for: game), "中断后的更新必须允许手动恢复")
        var task = ScheduledTask(type: .gameUpdate, gameId: game.id)
        XCTAssertFalse(GameDownloadPresentation.canSubmitUpdate(for: game, task: task))
        task.state = .running
        XCTAssertFalse(GameDownloadPresentation.canSubmitUpdate(for: game, task: task))
        task.state = .failed
        XCTAssertTrue(GameDownloadPresentation.canSubmitUpdate(for: game, task: task))
        task.state = .cancelled
        XCTAssertTrue(GameDownloadPresentation.canSubmitUpdate(for: game, task: task))
        game.state = .running
        XCTAssertFalse(GameDownloadPresentation.canSubmitUpdate(for: game, task: task))
    }

    func testGameDownloadProjectionRejectsLateEventsFromPreviousTask() {
        var old = ScheduledTask(type: .gameUpdate, gameId: "game", createdAt: Date(timeIntervalSince1970: 1))
        old.state = .completed
        old.revision = 99
        var current = ScheduledTask(type: .gameUpdate, gameId: "game", createdAt: Date(timeIntervalSince1970: 2))
        current.revision = 3
        XCTAssertFalse(GameDownloadPresentation.shouldProject(old, replacing: current), "旧任务的终态不能覆盖新任务")
        XCTAssertTrue(GameDownloadPresentation.shouldProject(current, replacing: old))
        var staleRevision = current
        staleRevision.revision = 2
        XCTAssertFalse(GameDownloadPresentation.shouldProject(staleRevision, replacing: current))
        current.revision = 4
        XCTAssertTrue(GameDownloadPresentation.shouldProject(current, replacing: staleRevision))
    }

    func testGameDownloadUIRequiresBusinessResultBeforeShowingCompletion() {
        var game = gameForDownloadPresentation()
        var task = ScheduledTask(type: .gameInstall, gameId: game.id)
        task.state = .completed
        XCTAssertFalse(GameDownloadPresentation.resultConfirmed(for: task, game: game))
        task.outcome = "gameInstalled"
        XCTAssertTrue(GameDownloadPresentation.resultConfirmed(for: task, game: game))
        game.state = .gameUpdating
        XCTAssertFalse(GameDownloadPresentation.resultConfirmed(for: task, game: game))
        game.state = .installed
        game.version = nil
        XCTAssertFalse(GameDownloadPresentation.resultConfirmed(for: task, game: game))
        game.version = "1.0.0"
        game.location?.bookmarkData = nil
        XCTAssertFalse(GameDownloadPresentation.resultConfirmed(for: task, game: game))
        let otherGame = gameForDownloadPresentation(type: .zenlessZoneZero)
        XCTAssertFalse(GameDownloadPresentation.resultConfirmed(for: task, game: otherGame))
    }

    func testStarRailUpdateDoesNotEnqueueWithoutExplicitConfirmation() async throws {
        let game = gameForDownloadPresentation(type: .honkaiStarRail)
        let fixture = try await makeScheduler(games: [game])
        let fileSystem = GameFileSystemRepository(appSupportDirectory: try makeTemporaryDirectory())
        let model = SettingsViewModel(
            systemDetector: SystemEnvironmentDetector(), wineVersionManager: fixture.wineManager,
            gameRegistry: fixture.registry, fileSystemRepository: fileSystem,
            taskScheduler: fixture.scheduler,
            performanceOptionManager: PerformanceOptionManager(persistenceStore: fixture.persistence, logWriter: fixture.logger)
        )
        await model.loadSettings()
        XCTAssertTrue(model.canUpdateGame(for: game.id))
        await model.updateGame(for: game.id)
        let beforeConfirmation = await fixture.scheduler.allTaskSnapshots()
        XCTAssertFalse(beforeConfirmation.contains(where: { $0.type == .gameUpdate }))
        XCTAssertTrue(model.errorMessage?.contains("确认") == true)

        // The intentionally invalid fixture bookmark fails before file access or
        // network activity, while preserving the user's explicit choice in the receipt.
        await model.updateGame(for: game.id, confirmedMainland: true, confirmedLocationBookmark: game.location?.bookmarkData)
        let afterConfirmation = await fixture.scheduler.allTaskSnapshots()
        let submitted = afterConfirmation.first(where: { $0.type == .gameUpdate })
        XCTAssertEqual(submitted?.context["confirmedMainland"], "true")
        XCTAssertNotEqual(submitted?.state, .completed)
    }

    func testPausedContentTasksOfferPauseAndContinueWithoutClaimingCompletion() {
        var update = ScheduledTask(type: .gameUpdate, gameId: GameType.genshinImpact.rawValue)
        update.state = .cancelled
        XCTAssertEqual(GameDownloadPresentation.pauseButtonLabel(for: update), "暂停")
        XCTAssertEqual(GameDownloadPresentation.resumeButtonLabel(for: update), "继续更新")
        XCTAssertTrue(GameDownloadPresentation.pausedMessage(for: update).contains("无法启动游戏"))
        update.phaseDescription = "正在分批安装游戏文件"
        XCTAssertNotEqual(update.cancellationPolicy, .notCancellable)
        update.phaseDescription = ScheduledTask.sophonCommitPhaseDescription
        XCTAssertEqual(update.cancellationPolicy, .notCancellable)

        let install = ScheduledTask(type: .gameInstall, gameId: update.gameId)
        XCTAssertEqual(GameDownloadPresentation.pauseButtonLabel(for: install), "暂停")
        XCTAssertEqual(GameDownloadPresentation.resumeButtonLabel(for: install), "继续安装")
        XCTAssertTrue(GameDownloadPresentation.pausedMessage(for: install).contains("已下载"))
        let predownload = ScheduledTask(type: .gamePredownload, gameId: update.gameId)
        XCTAssertEqual(GameDownloadPresentation.pauseButtonLabel(for: predownload), "取消")
        XCTAssertEqual(GameDownloadPresentation.resumeButtonLabel(for: predownload), "继续预下载")
    }

    func testPartialUpdatePrimaryActionContinuesUpdateInsteadOfLaunchingGame() async throws {
        var game = gameForDownloadPresentation()
        game.state = .gameUpdating
        let fixture = try await makeScheduler(games: [game])
        let model = LibraryViewModel(gameRegistry: fixture.registry, launchOrchestrator: fixture.launchOrchestrator,
                                     persistenceStore: fixture.persistence, taskScheduler: fixture.scheduler,
                                     logWriter: fixture.logger)
        await model.refreshGames()
        model.selectGame(id: game.id)
        XCTAssertEqual(model.primaryButtonState.label, "继续更新")
        XCTAssertEqual(model.primaryButtonState.action, .recoverGame)
        XCTAssertTrue(model.primaryButtonState.isEnabled)
        var task = ScheduledTask(type: .gameUpdate, gameId: game.id)
        task.state = .cancelled
        XCTAssertTrue(GameDownloadPresentation.canResume(task, for: game))
        XCTAssertFalse(GameDownloadPresentation.resultConfirmed(for: task, game: game))
    }

    private func gameForDownloadPresentation(
        type: GameType = .genshinImpact,
        uapc: String? = nil,
        channel: String = "1",
        cps: String = "mihoyo"
    ) -> Game {
        let evidence = VersionChecker.LocalEvidence(
            gameVersion: "1.0.0", channel: channel, subChannel: "1", cps: cps, sdkVersion: nil,
            configFields: uapc.map { [.init(section: "General", key: "uapc", value: $0)] } ?? []
        )
        return Game(
            id: type.rawValue, type: type,
            location: GameLocation(gameID: type.rawValue, bookmarkData: Data("invalid-ui-fixture".utf8),
                                   lastKnownPath: "/tmp/miplay-ui-download-fixture/\(type.rawValue)",
                                   scope: .readWrite, resolutionState: .resolvable),
            state: .installed, version: "1.0.0",
            lastMetadata: GameMetadata(gameID: type.rawValue, latestVersion: "2.0.0", outcome: .updateAvailable, localEvidence: evidence),
            lastLaunchDate: nil, solutionApplications: []
        )
    }

    /// A background video path change (group switch, hover preview, cache
    /// re-transcode) must rebuild the pooled player; reusing the stale player
    /// kept the old file playing or left a blank layer after cleanup.
    func testPlayerPoolRebuildsWhenVideoPathChanges() {
        let pool = PlayerPool()
        let first = pool.player(for: "ZenlessZoneZero", videoPath: "/tmp/a.mp4")
        let samePath = pool.player(for: "ZenlessZoneZero", videoPath: "/tmp/a.mp4")
        XCTAssertTrue(first === samePath)

        let changed = pool.player(for: "ZenlessZoneZero", videoPath: "/tmp/b.mp4")
        XCTAssertFalse(first === changed)
        XCTAssertEqual(first.rate, 0)
    }

    /// Creating a background player must not start hidden media from view evaluation.
    func testBackgroundPlayerCreationStartsPausedAndCanPauseAll() {
        let pool = PlayerPool()
        let first = pool.player(for: "one", videoPath: "/tmp/one.mp4")
        let second = pool.player(for: "two", videoPath: "/tmp/two.mp4")
        XCTAssertEqual(first.rate, 0)
        XCTAssertEqual(second.rate, 0)
        first.rate = 1
        second.rate = 1
        pool.pauseAll()
        XCTAssertEqual(first.rate, 0)
        XCTAssertEqual(second.rate, 0)
        XCTAssertTrue(pool.player(for: "one", videoPath: "/tmp/one.mp4") === first)
    }

    func testPrimaryButtonAndSettingsAccessibilityContractsAreStable() {
        let enabled = LibraryViewModel.PrimaryButtonState.enabled(label: "启动", action: .launch)
        XCTAssertTrue(enabled.isEnabled)
        XCTAssertEqual(enabled.label, "启动")
        if case .launch = enabled.action {
            // Expected action mapping.
        } else {
            XCTFail("Expected launch action")
        }

        let failed = LibraryViewModel.PrimaryButtonState.enabled(label: "启动", action: .launch)
        XCTAssertTrue(failed.isEnabled)
        XCTAssertEqual(failed.label, "启动")
        XCTAssertEqual(GameStateMachine().suggestedAction(for: .launchFailed), "启动")

        let disabled = LibraryViewModel.PrimaryButtonState.disabled("启动中…")
        XCTAssertFalse(disabled.isEnabled)
        XCTAssertEqual(disabled.label, "启动中…")
        XCTAssertNil(disabled.action)

        let items: [SettingsSidebarItem] = [.general, .wineEnvironment] + SettingsSidebarItem.gameItems + [.about]
        XCTAssertEqual(SettingsSidebarItem.gameItems.map(\.gameType), GameType.allCases.map(Optional.some))
        XCTAssertEqual(Set(items).count, GameType.allCases.count + 3)
        for item in items {
            XCTAssertFalse(item.sidebarTitle.isEmpty)
            XCTAssertFalse(item.title.isEmpty)
            XCTAssertFalse(item.icon.isEmpty)
        }
        XCTAssertEqual(SettingsSidebarItem.game(.genshinImpact).sidebarTitle, "原神")
        XCTAssertEqual(SettingsSidebarItem.game(.honkaiStarRail).sidebarTitle, "星穹铁道")
        XCTAssertEqual(SettingsSidebarItem.game(.zenlessZoneZero).sidebarTitle, "绝区零")
        XCTAssertEqual(SettingsSidebarItem.game(.genshinImpact).icon, "wind")
        XCTAssertEqual(SettingsSidebarItem.game(.honkaiStarRail).icon, "star")
        XCTAssertEqual(SettingsSidebarItem.game(.zenlessZoneZero).icon, "bolt.fill")
        XCTAssertEqual(SettingsSidebarItem.game(.honkaiStarRail).title, "崩坏：星穹铁道")
        XCTAssertNil(SettingsSidebarItem.general.gameType)
        XCTAssertNil(SettingsSidebarItem.wineEnvironment.gameType)
        XCTAssertNil(SettingsSidebarItem.about.gameType)
    }

    func testWineReadinessRequiresSharedPrefixBeforeWineReady() async throws {
        let appSupport = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: appSupport) }
        let fileSystem = GameFileSystemRepository(appSupportDirectory: appSupport)
        let persistence = PersistenceStore(baseURL: try makeTemporaryDirectory())
        let process = ProcessManager()
        let logger = LogWriter(fileSystemRepository: fileSystem)
        let pair = try makeFixedWineRuntimePair(appSupport: appSupport, createPrefix: false)
        try await persistence.writeAppData(AppData(
            managedWineRuntime: pair.runtime,
            sharedWinePrefix: pair.prefix
        ))

        let downloader = WineVersionDownloader(
            networkProvider: NetworkDownloadProvider(),
            fileSystemRepository: fileSystem,
            processManager: process,
            logWriter: logger
        )
        let provider = WineRuntimeProvider(processManager: process, fileSystemRepository: fileSystem)
        let manager = WineVersionManager(
            networkProvider: NetworkDownloadProvider(),
            fileSystemRepository: fileSystem,
            persistenceStore: persistence,
            wineVersionDownloader: downloader,
            logWriter: logger,
            wineRuntimeProvider: provider
        )
        await manager.initialize()

        guard case .prefixNotReady(gameID: nil) = await manager.checkReadiness() else {
            return XCTFail("Settings readiness must not report ready without the shared prefix")
        }

        let prefix = appSupport.appendingPathComponent("WinePrefixes/shared", isDirectory: true)
        try FileManager.default.createDirectory(
            at: prefix.appendingPathComponent("drive_c", isDirectory: true),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(
            at: prefix.appendingPathComponent("dosdevices", isDirectory: true),
            withIntermediateDirectories: true
        )
        guard case .ready = await manager.checkReadiness() else {
            return XCTFail("A verified shared prefix should complete Wine readiness")
        }
    }

    func testManagedWineStagingRejectsOutsideAndSymlinkDestinations() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let stagingRoot = root.appendingPathComponent("WineVersions/.staging", isDirectory: true)
        let inside = stagingRoot.appendingPathComponent("task", isDirectory: true)
        let outside = root.appendingPathComponent("outside", isDirectory: true)
        try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)

        let staging = try WineVersionDownloader.ManagedStaging(rootURL: stagingRoot, directoryURL: inside)
        XCTAssertEqual(staging.directoryURL.lastPathComponent, "task")

        XCTAssertThrowsError(
            try WineVersionDownloader.ManagedStaging(rootURL: stagingRoot, directoryURL: outside)
        )

        let symlink = stagingRoot.appendingPathComponent("symlink", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: outside)
        XCTAssertThrowsError(
            try WineVersionDownloader.ManagedStaging(rootURL: stagingRoot, directoryURL: symlink)
        )
    }

    func testWineArchiveWrapperDirectoryIsDetected() {
        let fileSystem = GameFileSystemRepository()
        let downloader = WineVersionDownloader(
            networkProvider: NetworkDownloadProvider(),
            fileSystemRepository: fileSystem,
            processManager: ProcessManager(),
            logWriter: LogWriter(fileSystemRepository: fileSystem)
        )
        let wrapped = "wine/\nwine/bin/\nwine/bin/wine\n"
        let rooted = "bin/\nbin/wine\n"

        XCTAssertEqual(downloader.archiveWrapperDirectory(from: wrapped), "wine")
        XCTAssertNil(downloader.archiveWrapperDirectory(from: rooted))
    }

    func testWineExtractionRejectsArchiveOutsideManagedStagingWithoutDeletingIt() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileSystem = GameFileSystemRepository(appSupportDirectory: root)
        let logger = LogWriter(fileSystemRepository: fileSystem)
        let downloader = WineVersionDownloader(
            networkProvider: NetworkDownloadProvider(),
            fileSystemRepository: fileSystem,
            processManager: ProcessManager(),
            logWriter: logger
        )
        let stagingRoot = root.appendingPathComponent("WineVersions/.staging", isDirectory: true)
        let destination = stagingRoot.appendingPathComponent("task", isDirectory: true)
        let archive = root.appendingPathComponent("outside.tar.xz")
        try FileManager.default.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        try Data("not an archive".utf8).write(to: archive)

        do {
            _ = try await downloader.extractArchive(archivePath: archive.path, to: destination.path)
            XCTFail("Expected archive boundary rejection")
        } catch let error as WineVersionDownloader.DownloaderError {
            guard case .extractionFailed(let detail) = error else {
                return XCTFail("Unexpected extraction error: \(error)")
            }
            XCTAssertTrue(detail.contains("托管 staging"))
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: archive.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testSettingsWineStatusPreservesReadinessSemantics() {
        XCTAssertTrue(SettingsViewModel.WineStatusText.notSelected.label.contains("未选择"))
        XCTAssertTrue(SettingsViewModel.WineStatusText.notDownloaded.label.contains("未下载"))
        XCTAssertTrue(SettingsViewModel.WineStatusText.prefixNotReady(gameID: nil).label.contains("前缀"))
        XCTAssertTrue(SettingsViewModel.WineStatusText.error("binary").label.contains("错误"))
    }

    func testSystemEnvironmentDetectorExposesAboutThisMacFields() {
        let detector = SystemEnvironmentDetector()
        XCTAssertFalse(detector.getMachineName().isEmpty, "Expected system-provided machine name")
        XCTAssertFalse(detector.getChipName().isEmpty, "Expected system-provided chip name")
        XCTAssertFalse(detector.getModelIdentifier().isEmpty, "Expected hardware model identifier")
        XCTAssertFalse(detector.getPhysicalMemoryText().isEmpty, "Expected readable physical memory")
        XCTAssertFalse(detector.getOSVersion().isEmpty, "Expected macOS product version")

        let info = detector.getSystemInfo()
        XCTAssertEqual(info.machineName, detector.getMachineName())
        XCTAssertEqual(info.chipName, detector.getChipName())
        XCTAssertEqual(info.modelIdentifier, detector.getModelIdentifier())
        XCTAssertEqual(info.physicalMemoryText, detector.getPhysicalMemoryText())
        XCTAssertGreaterThan(info.physicalMemory, 0)
    }

    /// 用户指令：设置窗口打开时点击主窗口，不仅要切换焦点，还要关闭设置窗口。
    /// 其它窗口获得焦点时设置窗口保持打开；主窗口获得焦点时关闭。
    func testSettingsWindowClosesWhenMainWindowTakesFocus() {
        final class RecordingWindow: NSWindow {
            var closeCount = 0
            override func close() {
                closeCount += 1
                super.close()
            }
        }

        let delegate = AppDelegate()
        let mainWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1280, height: 688),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let settingsWindow = RecordingWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 448),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        let otherWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 320, height: 200),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        delegate.registerMainWindow(mainWindow)
        delegate.registerSettingsWindow(settingsWindow)
        // 程序化创建的窗口默认 `isReleasedWhenClosed = true`，在测试里 `close()`
        // 会与 ARC 的强引用冲突（over-release 崩溃）。
        for window in [mainWindow, settingsWindow, otherWindow] {
            window.isReleasedWhenClosed = false
        }

        // 其它窗口获得焦点：设置窗口保持打开。
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: otherWindow)
        XCTAssertEqual(settingsWindow.closeCount, 0)

        // 主窗口获得焦点：设置窗口关闭。
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: mainWindow)
        XCTAssertEqual(settingsWindow.closeCount, 1, "点击主窗口必须关闭设置窗口")
    }

    func testSettingsActivationRestoresMainAppearanceWithoutTakingKeyboardFocus() async throws {
        // 测试宿主由 Xcode 在后台启动，用记录窗口验证通知链与 API 调用，
        // 实际 main/key 状态及玻璃外观由 ProbeMainWindowFocus 验证。
        final class RecordingWindow: NSWindow {
            var simulatedVisibility = true
            var simulatedKey = false
            var makeMainCount = 0
            var makeKeyCount = 0
            override var isVisible: Bool { simulatedVisibility }
            override var isKeyWindow: Bool { simulatedKey }
            override func makeMain() { makeMainCount += 1 }
            override func makeKey() { makeKeyCount += 1 }
            override func close() { simulatedVisibility = false }
        }
        let delegate = AppDelegate()
        let mainWindow = RecordingWindow()
        let settingsWindow = RecordingWindow()
        settingsWindow.simulatedKey = true
        delegate.registerMainWindow(mainWindow)
        delegate.registerSettingsWindow(settingsWindow)
        // 重复注册不应导致通知被处理多次。
        delegate.registerSettingsWindow(settingsWindow)

        NotificationCenter.default.post(name: NSWindow.didBecomeMainNotification, object: settingsWindow)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(mainWindow.makeMainCount, 1)
        XCTAssertEqual(mainWindow.makeKeyCount, 0, "保留活动外观不能抢走设置窗口的键盘焦点")
        XCTAssertTrue(settingsWindow.isVisible)

        delegate.toggleSettings { XCTFail("设置已打开时应关闭") }
        XCTAssertFalse(settingsWindow.isVisible)
        var requestedOpen = false
        delegate.toggleSettings { requestedOpen = true }
        XCTAssertTrue(requestedOpen, "关闭后仍可再次打开设置")

        settingsWindow.simulatedVisibility = true
        NotificationCenter.default.post(name: NSWindow.didBecomeMainNotification, object: settingsWindow)
        try await Task.sleep(for: .milliseconds(20))
        XCTAssertEqual(mainWindow.makeMainCount, 2)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: mainWindow)
        XCTAssertFalse(settingsWindow.isVisible, "点击主窗口仍应关闭设置")
    }

}

private actor PredownloadRefreshProbe {
    private(set) var calls = 0
    func lookup(_ type: GameType) -> String? {
        calls += 1
        return type == .genshinImpact ? "1.4.0" : nil
    }
}

@MainActor extension MiPlayCoreTests {
    func testForegroundRefreshIsThrottledAndDoesNotDuplicatePendingChecks() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data().write(to: directory.appendingPathComponent("YuanShen.exe"))
        try Data("[General]\ngame_version=1.2.3\nchannel=1\nsub_channel=1\ncps=mihoyo\n".utf8)
            .write(to: directory.appendingPathComponent("config.ini"))
        let location = try GameFileSystemRepository().makeGameLocation(gameID: GameType.genshinImpact.rawValue, for: directory)
        let game = Game(id: GameType.genshinImpact.rawValue, type: .genshinImpact, location: location,
                        state: .installed, version: "1.2.3", lastLaunchDate: nil, solutionApplications: [])
        let fixture = try await makeScheduler(games: [game], latestVersions: [.genshinImpact: "1.3.0"])
        let probe = PredownloadRefreshProbe()
        let model = LibraryViewModel(gameRegistry: fixture.registry, launchOrchestrator: fixture.launchOrchestrator,
                                     persistenceStore: fixture.persistence, taskScheduler: fixture.scheduler,
                                     logWriter: fixture.logger, predownloadLookup: { type in await probe.lookup(type) })

        // Returning to the app before initialization must not start work.
        await model.refreshUpdatesOnActivation()
        let beforeInitialization = await fixture.scheduler.allTaskSnapshots()
        XCTAssertTrue(beforeInitialization.isEmpty)
        await model.initialize()
        let initialChecks = await fixture.scheduler.allTaskSnapshots().filter { $0.type == .versionCheck }
        let first = try XCTUnwrap(initialChecks.first)
        _ = try await waitForTask(first.id, scheduler: fixture.scheduler)
        for _ in 0..<300 {
            if model.gamePredownloadVersions[game.id] == "1.4.0" { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let initialLookupCount = await probe.calls
        XCTAssertEqual(initialLookupCount, 1)
        let start = try XCTUnwrap(model.lastAutomaticVersionRefresh)

        await model.refreshUpdatesOnActivation(now: start.advanced(by: .seconds(299)))
        let beforeIntervalCalls = await probe.calls
        let beforeIntervalChecks = await fixture.scheduler.allTaskSnapshots().filter { $0.type == .versionCheck }
        XCTAssertEqual(beforeIntervalCalls, initialLookupCount)
        XCTAssertEqual(beforeIntervalChecks.count, 1)

        await model.refreshUpdatesOnActivation(now: start.advanced(by: .seconds(301)))
        let afterRefresh = await fixture.scheduler.allTaskSnapshots().filter { $0.type == .versionCheck }
        XCTAssertEqual(afterRefresh.count, 2)
        _ = try await waitForTask(try XCTUnwrap(afterRefresh.first { $0.id != first.id }).id, scheduler: fixture.scheduler)
        let afterRefreshCalls = await probe.calls
        XCTAssertEqual(afterRefreshCalls, initialLookupCount + 1)
        await model.refreshUpdatesOnActivation(now: start.advanced(by: .seconds(302)))
        let repeatedCalls = await probe.calls
        XCTAssertEqual(repeatedCalls, initialLookupCount + 1)

        // A pending check blocked behind an active predownload remains the
        // single queued check across further activation events.
        let blocker = ScheduledTask(type: .gamePredownload, gameId: game.id)
        await fixture.scheduler.lockResources(for: blocker)
        let pending = try await fixture.scheduler.enqueueReceipt(type: .versionCheck, gameId: game.id)
        let pendingSnapshot = try await fixture.scheduler.taskSnapshot(id: pending.taskID)
        XCTAssertEqual(pendingSnapshot.state, .pending)
        async let firstRegistrationCheck: Void = model.scheduleAutomaticVersionCheck(for: game.id)
        async let secondRegistrationCheck: Void = model.scheduleAutomaticVersionCheck(for: game.id)
        _ = await (firstRegistrationCheck, secondRegistrationCheck)
        await model.refreshUpdatesOnActivation(now: start.advanced(by: .seconds(602)))
        let pendingChecks = await fixture.scheduler.allTaskSnapshots().filter {
            $0.type == .versionCheck && ($0.state == .pending || $0.state == .running)
        }
        XCTAssertEqual(pendingChecks.count, 1)
        XCTAssertEqual(pendingChecks.first?.id, pending.taskID)
        let finalCalls = await probe.calls
        XCTAssertEqual(finalCalls, initialLookupCount + 2)
        await fixture.scheduler.unlockResources(for: blocker)
        await fixture.scheduler.schedule()
        _ = try await waitForTask(pending.taskID, scheduler: fixture.scheduler)
    }

    func testLocatingGameChecksVersionWithoutWaitingForForegroundRefresh() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data().write(to: directory.appendingPathComponent("YuanShen.exe"))
        try Data("[General]\ngame_version=1.2.3\nchannel=1\nsub_channel=1\ncps=mihoyo\n".utf8)
            .write(to: directory.appendingPathComponent("config.ini"))
        let selected: URL
        do {
            let bookmark = try directory.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
            var stale = false
            selected = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale)
            guard selected.startAccessingSecurityScopedResource() else {
                throw XCTSkip("测试宿主无法为临时目录取得原生授权")
            }
            selected.stopAccessingSecurityScopedResource()
        } catch let skipped as XCTSkip { throw skipped }
        catch { throw XCTSkip("测试宿主无法创建原生目录授权：\(error.localizedDescription)") }

        let game = Game(id: GameType.genshinImpact.rawValue, type: .genshinImpact, location: nil,
                        state: .notInstalled, version: nil, lastLaunchDate: nil, solutionApplications: [])
        let fixture = try await makeScheduler(games: [game], latestVersions: [.genshinImpact: "1.3.0"])
        let probe = PredownloadRefreshProbe()
        let model = LibraryViewModel(gameRegistry: fixture.registry, launchOrchestrator: fixture.launchOrchestrator,
                                     persistenceStore: fixture.persistence, taskScheduler: fixture.scheduler,
                                     logWriter: fixture.logger, predownloadLookup: { type in await probe.lookup(type) })
        await model.initialize()
        await model.locateGame(type: .genshinImpact, selectedURL: selected)
        var checks: [ScheduledTask] = []
        for _ in 0..<300 {
            checks = await fixture.scheduler.allTaskSnapshots().filter { $0.type == .versionCheck }
            if !checks.isEmpty, model.gamePredownloadVersions[game.id] == "1.4.0" { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(checks.count, 1)
        let calls = await probe.calls
        XCTAssertEqual(calls, 1)
        _ = try await waitForTask(try XCTUnwrap(checks.first).id, scheduler: fixture.scheduler)
        let registered = await fixture.registry.getGame(by: game.id)
        XCTAssertEqual(registered?.state, .updateAvailable)
    }

    func testCompletedInstallationTriggersDiscoveryOnlyOnce() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data().write(to: directory.appendingPathComponent("YuanShen.exe"))
        try Data("[General]\ngame_version=1.2.3\nchannel=1\nsub_channel=1\ncps=mihoyo\n".utf8)
            .write(to: directory.appendingPathComponent("config.ini"))
        let location = try GameFileSystemRepository().makeGameLocation(gameID: GameType.genshinImpact.rawValue, for: directory)
        let game = Game(id: GameType.genshinImpact.rawValue, type: .genshinImpact, location: location,
                        state: .installed, version: "1.2.3", lastLaunchDate: nil, solutionApplications: [])
        let fixture = try await makeScheduler(games: [game], latestVersions: [.genshinImpact: "1.3.0"])
        let probe = PredownloadRefreshProbe()
        let model = LibraryViewModel(gameRegistry: fixture.registry, launchOrchestrator: fixture.launchOrchestrator,
                                     persistenceStore: fixture.persistence, taskScheduler: fixture.scheduler,
                                     logWriter: fixture.logger, predownloadLookup: { type in await probe.lookup(type) })
        await model.initialize()
        let initialTasks = await fixture.scheduler.allTaskSnapshots()
        let first = try XCTUnwrap(initialTasks.first { $0.type == .versionCheck })
        _ = try await waitForTask(first.id, scheduler: fixture.scheduler)
        for _ in 0..<300 {
            if model.gamePredownloadVersions[game.id] == "1.4.0" { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let initialCalls = await probe.calls
        XCTAssertEqual(initialCalls, 1)

        var installed = ScheduledTask(type: .gameInstall, gameId: game.id)
        installed.state = .completed
        installed.outcome = "gameInstalled"
        await model.projectGameDownload(installed)
        await model.projectGameDownload(installed)
        var checks: [ScheduledTask] = []
        for _ in 0..<300 {
            checks = await fixture.scheduler.allTaskSnapshots().filter { $0.type == .versionCheck }
            if checks.count >= 2, await probe.calls >= initialCalls + 1 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        XCTAssertEqual(checks.count, 2)
        let calls = await probe.calls
        XCTAssertEqual(calls, initialCalls + 1)
        _ = try await waitForTask(try XCTUnwrap(checks.first { $0.id != first.id }).id, scheduler: fixture.scheduler)
    }
}
