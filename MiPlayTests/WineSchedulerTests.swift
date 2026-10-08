// Source: Implementation maintenance split -> Wine task lifecycle, cancellation, and readiness
import XCTest
@testable import MiPlay

@MainActor extension MiPlayCoreTests {
    func testExistingManagedRuntimeIsPreparedWithoutCatalogNetwork() async throws {
        let appSupport = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: appSupport) }
        let persistenceURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: persistenceURL) }

        let runtimeRoot = appSupport
            .appendingPathComponent("WineVersions", isDirectory: true)
            .appendingPathComponent(WineVersionManager.fixedRuntimeTag, isDirectory: true)
        let binDirectory = runtimeRoot.appendingPathComponent("bin", isDirectory: true)
        try FileManager.default.createDirectory(at: binDirectory, withIntermediateDirectories: true)
        let wine = binDirectory.appendingPathComponent("wine")
        let wineScript = """
        #!/bin/sh
        case "$1" in
          --version) printf 'wine-11.0\\n' ;;
          wineboot)
            mkdir -p "$WINEPREFIX/drive_c" "$WINEPREFIX/dosdevices"
            ;;
          *) exit 0 ;;
        esac
        """
        try Data(wineScript.utf8).write(to: wine)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wine.path)

        let fileSystem = GameFileSystemRepository(appSupportDirectory: appSupport)
        let persistence = PersistenceStore(baseURL: persistenceURL)
        try await persistence.writeAppData(AppData())
        let logger = LogWriter(fileSystemRepository: fileSystem)
        let process = ProcessManager()
        let provider = WineRuntimeProvider(
            processManager: process,
            fileSystemRepository: fileSystem,
            logWriter: logger
        )
        let manager = WineVersionManager(
            networkProvider: NetworkDownloadProvider(),
            fileSystemRepository: fileSystem,
            persistenceStore: persistence,
            wineVersionDownloader: WineVersionDownloader(
                networkProvider: NetworkDownloadProvider(),
                fileSystemRepository: fileSystem,
                processManager: process,
                logWriter: logger
            ),
            logWriter: logger,
            wineRuntimeProvider: provider
        )
        await manager.initialize()

        let didPrepare = try await manager.setupExistingManagedRuntimeIfPresent()
        XCTAssertTrue(didPrepare)

        let prefixURL = appSupport
            .appendingPathComponent("WinePrefixes", isDirectory: true)
            .appendingPathComponent("shared", isDirectory: true)
        XCTAssertTrue(FileManager.default.fileExists(atPath: prefixURL.appendingPathComponent("drive_c").path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: prefixURL.appendingPathComponent("dosdevices").path))

        let persisted = try await persistence.readAppData()
        XCTAssertEqual(persisted.managedWineRuntime?.identity, WineVersionManager.fixedRuntimeTag)
        XCTAssertEqual(persisted.sharedWinePrefix?.identity, WineVersionManager.sharedPrefixIdentity)
        XCTAssertEqual(persisted.sharedWinePrefix?.absolutePath, prefixURL.path)
        let readiness = await manager.checkReadiness()
        XCTAssertEqual(readiness, .ready(versionPath: runtimeRoot.path))
    }

    func testPreLaunchValidatorAllowsLaunchWhenIntegrityManifestIsUnavailable() async throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        try Data("exe".utf8).write(to: directory.appendingPathComponent("YuanShen.exe"))
        try Data("[General]\ngame_version=7.0.0\n".utf8)
            .write(to: directory.appendingPathComponent("config.ini"))

        let supportDirectory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: supportDirectory) }
        let fileSystem = GameFileSystemRepository(
            appSupportDirectory: supportDirectory,
            bookmarkResolver: BookmarkResolver(
                resolve: { _ in .init(url: directory, isStale: false) },
                refresh: { _, _ in Data([2]) },
                startAccessing: { _ in true },
                stopAccessing: { _ in }
            )
        )
        let store = PersistenceStore(baseURL: try makeTemporaryDirectory())
        let logger = LogWriter(fileSystemRepository: fileSystem)
        let process = ProcessManager()
        let pair = try makeFixedWineRuntimePair(appSupport: supportDirectory)
        try await store.writeAppData(AppData(
            games: [
                Game(
                    id: GameType.genshinImpact.rawValue,
                    type: .genshinImpact,
                    location: GameLocation(
                        gameID: GameType.genshinImpact.rawValue,
                        bookmarkData: Data([1]),
                        lastKnownPath: directory.path,
                        resolutionState: .resolvable
                    ),
                    state: .installed,
                    version: "7.0.0",
                    lastLaunchDate: nil,
                    solutionApplications: []
                )
            ],
            managedWineRuntime: pair.runtime,
            sharedWinePrefix: pair.prefix
        ))

        let registry = GameRegistry(
            persistenceStore: store,
            fileSystemRepository: fileSystem,
            stateMachine: GameStateMachine(),
            systemDetector: SystemEnvironmentDetector { _ in
                (free: UInt64.max, total: UInt64.max)
            },
            logWriter: logger
        )
        await registry.initialize()
        let wineDownloader = WineVersionDownloader(
            networkProvider: NetworkDownloadProvider(),
            fileSystemRepository: fileSystem,
            processManager: process,
            logWriter: logger
        )
        let wine = WineRuntimeProvider(processManager: process, fileSystemRepository: fileSystem)
        let manager = WineVersionManager(
            networkProvider: NetworkDownloadProvider(),
            fileSystemRepository: fileSystem,
            persistenceStore: store,
            wineVersionDownloader: wineDownloader,
            logWriter: logger,
            wineRuntimeProvider: wine
        )
        await manager.initialize()
        let validator = PreLaunchValidator(
            fileSystemRepository: fileSystem,
            systemDetector: SystemEnvironmentDetector { _ in
                (free: UInt64.max, total: UInt64.max)
            },
            wineRuntimeProvider: wine,
            wineVersionManager: manager,
            integrityVerifier: FileIntegrityVerifier(fileSystemRepository: fileSystem),
            gameRegistry: registry
        )

        guard let registeredGame = await registry.getGame(by: GameType.genshinImpact.rawValue) else {
            return XCTFail("Expected registered game")
        }
        let result = await validator.validate(game: registeredGame)
        XCTAssertTrue(result.isPassed)
        XCTAssertTrue(result.errors.isEmpty)
        XCTAssertTrue(result.warnings.contains {
            if case .integrityUnsupported = $0 { return true }
            return false
        })
    }

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

        let pair = try makeFixedWineRuntimePair(appSupport: supportDirectory)
        let wine = WineRuntimeProvider(
            processManager: process,
            fileSystemRepository: fileSystem
        )

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
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            if await registry.getGame(by: game.id)?.state == .installed { break }
            try await Task.sleep(for: .milliseconds(50))
        }

        let finalState = await registry.getGame(by: game.id)?.state
        XCTAssertEqual(finalState, GameBusinessState.installed)
        let prefixPath = await wine.getPrefixPath(for: game.id)
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

    func testLaunchPreflightFailureCommitsLaunchFailedStateAndDiagnostic() async throws {
        let game = Game(
            id: GameType.genshinImpact.rawValue,
            type: .genshinImpact,
            location: nil,
            state: .installed,
            version: nil,
            lastLaunchDate: nil,
            solutionApplications: []
        )
        let fixture = try await makeScheduler(games: [game])
        let taskID = try await fixture.scheduler.enqueue(
            type: .gameLaunch,
            gameId: game.id
        )
        let task = try await waitForTask(taskID, scheduler: fixture.scheduler)

        XCTAssertEqual(task.state, .failed)
        let updatedGame = await fixture.registry.getGame(by: game.id)
        XCTAssertEqual(updatedGame?.state, .launchFailed)
        XCTAssertTrue(
            updatedGame?.lastLaunchFailure?
                .contains("security-scoped bookmark") == true
        )
    }

    func testWineSchedulerReturnsOneReceiptAndRejectsResourceConflict() async throws {
        let network = try makeWineNetwork(metadataDelay: 0.5)
        let fixture = try await makeScheduler(networkProvider: network)
        let first = try await fixture.scheduler.enqueueReceipt(
            type: .wineRuntimeSetup,
            gameId: nil,
            context: ["runtimeIdentity": WineVersionManager.fixedRuntimeTag]
        )
        let duplicate = try await fixture.scheduler.enqueueReceipt(
            type: .wineRuntimeSetup,
            gameId: nil,
            context: ["runtimeIdentity": WineVersionManager.fixedRuntimeTag]
        )

        XCTAssertEqual(first.taskID, duplicate.taskID)
        XCTAssertEqual(first.resourceKeys, ["sharedWinePrefix", "wineRuntime"])
        XCTAssertEqual(first.persistence, .committed)

        do {
            _ = try await fixture.scheduler.enqueueReceipt(
                type: .wineRuntimeSetup,
                gameId: nil,
                context: ["runtimeIdentity": "wine-devel-9.0"]
            )
            XCTFail("Expected fixed runtime validation failure")
        } catch let error as TaskScheduler.SchedulerError {
            guard case .invalidRequest = error else {
                return XCTFail("Unexpected scheduler error: \(error)")
            }
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
        let receipt = try await fixture.scheduler.enqueueReceipt(
            type: .wineRuntimeSetup,
            gameId: nil,
            context: ["runtimeIdentity": WineVersionManager.fixedRuntimeTag]
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
        XCTAssertTrue(exportedLogs.contains("\"wineTag\":\"\(WineVersionManager.fixedRuntimeTag)\""))
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
        let progressStream = await fixture.scheduler.makeProgressStream()
        let progressCollector = Task { () -> TaskProgress? in
            for await progress in progressStream {
                guard progress.phase == "正在下载 Wine", progress.download != nil else { continue }
                return progress
            }
            return nil
        }

        let receipt = try await fixture.scheduler.enqueueReceipt(
            type: .wineRuntimeSetup,
            gameId: nil,
            context: ["runtimeIdentity": WineVersionManager.fixedRuntimeTag]
        )
        let result = try await waitForTask(receipt.taskID, scheduler: fixture.scheduler)
        let progress = await progressCollector.value

        XCTAssertEqual(result.state, .completed, result.error ?? result.recovery ?? "no detail")
        XCTAssertNotNil(progress)
        XCTAssertGreaterThan(progress?.download?.totalBytes ?? 0, 0)
        XCTAssertGreaterThanOrEqual(progress?.download?.bytesReceived ?? -1, 0)
        XCTAssertGreaterThanOrEqual(progress?.download?.speed ?? -1, 0)
    }

    func testWineSchedulerRetainsTransferSizeDuringExtraction() async throws {
        let archive = try makeWineArchive(fillerBytes: 20_000)
        let network = try makeWineNetwork(archive: archive, chunkDelay: 0.01)
        let fixture = try await makeScheduler(networkProvider: network)
        let progressStream = await fixture.scheduler.makeProgressStream()
        let progressCollector = Task { () -> TaskProgress? in
            for await progress in progressStream {
                guard progress.phase == "正在解压 Wine" else { continue }
                return progress
            }
            return nil
        }

        let receipt = try await fixture.scheduler.enqueueReceipt(
            type: .wineRuntimeSetup,
            gameId: nil,
            context: ["runtimeIdentity": WineVersionManager.fixedRuntimeTag]
        )
        let result = try await waitForTask(receipt.taskID, scheduler: fixture.scheduler)
        let progress = await progressCollector.value

        XCTAssertEqual(result.state, .completed, result.error ?? result.recovery ?? "no detail")
        XCTAssertNotNil(progress)
        XCTAssertGreaterThan(progress?.download?.bytesReceived ?? -1, 0)
        XCTAssertGreaterThan(progress?.download?.totalBytes ?? 0, 0)
        XCTAssertEqual(progress?.download?.speed, 0)
    }

    func testWineRuntimeCommitNormalizesBinaryPermissions() async throws {
        let archive = try makeWineArchive(fillerBytes: 20_000)
        let fixture = try await makeScheduler(networkProvider: makeWineNetwork(archive: archive))
        let receipt = try await fixture.scheduler.enqueueReceipt(
            type: .wineRuntimeSetup,
            gameId: nil,
            context: ["runtimeIdentity": WineVersionManager.fixedRuntimeTag]
        )
        let result = try await waitForTask(receipt.taskID, scheduler: fixture.scheduler)

        XCTAssertEqual(result.state, .completed, result.error ?? result.recovery ?? "no detail")
        let runtime = await fixture.wineManager.validatedRuntime()
        XCTAssertNotNil(runtime)
        if let binaryPath = runtime?.rootURL.appendingPathComponent("bin/wine").path {
            let mode = try FileManager.default.attributesOfItem(atPath: binaryPath)[.posixPermissions] as? NSNumber
            XCTAssertEqual(mode.map { $0.intValue & 0o111 }, 0o111)
        }
    }

    func testWineInterruptedTaskBecomesRecoveryRequiredWithoutAutomaticRetry() async throws {
        let baseURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: baseURL) }
        let store = PersistenceStore(baseURL: baseURL)
        let record = PersistedTaskRecord(
            id: "wine-interrupted",
            type: ScheduledTaskType.wineRuntimeSetup.rawValue,
            gameID: nil,
            status: ScheduledTaskState.running.rawValue,
            phase: "正在下载 Wine",
            progress: 0.4,
            outcome: nil,
            error: nil,
            recovery: nil,
            createdAt: Date(),
            context: ["runtimeIdentity": WineVersionManager.fixedRuntimeTag, "stagingPath": "/tmp/does-not-retry"],
            resourceKeys: ["sharedWinePrefix", "wineRuntime"]
        )
        try await store.writeAppData(AppData(taskHistory: [record]))
        let fixture = try await makeScheduler(store: store)

        await fixture.scheduler.initialize()
        let repaired = try await fixture.scheduler.taskSnapshot(id: ScheduledTaskID("wine-interrupted"))
        let data = try await store.readAppData()

        XCTAssertEqual(repaired.state, .failed)
        XCTAssertFalse(repaired.recovery?.isEmpty ?? true)
        XCTAssertTrue(data.recoveryRecords.contains {
            $0.kind == "wineRuntimeSetup" && $0.target == WineVersionManager.fixedRuntimeTag && $0.resolvedAt == nil
        })
        XCTAssertEqual(data.taskHistory.first?.status, ScheduledTaskState.failed.rawValue)
    }

    func testWineInstallDoesNotCompleteWhenPersistenceFailsAndCanRetry() async throws {
        let archive = try makeWineArchive(fillerBytes: 1_000)
        let network = try makeWineNetwork(archive: archive)
        let fixture = try await makeScheduler(networkProvider: network)
        let version = WineVersionInfo(
            id: WineVersionManager.fixedRuntimeTag,
            tagName: WineVersionManager.fixedRuntimeTag,
            name: "Test",
            downloadURL: URL(string: "https://github.com/yaagl/anime-game-wine/releases/download/wine-crossover-11.0-1-signed/wine-crossover-11.0-1-osx64-signed.tar.xz")!,
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
        XCTAssertNil(failedData.managedWineRuntime)
        XCTAssertNil(failedData.sharedWinePrefix)

        await fixture.persistence.clearWriteFailure()
        let secondPhases = await collectWinePhases(
            fixture.wineManager.downloadAndInstall(version: version, taskID: UUID())
        )
        XCTAssertTrue(secondPhases.contains { if case .installed = $0 { return true }; return false }, "phases: \(secondPhases)")
        XCTAssertTrue(secondPhases.contains { if case .completed = $0 { return true }; return false }, "phases: \(secondPhases)")
        let completedData = try await fixture.persistence.readAppData()
        XCTAssertEqual(completedData.managedWineRuntime?.identity, WineVersionManager.fixedRuntimeTag)
        XCTAssertEqual(completedData.sharedWinePrefix?.identity, WineVersionManager.sharedPrefixIdentity)
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

    func testBackgroundMediaLoadRunsThroughScheduler() async throws {
        let fixture = try await makeScheduler()
        let gameID = GameType.genshinImpact.rawValue
        let imageURL = try makeTemporaryDirectory().appendingPathComponent("background.png")
        try Data("background fixture".utf8).write(to: imageURL)

        await fixture.backgroundMediaService.setBackgroundMode(
            for: gameID,
            mode: .custom,
            customPath: imageURL.path
        )
        let taskID = try await fixture.scheduler.enqueue(
            type: .backgroundMediaLoad,
            gameId: gameID
        )
        let task = try await waitForTask(taskID, scheduler: fixture.scheduler)

        XCTAssertEqual(task.state, .completed)
        XCTAssertEqual(task.outcome, "mediaReady")
        if case .ready(let path, let isVideo) = fixture.backgroundMediaService.getMediaState(for: gameID) {
            XCTAssertEqual(path, imageURL.path)
            XCTAssertFalse(isVideo)
        } else {
            XCTFail("Expected custom background media to be ready")
        }
    }

    func testTaskSchedulerRejectsUnsupportedAndMalformedRequests() async throws {
        let fixture = try await makeScheduler()

        do {
            _ = try await fixture.scheduler.enqueue(
                type: .wineRuntimeSetup,
                gameId: "g",
                context: ["runtimeIdentity": WineVersionManager.fixedRuntimeTag]
            )
            XCTFail("Expected malformed Wine setup request")
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

    func testReadOnlyEvidenceTasksDoNotBlockMediaOrLaunchResources() async throws {
        let fixture = try await makeScheduler(games: [])
        let scheduler = fixture.scheduler

        let versionCheck = ScheduledTask(type: .versionCheck, gameId: "g")
        let integrity = ScheduledTask(type: .integrityVerification, gameId: "g")
        let mediaLoad = ScheduledTask(type: .backgroundMediaLoad, gameId: "g")
        let launch = ScheduledTask(type: .gameLaunch, gameId: "g")

        let checkKeys = await scheduler.resourceKeys(for: versionCheck)
        let integrityKeys = await scheduler.resourceKeys(for: integrity)
        let mediaKeys = await scheduler.resourceKeys(for: mediaLoad)
        let launchKeys = await scheduler.resourceKeys(for: launch)

        // A running version/integrity check must not block the game's media
        // load or launch; those waits used to leave installed games without a
        // background for the duration of a multi-minute pkg_version scan.
        XCTAssertTrue(checkKeys.contains("game:g:evidence"))
        XCTAssertTrue(checkKeys.isDisjoint(with: mediaKeys))
        XCTAssertTrue(checkKeys.isDisjoint(with: launchKeys))
        XCTAssertTrue(mediaKeys.isDisjoint(with: integrityKeys))
        // 同一游戏的重复媒体加载按 per-game 键去重；不同游戏之间互不阻塞，
        // 三款游戏的下载与转码因此可以并行、相互重叠。
        XCTAssertTrue(mediaKeys.contains("game:g:media"))
        XCTAssertFalse(mediaKeys.contains("backgroundMedia"))
        let otherMediaLoad = ScheduledTask(type: .backgroundMediaLoad, gameId: "h")
        let otherMediaKeys = await scheduler.resourceKeys(for: otherMediaLoad)
        XCTAssertTrue(mediaKeys.isDisjoint(with: otherMediaKeys))
        XCTAssertFalse(mediaKeys.contains("game:g:lifecycle"))
        XCTAssertTrue(launchKeys.contains("game:g:lifecycle"))
    }

    func testLaunchCompatibilityEnvironmentStagesAssetsAndRestoresGameFiles() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileManager = FileManager.default

        let gameDirectory = root.appendingPathComponent("Genshin Impact", isDirectory: true)
        let pluginsDirectory = gameDirectory.appendingPathComponent("YuanShen_Data/Plugins", isDirectory: true)
        try fileManager.createDirectory(at: pluginsDirectory, withIntermediateDirectories: true)
        try Data("driver".utf8).write(to: gameDirectory.appendingPathComponent("HoYoKProtect.sys"))
        let vulkanURL = pluginsDirectory.appendingPathComponent("vulkan-1.dll")
        try Data("bundled-vulkan".utf8).write(to: vulkanURL)

        let prefix = root.appendingPathComponent("prefix", isDirectory: true)
        let system32 = prefix.appendingPathComponent("drive_c/windows/system32", isDirectory: true)
        let syswow64 = prefix.appendingPathComponent("drive_c/windows/syswow64", isDirectory: true)
        try fileManager.createDirectory(at: system32, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: syswow64, withIntermediateDirectories: true)

        let runtimeRoot = root.appendingPathComponent("runtime", isDirectory: true)
        let windowsLib = runtimeRoot.appendingPathComponent("lib/wine/x86_64-windows", isDirectory: true)
        let unixLib = runtimeRoot.appendingPathComponent("lib/wine/x86_64-unix", isDirectory: true)
        try fileManager.createDirectory(at: windowsLib, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: unixLib, withIntermediateDirectories: true)
        for name in ["d3d10core.dll", "d3d11.dll", "dxgi.dll", "nvapi64.dll", "nvngx.dll"] {
            try Data("build-\(name)".utf8).write(to: windowsLib.appendingPathComponent(name))
        }
        try Data("build-winemetal.so".utf8).write(to: unixLib.appendingPathComponent("winemetal.so"))

        let assets = root.appendingPathComponent("assets", isDirectory: true)
        let dxmt = assets.appendingPathComponent("dxmt", isDirectory: true)
        let protonextras = assets.appendingPathComponent("protonextras", isDirectory: true)
        try fileManager.createDirectory(at: dxmt, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: protonextras, withIntermediateDirectories: true)
        for name in ["d3d10core.dll", "d3d11.dll", "dxgi.dll", "winemetal.dll"] {
            try Data("dxmt-\(name)".utf8).write(to: dxmt.appendingPathComponent(name))
        }
        try Data("dxmt-winemetal.so".utf8).write(to: dxmt.appendingPathComponent("winemetal.so"))
        for name in ["steam64.exe", "steam32.exe", "lsteamclient64.dll", "lsteamclient32.dll"] {
            try Data("protonextras-\(name)".utf8).write(to: protonextras.appendingPathComponent(name))
        }

        let staging = LaunchCompatibilityEnvironment.stage(
            gameType: .genshinImpact,
            gameDirectory: gameDirectory,
            prefixURL: prefix,
            runtimeRootURL: runtimeRoot,
            assetRootURL: assets,
            fileManager: fileManager
        )

        XCTAssertTrue(staging.missingAssetNames.isEmpty)
        XCTAssertEqual(staging.stagedGameFiles.count, 1)
        XCTAssertEqual(
            try String(contentsOfFile: system32.appendingPathComponent("HoYoKProtect.sys").path, encoding: .utf8),
            "driver"
        )
        XCTAssertEqual(
            try String(contentsOfFile: windowsLib.appendingPathComponent("d3d11.dll").path, encoding: .utf8),
            "dxmt-d3d11.dll"
        )
        XCTAssertEqual(
            try String(contentsOfFile: windowsLib.appendingPathComponent("d3d11.dll.bak").path, encoding: .utf8),
            "build-d3d11.dll"
        )
        XCTAssertEqual(
            try String(contentsOfFile: system32.appendingPathComponent("d3d11.dll").path, encoding: .utf8),
            "build-d3d11.dll"
        )
        XCTAssertEqual(
            try String(contentsOfFile: system32.appendingPathComponent("winemetal.dll").path, encoding: .utf8),
            "dxmt-winemetal.dll"
        )
        XCTAssertEqual(
            try String(contentsOfFile: unixLib.appendingPathComponent("winemetal.so").path, encoding: .utf8),
            "dxmt-winemetal.so"
        )
        XCTAssertEqual(
            try String(contentsOfFile: system32.appendingPathComponent("steam.exe").path, encoding: .utf8),
            "protonextras-steam64.exe"
        )
        XCTAssertFalse(fileManager.fileExists(atPath: vulkanURL.path))
        XCTAssertTrue(fileManager.fileExists(atPath: vulkanURL.path + ".bak"))

        let invocation = LaunchCompatibilityEnvironment.launchInvocation(
            gameType: .genshinImpact,
            executablePath: "/games/YuanShen.exe",
            prefixURL: prefix,
            fileManager: fileManager
        )
        // 国服 7.1.0 实测：直启会被 HoYoKProtect 内核驱动加载失败挡住（WDFLDR），
        // 因此默认走 Steam 兼容存根；存根路径的代价是强制退出菜单多一个 "wine" 条目
        // （详见 `LaunchCompatibilityEnvironment.launchInvocation` 注释）。
        XCTAssertEqual(invocation.program, "C:\\windows\\system32\\steam.exe")
        XCTAssertEqual(invocation.arguments, ["Z:\\games\\YuanShen.exe"])
        XCTAssertEqual(
            LaunchCompatibilityEnvironment.additionalEnvironment(for: .genshinImpact)["WINEESYNC"],
            "1"
        )

        LaunchCompatibilityEnvironment.restore(staging.stagedGameFiles, fileManager: fileManager)
        XCTAssertEqual(
            try String(contentsOfFile: vulkanURL.path, encoding: .utf8),
            "bundled-vulkan"
        )
        XCTAssertFalse(fileManager.fileExists(atPath: vulkanURL.path + ".bak"))
    }

    func testLaunchAppBundleStagesNamedApplicationForManagedRuntime() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileManager = FileManager.default

        let assetRoot = root.appendingPathComponent("RuntimeAssets", isDirectory: true)
        let launcherResource = root.appendingPathComponent("GameLauncher")
        try Data("launcher fixture".utf8).write(to: launcherResource)

        let bundle = LaunchCompatibilityEnvironment.prepareAppBundle(
            gameType: .genshinImpact,
            assetRootURL: assetRoot,
            launcherResourceURL: launcherResource
        )
        let staged = try XCTUnwrap(bundle)
        XCTAssertTrue(fileManager.fileExists(atPath: staged.bundleURL.path))

        let executable = staged.bundleURL.appendingPathComponent("Contents/MacOS/GenshinImpact")
        XCTAssertTrue(fileManager.fileExists(atPath: executable.path))
        XCTAssertTrue(fileManager.isExecutableFile(atPath: executable.path))

        let plistURL = staged.bundleURL.appendingPathComponent("Contents/Info.plist")
        let plistData = try Data(contentsOf: plistURL)
        let plist = try PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any]
        XCTAssertEqual(plist?["CFBundleName"] as? String, GameType.genshinImpact.displayName)
        XCTAssertEqual(plist?["CFBundleExecutable"] as? String, "GenshinImpact")
        XCTAssertEqual(plist?["CFBundleIdentifier"] as? String, "dev.miplay.game.GenshinImpact")

        XCTAssertTrue(staged.logURL.path.hasPrefix(staged.bundleURL.path))
        XCTAssertTrue(staged.statusURL.path.hasPrefix(staged.bundleURL.path))
    }

    func testLaunchCompatibilityEnvironmentReportsMissingAssetsAndDirectInvocation() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileManager = FileManager.default

        let gameDirectory = root.appendingPathComponent("ZenlessZoneZero Game", isDirectory: true)
        let pluginsDirectory = gameDirectory.appendingPathComponent("ZenlessZoneZero_Data/Plugins/x86_64", isDirectory: true)
        try fileManager.createDirectory(at: pluginsDirectory, withIntermediateDirectories: true)
        try Data("driver".utf8).write(to: gameDirectory.appendingPathComponent("HoYoKProtect.sys"))
        let vulkanURL = pluginsDirectory.appendingPathComponent("vulkan-1.dll")
        try Data("bundled-vulkan".utf8).write(to: vulkanURL)

        let prefix = root.appendingPathComponent("prefix", isDirectory: true)
        try fileManager.createDirectory(
            at: prefix.appendingPathComponent("drive_c/windows/system32", isDirectory: true),
            withIntermediateDirectories: true
        )
        let runtimeRoot = root.appendingPathComponent("runtime", isDirectory: true)
        let assets = root.appendingPathComponent("assets", isDirectory: true)

        let staging = LaunchCompatibilityEnvironment.stage(
            gameType: .zenlessZoneZero,
            gameDirectory: gameDirectory,
            prefixURL: prefix,
            runtimeRootURL: runtimeRoot,
            assetRootURL: assets,
            fileManager: fileManager
        )

        XCTAssertEqual(staging.missingAssetNames.count, 5)
        XCTAssertEqual(staging.stagedGameFiles.count, 1)
        XCTAssertTrue(fileManager.fileExists(atPath: vulkanURL.path + ".bak"))

        let invocation = LaunchCompatibilityEnvironment.launchInvocation(
            gameType: .zenlessZoneZero,
            executablePath: "/games/ZenlessZoneZero.exe",
            prefixURL: prefix,
            fileManager: fileManager
        )
        XCTAssertEqual(invocation.program, "/games/ZenlessZoneZero.exe")
        XCTAssertTrue(invocation.arguments.isEmpty)
        XCTAssertEqual(
            LaunchCompatibilityEnvironment.additionalEnvironment(for: .zenlessZoneZero)["WINEMSYNC"],
            "1"
        )

        LaunchCompatibilityEnvironment.restore(staging.stagedGameFiles, fileManager: fileManager)
        XCTAssertTrue(fileManager.fileExists(atPath: vulkanURL.path))
    }

}
