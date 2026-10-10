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

    // MARK: - 启动会话恢复（2026-10-10 修复：wineserver 清理失败后本会话内可恢复）

    /// 恢复入口前置条件矩阵（纯函数）。
    func testLaunchRecoveryPreconditionMatrix() {
        // 无会话在途：允许（应用重启后的自动恢复走这条）。
        XCTAssertTrue(LaunchOrchestrator.canRetryProcessExitRecovery(
            hasActiveSession: false, sessionProcessExited: false
        ))
        // 会话在途、进程退出事实已确认：允许（本次修复的目标场景）。
        XCTAssertTrue(LaunchOrchestrator.canRetryProcessExitRecovery(
            hasActiveSession: true, sessionProcessExited: true
        ))
        // 会话在途、进程状态未知（游戏可能仍在运行）：拒绝，避免误杀。
        XCTAssertFalse(LaunchOrchestrator.canRetryProcessExitRecovery(
            hasActiveSession: true, sessionProcessExited: false
        ))
        // 会话已收尾：允许。
        XCTAssertTrue(LaunchOrchestrator.canRetryProcessExitRecovery(
            hasActiveSession: false, sessionProcessExited: true
        ))
    }

    /// wineserver 清理失败 → 会话内可手动恢复；恢复先释放 prefix 再提交退出事实；
    /// 重复调用不会二次释放；成功后守卫清空、可再次启动。
    func testWineserverShutdownFailureKeepsSessionRecoverableInApp() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let executable = directory.appendingPathComponent("YuanShen.exe")
        try Data("printf '%s' \"$0\" > \"$WINEPREFIX/launch-arg\"\nsleep 0.2\nexit 0\n".utf8)
            .write(to: executable)
        try Data("[General]\ngame_version=1.2.3\nchannel=1\nsub_channel=0\ncps=test\n".utf8)
            .write(to: directory.appendingPathComponent("config.ini"))

        let supportDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: supportDirectory) }
        // 游戏目录授权：与既有启动夹具相同，用解析器把测试书签指向临时目录。
        let resolver = BookmarkResolver(
            resolve: { _ in .init(url: directory, isStale: true) },
            refresh: { _, _ in Data([2]) },
            startAccessing: { _ in true },
            stopAccessing: { _ in }
        )
        let fileSystem = GameFileSystemRepository(
            appSupportDirectory: supportDirectory,
            bookmarkResolver: resolver
        )
        let store = PersistenceStore(baseURL: try makeTemporaryDirectory())
        let logger = LogWriter(fileSystemRepository: fileSystem)
        let process = ProcessManager()
        let pair = try makeFixedWineRuntimePair(appSupport: supportDirectory)
        let wine = WineRuntimeProvider(processManager: process, fileSystemRepository: fileSystem)

        // 受控 wineserver：默认 `-k` 失败（退出码 42）；marker 存在时成功。
        // 只使用临时目录中的运行时，绝不触碰真实 Prefix。
        let marker = supportDirectory.appendingPathComponent("wineserver-ok")
        let server = supportDirectory
            .appendingPathComponent("WineVersions")
            .appendingPathComponent(WineVersionManager.fixedRuntimeTag)
            .appendingPathComponent("bin/wineserver")
        let serverScript = """
        #!/bin/sh
        case "$1" in
          -w) exit 0 ;;
          -k) if [ -f "\(marker.path)" ]; then exit 0; else exit 42; fi ;;
          *) exit 0 ;;
        esac
        """
        try Data(serverScript.utf8).write(to: server)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: server.path)

        let hash = try await fileSystem.calculateSHA256(of: executable.path)
        let game = Game(
            id: GameType.genshinImpact.rawValue,
            type: .genshinImpact,
            location: GameLocation(
                gameID: GameType.genshinImpact.rawValue,
                bookmarkData: Data([1]),
                lastKnownPath: directory.path,
                resolutionState: .resolvable
            ),
            state: .installed,
            version: "1.2.3",
            lastLaunchDate: nil,
            solutionApplications: []
        )
        try await store.writeAppData(AppData(
            games: [game],
            managedWineRuntime: pair.runtime,
            sharedWinePrefix: pair.prefix
        ))
        let registry = GameRegistry(
            persistenceStore: store,
            fileSystemRepository: fileSystem,
            stateMachine: GameStateMachine(),
            systemDetector: SystemEnvironmentDetector(),
            logWriter: logger
        )
        await registry.initialize()
        let wineManager = WineVersionManager(
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
            wineRuntimeProvider: wine
        )
        await wineManager.initialize()
        let verifier = FileIntegrityVerifier(
            fileSystemRepository: fileSystem,
            manifests: [.genshinImpact: .init(
                gameID: GameType.genshinImpact.rawValue,
                version: "1.2.3",
                files: ["YuanShen.exe": hash]
            )],
            gameRegistry: registry
        )
        let validator = PreLaunchValidator(
            fileSystemRepository: fileSystem,
            systemDetector: SystemEnvironmentDetector { _ in
                (free: UInt64.max, total: UInt64.max)
            },
            wineRuntimeProvider: wine,
            wineVersionManager: wineManager,
            integrityVerifier: verifier,
            gameRegistry: registry
        )
        let launch = LaunchOrchestrator(
            preLaunchValidator: validator,
            wineRuntimeProvider: wine,
            wineVersionManager: wineManager,
            processManager: process,
            performanceOptionManager: PerformanceOptionManager(
                persistenceStore: store,
                logWriter: logger
            ),
            gameRegistry: registry,
            fileSystemRepository: fileSystem,
            logWriter: logger
        )

        let result = await launch.launch(game: game)
        guard case .success = result else {
            return XCTFail("Expected Wine binary launch, got \(result)")
        }

        // 等待"退出已提交 + 清理失败"的现场：状态回到 installed，且存在待恢复记录。
        let deadline = Date().addingTimeInterval(8)
        var pendingRecord: RecoveryRecord?
        while Date() < deadline {
            let state = await registry.getGame(by: game.id)?.state
            let pending = await registry.pendingRecoveryRecords(gameID: game.id)
                .filter { $0.kind == "processExit" }
            if state == .installed, let first = pending.first {
                pendingRecord = first
                break
            }
            try await Task.sleep(for: .milliseconds(50))
        }
        let record = try XCTUnwrap(pendingRecord, "wineserver 清理失败后应保留待恢复记录")

        // 场景 6：会话未收尾时不允许新启动（共享 Prefix 不会被并发操作）。
        let concurrent = await launch.launch(game: game)
        guard case .failure(.gameAlreadyRunning) = concurrent else {
            return XCTFail("会话未收尾时不应允许新启动: \(concurrent)")
        }

        // 场景 2：恢复入口必须可达——应表现为 prefix 清理失败，而不是被会话守卫拒绝。
        do {
            try await launch.retryProcessExitRecovery(recordID: record.id)
            XCTFail("wineserver 仍然失败时不应恢复成功")
        } catch {
            let description = error.localizedDescription
            XCTAssertFalse(
                description.contains("启动进行中"),
                "恢复入口被会话守卫拒绝（本次修复的目标场景）: \(description)"
            )
        }
        let stillPending = await registry.pendingRecoveryRecords(gameID: game.id)
            .contains { $0.id == record.id }
        XCTAssertTrue(stillPending, "第一次重试失败后不应丢失待恢复记录")

        // 场景 3：清理恢复可用后，在同一应用会话内完成恢复。
        try Data().write(to: marker)
        try await launch.retryProcessExitRecovery(recordID: record.id)
        let pendingAfter = await registry.pendingRecoveryRecords(gameID: game.id)
        XCTAssertTrue(pendingAfter.isEmpty, "恢复完成后不应残留待恢复记录")
        let stateAfter = await registry.getGame(by: game.id)?.state
        XCTAssertEqual(stateAfter, .installed)

        // 场景 4：同一恢复事实不能被处理两次（也不会二次释放 prefix 租约）。
        do {
            try await launch.retryProcessExitRecovery(recordID: record.id)
            XCTFail("已消费的恢复事实不应再次被处理")
        } catch {
            // 期望：恢复事实不存在或已处理
        }

        // 场景 1：正常收尾后守卫已清空，可以再次启动（原有行为不变）。
        let relaunch = await launch.launch(game: game)
        guard case .success = relaunch else {
            return XCTFail("恢复后应可再次启动: \(relaunch)")
        }
        await launch.cancelLaunch()
    }

    // MARK: - 提交前异常路径验证（2026-10-10）
    //
    // A：Prefix 已释放、退出事实提交失败 → 记录不丢、不重复释放、可最终提交、状态一致。
    // B：上述状态下应用重启 → 新实例识别 Prefix 已释放、不重复清理、可完成恢复、不遗留阻塞状态。

    /// 受控会话夹具：临时目录 + 假 game 脚本 + 假 runtime + 可切换成败并记录调用的假 wineserver。
    /// 全程只写临时目录，不触碰真实 Prefix / 真实 wineserver / 真实 Wine/DXMT 资产。
    struct RecoverableSessionFixture {
        let store: PersistenceStore
        let fileSystem: GameFileSystemRepository
        let process: ProcessManager
        let logger: LogWriter
        let provider: WineRuntimeProvider
        let game: Game
        let marker: URL
        let serverLog: URL
        let directory: URL
        let supportDirectory: URL

        /// 假 wineserver 被调用 `-k` 的次数（用于证明"已释放的 Prefix 不会被重复清理"）。
        func killCount() -> Int {
            guard let content = try? String(contentsOf: serverLog, encoding: .utf8) else { return 0 }
            return content.split(whereSeparator: \.isNewline).filter { $0 == "-k" }.count
        }

        func removeTemporaryDirectories() {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: supportDirectory)
        }

        /// 构建一个会话。可多次调用以模拟应用重启：同一 store 与临时目录，独立的内存状态。
        func makeSession() async throws -> (registry: GameRegistry, orchestrator: LaunchOrchestrator) {
            let registry = GameRegistry(
                persistenceStore: store,
                fileSystemRepository: fileSystem,
                stateMachine: GameStateMachine(),
                systemDetector: SystemEnvironmentDetector(),
                logWriter: logger
            )
            await registry.initialize()
            let wineManager = WineVersionManager(
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
            await wineManager.initialize()
            let hash = try await fileSystem.calculateSHA256(
                of: directory.appendingPathComponent("YuanShen.exe").path
            )
            let verifier = FileIntegrityVerifier(
                fileSystemRepository: fileSystem,
                manifests: [.genshinImpact: .init(
                    gameID: GameType.genshinImpact.rawValue,
                    version: "1.2.3",
                    files: ["YuanShen.exe": hash]
                )],
                gameRegistry: registry
            )
            let validator = PreLaunchValidator(
                fileSystemRepository: fileSystem,
                systemDetector: SystemEnvironmentDetector { _ in
                    (free: UInt64.max, total: UInt64.max)
                },
                wineRuntimeProvider: provider,
                wineVersionManager: wineManager,
                integrityVerifier: verifier,
                gameRegistry: registry
            )
            let orchestrator = LaunchOrchestrator(
                preLaunchValidator: validator,
                wineRuntimeProvider: provider,
                wineVersionManager: wineManager,
                processManager: process,
                performanceOptionManager: PerformanceOptionManager(
                    persistenceStore: store,
                    logWriter: logger
                ),
                gameRegistry: registry,
                fileSystemRepository: fileSystem,
                logWriter: logger
            )
            return (registry, orchestrator)
        }
    }

    private func makeRecoverableSessionFixture() async throws -> RecoverableSessionFixture {
        let directory = try makeTemporaryDirectory()
        let executable = directory.appendingPathComponent("YuanShen.exe")
        try Data("printf '%s' \"$0\" > \"$WINEPREFIX/launch-arg\"\nsleep 0.2\nexit 0\n".utf8)
            .write(to: executable)
        try Data("[General]\ngame_version=1.2.3\nchannel=1\nsub_channel=0\ncps=test\n".utf8)
            .write(to: directory.appendingPathComponent("config.ini"))

        let supportDirectory = try makeTemporaryDirectory()
        let resolver = BookmarkResolver(
            resolve: { _ in .init(url: directory, isStale: true) },
            refresh: { _, _ in Data([2]) },
            startAccessing: { _ in true },
            stopAccessing: { _ in }
        )
        let fileSystem = GameFileSystemRepository(
            appSupportDirectory: supportDirectory,
            bookmarkResolver: resolver
        )
        let store = PersistenceStore(baseURL: try makeTemporaryDirectory())
        let logger = LogWriter(fileSystemRepository: fileSystem)
        let process = ProcessManager()
        let pair = try makeFixedWineRuntimePair(appSupport: supportDirectory)
        let provider = WineRuntimeProvider(processManager: process, fileSystemRepository: fileSystem)

        // 受控 wineserver：默认 `-k` 失败（退出码 42），marker 存在时成功；每次调用都记录到 serverLog。
        let marker = supportDirectory.appendingPathComponent("wineserver-ok")
        let serverLog = supportDirectory.appendingPathComponent("wineserver-calls.log")
        let server = supportDirectory
            .appendingPathComponent("WineVersions")
            .appendingPathComponent(WineVersionManager.fixedRuntimeTag)
            .appendingPathComponent("bin/wineserver")
        let serverScript = """
        #!/bin/sh
        echo "$1" >> "\(serverLog.path)"
        case "$1" in
          -w) exit 0 ;;
          -k) if [ -f "\(marker.path)" ]; then exit 0; else exit 42; fi ;;
          *) exit 0 ;;
        esac
        """
        try Data(serverScript.utf8).write(to: server)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: server.path)

        let game = Game(
            id: GameType.genshinImpact.rawValue,
            type: .genshinImpact,
            location: GameLocation(
                gameID: GameType.genshinImpact.rawValue,
                bookmarkData: Data([1]),
                lastKnownPath: directory.path,
                resolutionState: .resolvable
            ),
            state: .installed,
            version: "1.2.3",
            lastLaunchDate: nil,
            solutionApplications: []
        )
        try await store.writeAppData(AppData(
            games: [game],
            managedWineRuntime: pair.runtime,
            sharedWinePrefix: pair.prefix
        ))

        return RecoverableSessionFixture(
            store: store,
            fileSystem: fileSystem,
            process: process,
            logger: logger,
            provider: provider,
            game: game,
            marker: marker,
            serverLog: serverLog,
            directory: directory,
            supportDirectory: supportDirectory
        )
    }

    /// 等待"退出已提交 + 清理失败"的现场：状态回到 installed，且存在待恢复记录。
    private func waitForPendingProcessExitRecord(
        registry: GameRegistry,
        gameID: String,
        timeout: TimeInterval = 8
    ) async throws -> RecoveryRecord? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            let state = await registry.getGame(by: gameID)?.state
            let pending = await registry.pendingRecoveryRecords(gameID: gameID)
                .filter { $0.kind == "processExit" }
            if state == .installed, let first = pending.first { return first }
            try await Task.sleep(for: .milliseconds(50))
        }
        return nil
    }

    /// A：Prefix 已释放、退出事实提交失败。
    func testRecoveryAfterPrefixReleasedButExitCommitFails() async throws {
        let fixture = try await makeRecoverableSessionFixture()
        defer { fixture.removeTemporaryDirectories() }
        let session = try await fixture.makeSession()

        let launchResult = await session.orchestrator.launch(game: fixture.game)
        guard case .success = launchResult else {
            return XCTFail("Expected Wine binary launch, got \(launchResult)")
        }
        let pendingRecord = try await waitForPendingProcessExitRecord(
            registry: session.registry, gameID: fixture.game.id
        )
        let record = try XCTUnwrap(pendingRecord, "wineserver 清理失败后应保留待恢复记录")

        // 释放成功、提交失败：注入 AppData 写失败后在会话内重试。
        try Data().write(to: fixture.marker)
        let killsBeforeRetry = fixture.killCount()
        await fixture.store.injectWriteFailure("退出提交失败注入")
        do {
            try await session.orchestrator.retryProcessExitRecovery(recordID: record.id)
            XCTFail("提交失败时不应恢复成功")
        } catch {
            XCTAssertFalse(
                error.localizedDescription.contains("启动进行中"),
                "恢复入口必须可达: \(error)"
            )
        }
        XCTAssertEqual(
            fixture.killCount(), killsBeforeRetry + 1,
            "本次重试应恰好执行一次 wineserver -k（释放成功）"
        )
        let stillPending = await session.registry.pendingRecoveryRecords(gameID: fixture.game.id)
            .contains { $0.id == record.id }
        XCTAssertTrue(stillPending, "提交失败后不得丢失恢复记录")

        // 清除写失败 → 再次恢复：Prefix 已释放，不得重复清理，且应最终完成提交。
        await fixture.store.clearWriteFailure()
        try await session.orchestrator.retryProcessExitRecovery(recordID: record.id)
        XCTAssertEqual(
            fixture.killCount(), killsBeforeRetry + 1,
            "Prefix 已释放时不得重复执行 wineserver -k"
        )
        let pendingAfter = await session.registry.pendingRecoveryRecords(gameID: fixture.game.id)
        XCTAssertTrue(pendingAfter.isEmpty, "恢复完成后不应残留待恢复记录")
        let stateAfter = await session.registry.getGame(by: fixture.game.id)?.state
        XCTAssertEqual(stateAfter, .installed, "恢复后状态必须一致")

        // 不误操作新会话：恢复完成后可以再次启动并正常取消。
        let relaunch = await session.orchestrator.launch(game: fixture.game)
        guard case .success = relaunch else {
            return XCTFail("恢复后应可再次启动: \(relaunch)")
        }
        await session.orchestrator.cancelLaunch()
    }

    /// B：上述状态下应用重启（新实例 + restartReconciliation）。
    func testRestartAfterPrefixReleasedButExitCommitFails() async throws {
        let fixture = try await makeRecoverableSessionFixture()
        defer { fixture.removeTemporaryDirectories() }
        let firstSession = try await fixture.makeSession()

        let launchResult = await firstSession.orchestrator.launch(game: fixture.game)
        guard case .success = launchResult else {
            return XCTFail("Expected Wine binary launch, got \(launchResult)")
        }
        let pendingRecord = try await waitForPendingProcessExitRecord(
            registry: firstSession.registry, gameID: fixture.game.id
        )
        let record = try XCTUnwrap(pendingRecord, "wineserver 清理失败后应保留待恢复记录")
        try Data().write(to: fixture.marker)
        await fixture.store.injectWriteFailure("退出提交失败注入")
        do {
            try await firstSession.orchestrator.retryProcessExitRecovery(recordID: record.id)
            XCTFail("提交失败时不应恢复成功")
        } catch {
            XCTAssertFalse(error.localizedDescription.contains("启动进行中"), "恢复入口必须可达: \(error)")
        }
        let killsAfterRelease = fixture.killCount()

        // 模拟应用终止 + 重启：清除写失败，丢弃第一个实例的会话，用同一 store/临时目录建新实例。
        await fixture.store.clearWriteFailure()
        let restarted = try await fixture.makeSession()
        _ = try await restarted.registry.reconcileInterruptedLaunches()

        // 新实例无会话在途 → 恢复入口放行；Prefix 已释放 → 不得重复清理。
        try await restarted.orchestrator.retryProcessExitRecovery(recordID: record.id)
        XCTAssertEqual(
            fixture.killCount(), killsAfterRelease,
            "重启后不得重复清理已释放的 Prefix"
        )
        let pendingAfterRestart = await restarted.registry.pendingRecoveryRecords(gameID: fixture.game.id)
        XCTAssertTrue(pendingAfterRestart.isEmpty, "重启恢复后不应残留待恢复记录")
        let stateAfterRestart = await restarted.registry.getGame(by: fixture.game.id)?.state
        XCTAssertEqual(stateAfterRestart, .installed)

        // 不遗留阻止新启动的状态：新实例可以直接启动并正常取消。
        let relaunch = await restarted.orchestrator.launch(game: fixture.game)
        guard case .success = relaunch else {
            return XCTFail("重启恢复后应可启动: \(relaunch)")
        }
        await restarted.orchestrator.cancelLaunch()
    }

}
