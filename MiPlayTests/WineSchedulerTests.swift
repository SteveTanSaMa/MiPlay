// Source: Implementation maintenance split -> Wine task lifecycle, cancellation, and readiness
import XCTest
@testable import MiPlay

@MainActor extension MiPlayCoreTests {
    func testPreLaunchValidatorStaleWritebackFailureBlocksValidation() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("exe".utf8).write(to: directory.appendingPathComponent("YuanShen.exe"))
        try Data("[General]\ngame_version=1.2.3\n".utf8)
            .write(to: directory.appendingPathComponent("config.ini"))

        let counters = LockedBookmarkCounters()
        let resolver = BookmarkResolver(
            resolve: { _ in .init(url: directory, isStale: true) },
            refresh: { _, _ in counters.incrementRefresh(); return Data([2]) },
            startAccessing: { _ in counters.incrementStart(); return true },
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
                resolutionState: .stale
            ),
            state: .installed,
            version: "1.2.3",
            lastLaunchDate: nil,
            solutionApplications: []
        )
        try await store.writeAppData(AppData(games: [game]))
        let logger = LogWriter(fileSystemRepository: fileSystem)
        let registry = GameRegistry(
            persistenceStore: store,
            fileSystemRepository: fileSystem,
            stateMachine: GameStateMachine(),
            systemDetector: SystemEnvironmentDetector(),
            logWriter: logger
        )
        await registry.initialize()
        await store.injectWriteFailure("stale bookmark 写回失败")

        let process = ProcessManager()
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
            logWriter: logger
        )
        let validator = PreLaunchValidator(
            fileSystemRepository: fileSystem,
            systemDetector: SystemEnvironmentDetector(),
            wineRuntimeProvider: WineRuntimeProvider(
                processManager: process,
                fileSystemRepository: fileSystem
            ),
            wineVersionManager: wineManager,
            gameRegistry: registry
        )

        let result = await validator.validate(game: game)
        guard case .failed(let errors) = result else {
            return XCTFail("Expected stale bookmark writeback failure")
        }
        XCTAssertTrue(errors.contains { $0.localizedDescription.contains("stale bookmark 写回失败") })
        let counts = counters.snapshot()
        XCTAssertEqual(counts.0, counts.1)
        XCTAssertEqual(counts.2, 1)
        let persisted = try await store.readAppData()
        XCTAssertEqual(persisted.games.first?.location?.bookmarkData, Data([1]))
        XCTAssertEqual(persisted.games.first?.state, .installed)
    }

    func testLaunchOrchestratorRefreshesStaleBookmarkAndCommitsExitState() async throws {
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
            resolve: { _ in .init(url: directory, isStale: true) },
            refresh: { _, _ in counters.incrementRefresh(); return Data([2]) },
            startAccessing: { _ in counters.incrementStart(); return true },
            stopAccessing: { _ in counters.incrementStop() }
        )
        let supportDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: supportDirectory) }
        let fileSystem = GameFileSystemRepository(
            appSupportDirectory: supportDirectory,
            bookmarkResolver: resolver
        )
        let store = PersistenceStore(baseURL: try makeTemporaryDirectory())
        let logger = LogWriter(fileSystemRepository: fileSystem)
        let process = ProcessManager()

        let wineBinary = supportDirectory
            .appendingPathComponent("WineVersions/wine-devel-9.0/bin/wine")
        try FileManager.default.createDirectory(
            at: wineBinary.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createSymbolicLink(
            at: wineBinary,
            withDestinationURL: URL(fileURLWithPath: "/bin/sh")
        )
        let prefixDirectory = supportDirectory
            .appendingPathComponent("WinePrefixes/\(GameType.genshinImpact.rawValue)")
        try FileManager.default.createDirectory(at: prefixDirectory, withIntermediateDirectories: true)
        try Data(
            "mkdir -p \"$WINEPREFIX/drive_c\"\n".utf8
        ).write(to: prefixDirectory.appendingPathComponent("wineboot"))

        let hash = try await fileSystem.calculateSHA256(of: executable.path)
        let game = Game(
            id: GameType.genshinImpact.rawValue,
            type: GameType.genshinImpact,
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
        try await store.writeAppData(AppData(
            games: [game],
            selectedWineVersion: "wine-devel-9.0",
            installedWineVersions: ["wine-devel-9.0"]
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
            logWriter: logger
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
            wineRuntimeProvider: WineRuntimeProvider(
                processManager: process,
                fileSystemRepository: fileSystem
            ),
            wineVersionManager: wineManager,
            integrityVerifier: verifier,
            gameRegistry: registry
        )
        let launch = LaunchOrchestrator(
            preLaunchValidator: validator,
            wineRuntimeProvider: WineRuntimeProvider(
                processManager: process,
                fileSystemRepository: fileSystem
            ),
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
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if await registry.getGame(by: game.id)?.state == .installed { break }
            try await Task.sleep(for: .milliseconds(50))
        }

        let finalState = await registry.getGame(by: game.id)?.state
        XCTAssertEqual(finalState, .installed)
        let prefixPath = await WineRuntimeProvider(
            processManager: process,
            fileSystemRepository: fileSystem
        ).getPrefixPath(for: game.id)
        XCTAssertEqual(
            try String(contentsOfFile: "\(prefixPath)/launch-arg", encoding: .utf8),
            executable.path
        )
        let persisted = try await store.readAppData()
        XCTAssertEqual(persisted.games.first?.location?.bookmarkData, Data([2]))
        let counts = counters.snapshot()
        XCTAssertEqual(counts.0, counts.1)
        XCTAssertGreaterThanOrEqual(counts.0, 2)
    }

    func testWineSchedulerReturnsOneReceiptAndRejectsResourceConflict() async throws {
        let network = try makeWineNetwork(metadataDelay: 0.5)
        let fixture = try await makeScheduler(networkProvider: network)
        let first = try await fixture.scheduler.enqueueReceipt(
            type: .wineVersionDownload,
            gameId: nil,
            context: ["tagName": "wine-devel-9.0"]
        )
        let duplicate = try await fixture.scheduler.enqueueReceipt(
            type: .wineVersionDownload,
            gameId: nil,
            context: ["tagName": "wine-devel-9.0"]
        )

        XCTAssertEqual(first.taskID, duplicate.taskID)
        XCTAssertEqual(first.resourceKeys, ["wineRuntime"])
        XCTAssertEqual(first.persistence, .committed)

        do {
            _ = try await fixture.scheduler.enqueueReceipt(
                type: .wineVersionDownload,
                gameId: nil,
                context: ["tagName": "wine-crossover-21.2.0"]
            )
            XCTFail("Expected wineRuntime conflict")
        } catch let error as TaskScheduler.SchedulerError {
            guard case .conflict(_, let conflictingTaskID, _) = error else {
                return XCTFail("Unexpected scheduler error: \(error)")
            }
            XCTAssertEqual(conflictingTaskID, first.taskID)
        }

        try await fixture.scheduler.cancel(taskId: first.taskID)
        let cancelled = try await waitForTask(first.taskID, scheduler: fixture.scheduler)
        XCTAssertEqual(cancelled.state, .cancelled)
        XCTAssertEqual(cancelled.outcome, "cancelledBeforeStart")
    }

    func testWineDownloadCancellationCancelsURLSessionAndCleansStaging() async throws {
        let archive = try makeWineArchive(fillerBytes: 1_000)
        let network = try makeWineNetwork(archive: archive, metadataDelay: 2, chunkDelay: 0.05)
        let fixture = try await makeScheduler(networkProvider: network)
        let catalogReceipt = try await fixture.scheduler.enqueueReceipt(
            type: .wineCatalogQuery,
            gameId: nil,
            context: ["sourceID": "officialGitHub", "policyRevision": "2026-08-03"]
        )
        let catalog = try await waitForTask(catalogReceipt.taskID, scheduler: fixture.scheduler)
        XCTAssertEqual(catalog.state, .completed)
        let receipt = try await fixture.scheduler.enqueueReceipt(
            type: .wineVersionDownload,
            gameId: nil,
            context: ["tagName": "wine-devel-9.0"]
        )

        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline {
            if let task = try? await fixture.scheduler.taskSnapshot(id: receipt.taskID),
               task.state == .running,
               ["正在获取 Wine 版本信息", "正在下载 Wine", "正在解压 Wine"].contains(task.phaseDescription) {
                break
            }
            try await Task.sleep(for: .milliseconds(20))
        }

        try await fixture.scheduler.cancel(taskId: receipt.taskID)
        let result = try await waitForTask(receipt.taskID, scheduler: fixture.scheduler)
        XCTAssertEqual(result.state, .cancelled, result.error ?? result.recovery ?? "no detail")
        XCTAssertEqual(result.outcome, "cleanupVerified", result.error ?? result.recovery ?? "no detail")

        let exportedLogs = try await fixture.logger.exportLogs()
        XCTAssertTrue(exportedLogs.contains("\"eventName\":\"wine.asset.cancel\""))
        XCTAssertTrue(exportedLogs.contains("\"wineTag\":\"wine-devel-9.0\""))
        XCTAssertTrue(exportedLogs.contains("\"taskID\":\"\(receipt.taskID.id)\""))

        let versionsDirectory = await fixture.wineManager.wineVersionsDirectory()
        let stagingDirectory = versionsDirectory.appendingPathComponent(".staging")
        let remainingStaging = (try? FileManager.default.contentsOfDirectory(atPath: stagingDirectory.path)) ?? []
        XCTAssertTrue(remainingStaging.isEmpty, "remaining staging entries: \(remainingStaging)")
    }

    func testWineSchedulerPublishesDownloadMetrics() async throws {
        let archive = try makeWineArchive(fillerBytes: 20_000)
        let network = try makeWineNetwork(archive: archive, chunkDelay: 0.01)
        let fixture = try await makeScheduler(networkProvider: network)
        let catalogReceipt = try await fixture.scheduler.enqueueReceipt(
            type: .wineCatalogQuery,
            gameId: nil,
            context: ["sourceID": "officialGitHub", "policyRevision": "2026-08-03"]
        )
        let catalogResult = try await waitForTask(catalogReceipt.taskID, scheduler: fixture.scheduler)
        XCTAssertEqual(catalogResult.state, .completed)

        let progressStream = await fixture.scheduler.makeProgressStream()
        let progressCollector = Task { () -> TaskProgress? in
            for await progress in progressStream {
                guard progress.phase == "正在下载 Wine", progress.download != nil else { continue }
                return progress
            }
            return nil
        }

        let receipt = try await fixture.scheduler.enqueueReceipt(
            type: .wineVersionDownload,
            gameId: nil,
            context: ["tagName": "wine-devel-9.0"]
        )
        let result = try await waitForTask(receipt.taskID, scheduler: fixture.scheduler)
        let progress = await progressCollector.value

        XCTAssertEqual(result.state, .completed, result.error ?? result.recovery ?? "no detail")
        XCTAssertNotNil(progress)
        XCTAssertGreaterThan(progress?.download?.totalBytes ?? 0, 0)
        XCTAssertGreaterThanOrEqual(progress?.download?.bytesReceived ?? -1, 0)
        XCTAssertGreaterThanOrEqual(progress?.download?.speed ?? -1, 0)
    }

    func testWineInterruptedTaskBecomesRecoveryRequiredWithoutAutomaticRetry() async throws {
        let baseURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: baseURL) }
        let store = PersistenceStore(baseURL: baseURL)
        let record = PersistedTaskRecord(
            id: "wine-interrupted",
            type: ScheduledTaskType.wineVersionDownload.rawValue,
            gameID: nil,
            status: ScheduledTaskState.running.rawValue,
            phase: "正在下载 Wine",
            progress: 0.4,
            outcome: nil,
            error: nil,
            recovery: nil,
            createdAt: Date(),
            context: ["tagName": "wine-devel-9.0", "stagingPath": "/tmp/does-not-retry"],
            resourceKeys: ["wineRuntime"]
        )
        try await store.writeAppData(AppData(taskHistory: [record]))
        let fixture = try await makeScheduler(store: store)

        await fixture.scheduler.initialize()
        let repaired = try await fixture.scheduler.taskSnapshot(id: ScheduledTaskID("wine-interrupted"))
        let data = try await store.readAppData()

        XCTAssertEqual(repaired.state, .failed)
        XCTAssertFalse(repaired.recovery?.isEmpty ?? true)
        XCTAssertTrue(data.recoveryRecords.contains {
            $0.kind == "wineInstall" && $0.target == "wine-devel-9.0" && $0.resolvedAt == nil
        })
        XCTAssertEqual(data.taskHistory.first?.status, ScheduledTaskState.failed.rawValue)
    }

    func testWineInstallDoesNotCompleteWhenPersistenceFailsAndCanRetry() async throws {
        let archive = try makeWineArchive(fillerBytes: 1_000)
        let network = try makeWineNetwork(archive: archive)
        let fixture = try await makeScheduler(networkProvider: network)
        let version = WineVersionInfo(
            id: "wine-devel-9.0",
            tagName: "wine-devel-9.0",
            name: "Test",
            downloadURL: URL(string: "https://github.com/yaagl/anime-game-wine/releases/download/wine-devel-9.0/wine-arm64.tar.xz")!,
            fileSize: Int64(archive.count),
            publishedAt: Date()
        )

        await fixture.persistence.injectWriteFailure("安装记录写入失败")
        let firstPhases = await collectWinePhases(
            fixture.wineManager.downloadAndInstall(version: version, taskID: UUID())
        )
        XCTAssertTrue(firstPhases.contains { if case .failed = $0 { return true }; return false })
        XCTAssertFalse(firstPhases.contains { if case .completed = $0 { return true }; return false })
        let failedData = try await fixture.persistence.readAppData()
        XCTAssertFalse(failedData.installedWineVersions.contains("wine-devel-9.0"))

        await fixture.persistence.clearWriteFailure()
        let secondPhases = await collectWinePhases(
            fixture.wineManager.downloadAndInstall(version: version, taskID: UUID())
        )
        XCTAssertTrue(secondPhases.contains { if case .installed = $0 { return true }; return false }, "phases: \(secondPhases)")
        XCTAssertTrue(secondPhases.contains { if case .completed = $0 { return true }; return false }, "phases: \(secondPhases)")
        let completedData = try await fixture.persistence.readAppData()
        XCTAssertTrue(completedData.installedWineVersions.contains("wine-devel-9.0"))
    }

    func testScheduledTaskCancellationPoliciesMatchSideEffectBoundaries() {
        XCTAssertEqual(
            ScheduledTask(type: .versionCheck, gameId: "g").cancellationPolicy,
            .beforeSideEffect
        )
        XCTAssertEqual(
            ScheduledTask(type: .solutionApply, gameId: "g").cancellationPolicy,
            .cleanupAfterSideEffect
        )
        XCTAssertEqual(
            ScheduledTask(type: .solutionRevert, gameId: "g").cancellationPolicy,
            .notCancellable
        )
    }

    func testTaskSchedulerRejectsUnsupportedAndMalformedRequests() async throws {
        let fixture = try await makeScheduler()

        do {
            _ = try await fixture.scheduler.enqueue(type: .wineVersionDownload, gameId: "g")
            XCTFail("Expected malformed Wine download request")
        } catch let error as TaskScheduler.SchedulerError {
            guard case .invalidRequest = error else {
                return XCTFail("Unexpected scheduler error: \(error)")
            }
        }

        do {
            _ = try await fixture.scheduler.enqueue(type: .versionCheck, gameId: nil)
            XCTFail("Expected missing game ID")
        } catch let error as TaskScheduler.SchedulerError {
            guard case .invalidRequest = error else {
                return XCTFail("Unexpected scheduler error: \(error)")
            }
        }

        do {
            _ = try await fixture.scheduler.enqueue(type: .solutionApply, gameId: "g")
            XCTFail("Expected missing solution ID")
        } catch let error as TaskScheduler.SchedulerError {
            guard case .invalidRequest = error else {
                return XCTFail("Unexpected scheduler error: \(error)")
            }
        }
    }

}
