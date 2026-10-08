// Source: Implementation maintenance split -> task scheduling and restart recovery
import XCTest
@testable import MiPlay

@MainActor extension MiPlayCoreTests {
    func testTaskSchedulerRunsVersionCheckProjectsProgressAndPersistsOutcome() async throws {
        let gameDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: gameDirectory) }
        try Data("[General]\ngame_version=1.2.3\nchannel=1\nsub_channel=0\ncps=test\n".utf8)
            .write(to: gameDirectory.appendingPathComponent("config.ini"))
        let fileSystem = GameFileSystemRepository()
        let payload = Data("versioned scheduler evidence".utf8)
        let evidenceURL = gameDirectory.appendingPathComponent("data/file.bin")
        try FileManager.default.createDirectory(at: evidenceURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try payload.write(to: evidenceURL)
        let md5 = await fileSystem.calculateMD5(of: payload)
        let sha256 = await fileSystem.calculateSHA256(of: payload)
        try Data("{\"remoteName\":\"data/file.bin\",\"fileSize\":\(payload.count),\"md5\":\"\(md5)\"}\n".utf8)
            .write(to: gameDirectory.appendingPathComponent("pkg_version"))
        let location = try fileSystem.makeGameLocation(
            gameID: GameType.genshinImpact.rawValue,
            for: gameDirectory
        )
        let game = Game(
            id: GameType.genshinImpact.rawValue,
            type: .genshinImpact,
            location: location,
            state: .installed,
            version: nil,
            lastLaunchDate: nil,
            solutionApplications: []
        )
        let fixture = try await makeScheduler(
            games: [game],
            latestVersions: [.genshinImpact: "1.3.0"],
            integrityManifests: [.genshinImpact: .init(
                gameID: GameType.genshinImpact.rawValue,
                version: "1.2.3",
                channel: "1",
                subChannel: "0",
                files: ["data/file.bin": sha256],
                fileSizes: ["data/file.bin": Int64(payload.count)]
            )]
        )

        let progressStream = await fixture.scheduler.makeProgressStream()
        let progressCollector = Task { () -> [TaskProgress] in
            var values: [TaskProgress] = []
            for await progress in progressStream {
                values.append(progress)
                if values.count >= 3 { return values }
            }
            return values
        }
        let taskID = try await fixture.scheduler.enqueue(
            type: .versionCheck,
            gameId: game.id
        )
        let result = try await waitForTask(taskID, scheduler: fixture.scheduler)
        let progress = await progressCollector.value

        XCTAssertEqual(result.state, .failed)
        XCTAssertEqual(result.outcome, "versionEvidenceConflict")
        XCTAssertNil(result.progress)
        XCTAssertTrue(progress.contains(where: { $0.phase == "正在检测版本" }))
        let projectedGame = await fixture.registry.getGame(by: game.id)
        let persistedData = try await fixture.persistence.readAppData()
        XCTAssertNil(projectedGame?.version)
        XCTAssertEqual(projectedGame?.state, .installed)
        XCTAssertTrue(persistedData.taskHistory.contains(where: {
            $0.id == taskID.id && $0.status == ScheduledTaskState.failed.rawValue
        }))
    }

    func testTaskSchedulerRecordsFailureForMissingGameAndRecoveryHint() async throws {
        let fixture = try await makeScheduler()
        let taskID = try await fixture.scheduler.enqueue(
            type: .integrityVerification,
            gameId: "missing-game"
        )
        let result = try await waitForTask(taskID, scheduler: fixture.scheduler)

        XCTAssertEqual(result.state, .failed)
        XCTAssertNil(result.outcome)
        XCTAssertFalse(result.error?.isEmpty ?? true)
        XCTAssertFalse(result.recovery?.isEmpty ?? true)
    }

    func testTaskSchedulerRepairsInterruptedPersistedTask() async throws {
        let baseURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: baseURL) }
        let store = PersistenceStore(baseURL: baseURL)
        let interruptedID = "interrupted-1"
        let record = PersistedTaskRecord(
            id: interruptedID,
            type: ScheduledTaskType.gameLaunch.rawValue,
            gameID: GameType.genshinImpact.rawValue,
            status: ScheduledTaskState.running.rawValue,
            phase: "正在启动",
            progress: 0.5,
            outcome: nil,
            error: nil,
            recovery: nil,
            createdAt: Date()
        )
        try await store.writeAppData(AppData(taskHistory: [record]))
        let fixture = try await makeScheduler(store: store)

        await fixture.scheduler.initialize()
        let repaired = try await fixture.scheduler.taskSnapshot(id: ScheduledTaskID(interruptedID))
        let persisted = try await store.readAppData()

        XCTAssertEqual(repaired.state, .failed)
        XCTAssertEqual(repaired.error, "应用退出时任务被中断")
        XCTAssertEqual(persisted.taskHistory.first?.status, ScheduledTaskState.failed.rawValue)
        XCTAssertNil(persisted.taskHistory.first?.progress)
    }

    func testProcessExitPersistenceFailureCreatesRetryableRecoveryFact() async throws {
        let baseURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: baseURL) }
        let store = PersistenceStore(baseURL: baseURL)
        let game = Game(
            id: GameType.genshinImpact.rawValue,
            type: .genshinImpact,
            location: GameLocation(
                gameID: GameType.genshinImpact.rawValue,
                bookmarkData: Data([1, 2, 3]),
                lastKnownPath: "/Games/Genshin",
                resolutionState: .resolvable
            ),
            state: .installed,
            version: nil,
            lastLaunchDate: Date(),
            solutionApplications: []
        )
        try await store.writeAppData(AppData(games: [game]))

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

        try await registry.transitionGame(id: game.id, to: .launching)
        try await registry.recordLaunchConfirmed(id: game.id, date: Date())

        await store.injectWriteFailure("退出状态写入失败")
        do {
            try await registry.commitProcessExit(
                gameID: game.id,
                processID: UUID(),
                statusCode: 0,
                terminatedBySignal: false
            )
            XCTFail("Expected exit state persistence failure")
        } catch {
            let stateAfterFailure = await registry.getGame(by: game.id)?.state
            XCTAssertEqual(stateAfterFailure, .running)
        }

        let processID = UUID()
        do {
            _ = try await registry.recordProcessExitRecovery(
                gameID: game.id,
                processID: processID,
                statusCode: 0,
                terminatedBySignal: false,
                detail: "退出后状态尚未提交"
            )
            XCTFail("Expected recovery fact persistence failure")
        } catch let error as GameRegistry.RegistrationError {
            guard case .recoveryRequired = error else {
                return XCTFail("Unexpected recovery error: \(error)")
            }
        }

        let pending = await registry.pendingRecoveryRecords(gameID: game.id)
        guard let record = pending.first(where: { $0.kind == "processExit" && $0.payload["processID"] == processID.uuidString }) else {
            return XCTFail("Expected in-memory process exit recovery fact")
        }
        let stateBeforeRetry = await registry.getGame(by: game.id)?.state
        XCTAssertEqual(stateBeforeRetry, .running)

        await store.clearWriteFailure()
        try await registry.retryProcessExitRecovery(recordID: record.id)

        let stateAfterRetry = await registry.getGame(by: game.id)?.state
        XCTAssertEqual(stateAfterRetry, .installed)
        let remainingRecovery = await registry.pendingRecoveryRecords(gameID: game.id)
        XCTAssertTrue(remainingRecovery.isEmpty)
        let persistedAfterRetry = try await store.readAppData()
        XCTAssertEqual(persistedAfterRetry.games.first?.state, .installed)
    }

    func testPendingProcessExitRecoveryCommitsAutomaticallyThroughViewModel() async throws {
        let game = Game(
            id: GameType.genshinImpact.rawValue,
            type: .genshinImpact,
            location: nil,
            state: .running,
            version: nil,
            lastLaunchDate: nil,
            solutionApplications: []
        )
        let fixture = try await makeScheduler(games: [game])
        _ = try await fixture.registry.recordProcessExitRecovery(
            gameID: game.id,
            processID: UUID(),
            statusCode: 9,
            terminatedBySignal: true,
            detail: "退出后状态尚未提交"
        )

        let viewModel = LibraryViewModel(
            gameRegistry: fixture.registry,
            launchOrchestrator: fixture.launchOrchestrator,
            backgroundMediaService: fixture.backgroundMediaService,
            persistenceStore: fixture.persistence,
            taskScheduler: fixture.scheduler,
            logWriter: fixture.logger
        )
        await viewModel.refreshGames()

        let pending = await fixture.registry.pendingRecoveryRecords(gameID: game.id)
        XCTAssertTrue(pending.isEmpty)
        let state = await fixture.registry.getGame(by: game.id)?.state
        XCTAssertEqual(state, .installed)
    }

    func testRestartReconcilesPersistentRunningWithoutInventingNormalExit() async throws {
        let baseURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: baseURL) }
        let store = PersistenceStore(baseURL: baseURL)
        let game = Game(
            id: GameType.genshinImpact.rawValue,
            type: .genshinImpact,
            location: GameLocation(
                gameID: GameType.genshinImpact.rawValue,
                bookmarkData: Data([1]),
                lastKnownPath: "/Games/Genshin",
                resolutionState: .resolvable
            ),
            state: .running,
            version: nil,
            lastLaunchDate: Date(),
            solutionApplications: []
        )
        try await store.writeAppData(AppData(games: [game]))

        let fileSystem = GameFileSystemRepository(appSupportDirectory: try makeTemporaryDirectory())
        let registry = GameRegistry(
            persistenceStore: store,
            fileSystemRepository: fileSystem,
            stateMachine: GameStateMachine(),
            systemDetector: SystemEnvironmentDetector(),
            logWriter: LogWriter(fileSystemRepository: fileSystem)
        )

        await registry.initialize()

        let reconciledGame = await registry.getGame(by: game.id)
        XCTAssertEqual(reconciledGame?.state, .launchFailed)
        let snapshot = await registry.currentSnapshot()
        guard case .recoveryRequired = snapshot.state else {
            return XCTFail("Expected restart recovery state")
        }
        let persisted = try await store.readAppData()
        XCTAssertEqual(persisted.games.first?.state, .launchFailed)
        XCTAssertTrue(persisted.recoveryRecords.contains {
            $0.kind == "restartReconciliation" &&
                $0.phase == "restartReconciliation" &&
                $0.payload["reason"] == "interruptedAfterRestart" &&
                $0.resolvedAt == nil
        })
    }

    func testRestartRecoveryWithDurableNormalExitCommitsInstalled() async throws {
        let baseURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: baseURL) }
        let store = PersistenceStore(baseURL: baseURL)
        let processID = UUID()
        let game = Game(
            id: GameType.genshinImpact.rawValue,
            type: .genshinImpact,
            location: GameLocation(
                gameID: GameType.genshinImpact.rawValue,
                bookmarkData: Data([1]),
                lastKnownPath: "/Games/Genshin",
                resolutionState: .resolvable
            ),
            state: .running,
            version: nil,
            lastLaunchDate: Date(),
            solutionApplications: []
        )
        let record = RecoveryRecord(
            id: "exit-\(processID.uuidString)",
            kind: "processExit",
            gameID: game.id,
            target: GameBusinessState.installed.rawValue,
            phase: "exitStateCommit",
            detail: "进程已确认正常退出，但上次提交未完成",
            payload: [
                "processID": processID.uuidString,
                "statusCode": "0",
                "terminatedBySignal": "false"
            ]
        )
        try await store.writeAppData(AppData(games: [game], recoveryRecords: [record]))

        let fileSystem = GameFileSystemRepository(appSupportDirectory: try makeTemporaryDirectory())
        let registry = GameRegistry(
            persistenceStore: store,
            fileSystemRepository: fileSystem,
            stateMachine: GameStateMachine(),
            systemDetector: SystemEnvironmentDetector(),
            logWriter: LogWriter(fileSystemRepository: fileSystem)
        )
        await registry.initialize()
        try await registry.retryProcessExitRecovery(recordID: record.id)

        let recoveredGame = await registry.getGame(by: game.id)
        XCTAssertEqual(recoveredGame?.state, .installed)
        let persisted = try await store.readAppData()
        XCTAssertEqual(persisted.games.first?.state, .installed)
        XCTAssertNotNil(persisted.recoveryRecords.first?.resolvedAt)
    }

    func testRestartRecoveryGuardSurvivesAppDataWriteFailureAndBlocksNewLaunch() async throws {
        let baseURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: baseURL) }
        let store = PersistenceStore(baseURL: baseURL)
        let game = Game(
            id: GameType.genshinImpact.rawValue,
            type: .genshinImpact,
            location: GameLocation(
                gameID: GameType.genshinImpact.rawValue,
                bookmarkData: Data([1]),
                lastKnownPath: "/Games/Genshin",
                resolutionState: .resolvable
            ),
            state: .running,
            version: nil,
            lastLaunchDate: Date(),
            solutionApplications: []
        )
        try await store.writeAppData(AppData(games: [game]))
        await store.injectWriteFailure("AppData 和退出恢复记录同时不可写")

        let fileSystem = GameFileSystemRepository(appSupportDirectory: try makeTemporaryDirectory())
        let makeRegistry = {
            GameRegistry(
                persistenceStore: store,
                fileSystemRepository: fileSystem,
                stateMachine: GameStateMachine(),
                systemDetector: SystemEnvironmentDetector(),
                logWriter: LogWriter(fileSystemRepository: fileSystem)
            )
        }
        let firstRegistry = makeRegistry()
        await firstRegistry.initialize()

        let guardRecords = try await store.readRecoveryGuards()
        guard let guardRecord = guardRecords.first(where: { $0.gameID == game.id }) else {
            return XCTFail("Expected a cross-restart recovery guard")
        }
        let firstState = await firstRegistry.getGame(by: game.id)?.state
        XCTAssertEqual(firstState, .running)

        let secondRegistry = makeRegistry()
        await secondRegistry.initialize()
        let secondSnapshot = await secondRegistry.currentSnapshot()
        guard case .recoveryRequired = secondSnapshot.state else {
            return XCTFail("Expected recoveryRequired after restart")
        }
        do {
            try await secondRegistry.transitionGame(id: game.id, to: .launching)
            XCTFail("A pending recovery guard must block a new launch")
        } catch let error as GameRegistry.RegistrationError {
            guard case .recoveryRequired = error else {
                return XCTFail("Unexpected launch gate error: \(error)")
            }
        }

        await store.clearWriteFailure()
        try await secondRegistry.retryProcessExitRecovery(recordID: guardRecord.id)
        let recoveredState = await secondRegistry.getGame(by: game.id)?.state
        XCTAssertEqual(recoveredState, .launchFailed)
        let remainingGuards = try await store.readRecoveryGuards()
        XCTAssertTrue(remainingGuards.isEmpty)
        let recoveredData = try await store.readAppData()
        XCTAssertEqual(recoveredData.recoveryRecords.count, 1)
        XCTAssertEqual(recoveredData.recoveryRecords.first?.id, guardRecord.id)
        XCTAssertNotNil(recoveredData.recoveryRecords.first?.resolvedAt)
    }

    /// 回归：AppData 的 ISO8601 时间戳只有秒级精度，同一秒创建的多条恢复记录
    /// 必须按"结论强弱"确定性排序。否则提交顺序随机，最终状态会在保守结论
    /// （restartReconciliation → LaunchFailed）和具体退出事实
    /// （processExit → Installed）之间摇摆（此前的偶发失败用例）。
    func testRecoveryCommitOrderIsDeterministicForEqualTimestamps() {
        let sameInstant = Date(timeIntervalSince1970: 1_700_000_000)
        let conservative = RecoveryRecord(
            kind: "restartReconciliation",
            gameID: GameType.genshinImpact.rawValue,
            target: GameBusinessState.launchFailed.rawValue,
            phase: "restartReconciliation",
            detail: "应用重启后无法验证旧游戏进程",
            createdAt: sameInstant
        )
        let concrete = RecoveryRecord(
            kind: "processExit",
            gameID: GameType.genshinImpact.rawValue,
            target: GameBusinessState.installed.rawValue,
            phase: "exitStateCommit",
            detail: "退出后状态尚未提交",
            createdAt: sameInstant
        )

        // 保守结论先提交，具体退出事实最后提交 → 具体事实最终生效。
        XCTAssertTrue(GameRegistry.precedesInRecoveryCommitOrder(conservative, concrete))
        XCTAssertFalse(GameRegistry.precedesInRecoveryCommitOrder(concrete, conservative))

        // 时间不同仍以时间为准。
        let later = RecoveryRecord(
            kind: "restartReconciliation",
            phase: "restartReconciliation",
            detail: "更晚的保守结论",
            createdAt: sameInstant.addingTimeInterval(1)
        )
        XCTAssertTrue(GameRegistry.precedesInRecoveryCommitOrder(concrete, later))

        // 完全相同的键（same createdAt / kind / rank）也必须确定：按 id 排序。
        let lowerID = RecoveryRecord(
            id: "A-000",
            kind: "processExit",
            phase: "exitStateCommit",
            detail: "first",
            createdAt: sameInstant
        )
        let higherID = RecoveryRecord(
            id: "B-111",
            kind: "processExit",
            phase: "exitStateCommit",
            detail: "second",
            createdAt: sameInstant
        )
        XCTAssertTrue(GameRegistry.precedesInRecoveryCommitOrder(lowerID, higherID))
        XCTAssertFalse(GameRegistry.precedesInRecoveryCommitOrder(higherID, lowerID))
    }

}
