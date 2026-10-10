// Source: Implementation maintenance split -> Wine catalog and HTTP asset semantics
import XCTest
import Observation
@testable import MiPlay

@MainActor extension MiPlayCoreTests {
    func testCurrentGitHubWineReleaseAssetsAreDiscoverable() async throws {
        let network = try makeMockNetwork(response: Self.currentWineReleasesJSON(assetSize: 128))
        let fixture = try await makeScheduler(networkProvider: network)

        let versions = try await fixture.wineManager.fetchAvailableVersions()

        XCTAssertEqual(
            Set(versions.map(\.tagName)),
            [WineVersionManager.fixedRuntimeTag]
        )
        XCTAssertTrue(versions.allSatisfy { $0.assetName.contains("osx64") })
    }

    /// 设置页展示的「来源」仓库地址必须与下载用的 API 端点指向同一仓库。
    func testSourceRepositoryWebURLMatchesAPIEndpoint() {
        let source = BuiltInWineVersions.officialSource
        XCTAssertEqual(
            source.repositoryWebURL.absoluteString,
            "https://github.com/yaagl/anime-game-wine"
        )
        XCTAssertEqual(source.repositoryWebURL.host, source.allowedAssetHost)
        XCTAssertTrue(
            source.apiEndpoint.path.contains(source.repositoryWebURL.path),
            "API 端点与仓库地址必须指向同一仓库：\(source.apiEndpoint.path) vs \(source.repositoryWebURL.path)"
        )
    }

    func testWineCatalogDiagnosticsAndAllowlistGate() async throws {
        let forbidden = try await makeScheduler(networkProvider: makeWineNetwork(catalogStatus: 403))
        do {
            _ = try await forbidden.wineManager.fetchAvailableVersions()
            XCTFail("Expected GitHub API 403")
        } catch let error as WineVersionManager.VersionManagerError {
            guard case .apiForbidden(let sourceID, let detail) = error else {
                return XCTFail("Unexpected Wine catalog error: \(error)")
            }
            XCTAssertEqual(sourceID, BuiltInWineVersions.officialSource.sourceID)
            XCTAssertTrue(detail.lowercased().contains("forbidden"))
        }

        let rateLimited = try await makeScheduler(networkProvider: makeWineNetwork(catalogStatus: 429))
        do {
            _ = try await rateLimited.wineManager.fetchAvailableVersions()
            XCTFail("Expected GitHub API rate limit")
        } catch let error as WineVersionManager.VersionManagerError {
            guard case .rateLimited(let retryAfter) = error else {
                return XCTFail("Unexpected rate-limit error: \(error)")
            }
            XCTAssertEqual(retryAfter, 60)
        }

        let rejectedAsset = try await makeScheduler(
            networkProvider: makeWineNetwork(
                assetURL: "https://unapproved.example/wine-arm64.tar.xz"
            )
        )
        let versions = try await rejectedAsset.wineManager.fetchAvailableVersions()
        XCTAssertTrue(versions.isEmpty)
        let rejectedEntry = await rejectedAsset.wineManager.cachedAvailableVersion(
            tagName: WineVersionManager.fixedRuntimeTag
        )
        XCTAssertNil(rejectedEntry)

        let invalidVersion = WineVersionInfo(
            id: WineVersionManager.fixedRuntimeTag,
            tagName: WineVersionManager.fixedRuntimeTag,
            name: "Untrusted fixture",
            downloadURL: URL(string: "https://unapproved.example/wine-crossover-11.0-1-osx64-signed.tar.xz")!,
            fileSize: 1,
            publishedAt: Date(),
            assetName: "wine-crossover-11.0-1-osx64-signed.tar.xz"
        )
        let invalidPhases = await collectWinePhases(
            await rejectedAsset.wineManager.downloadAndInstall(version: invalidVersion)
        )
        XCTAssertTrue(invalidPhases.contains {
            if case .failed = $0 { return true }
            return false
        })
        XCTAssertFalse(invalidPhases.contains {
            if case .completed = $0 { return true }
            return false
        })
    }

    func testWineDownloaderRejectsUnapprovedRedirectHost() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = try makeWineArchive(fillerBytes: 64)
        let network = try makeWineNetwork(
            archive: archive,
            downloadResponseURL: "https://unapproved.example/wine-arm64.tar.xz"
        )
        let fileSystem = GameFileSystemRepository(appSupportDirectory: root)
        let process = ProcessManager()
        let logger = LogWriter(fileSystemRepository: fileSystem)
        let downloader = WineVersionDownloader(
            networkProvider: network,
            fileSystemRepository: fileSystem,
            processManager: process,
            logWriter: logger
        )
        let asset = WineVersionDownloader.ApprovedAsset(
            sourceID: BuiltInWineVersions.officialSource.sourceID,
            tagName: WineVersionManager.fixedRuntimeTag,
            url: URL(string: "https://github.com/yaagl/anime-game-wine/releases/download/\(WineVersionManager.fixedRuntimeTag)/wine-crossover-11.0-1-osx64-signed.tar.xz")!,
            assetName: "wine-crossover-11.0-1-osx64-signed.tar.xz",
            fileSize: Int64(archive.count)
        )
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        let phases = await collectWinePhases(
            await downloader.downloadArchive(for: asset, to: staging.path)
        )

        XCTAssertTrue(phases.contains {
            if case .failed(let detail) = $0 { return detail.contains("未批准来源") }
            return false
        }, "phases: \(phases)")
        XCTAssertFalse(phases.contains {
            if case .completed = $0 { return true }
            return false
        })
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.appendingPathComponent("wine.tar.xz").path))
    }

    func testNetworkDownloadRejectsNonHTTPResponse() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let network = try makeDownloadNetwork(
            response: .init(data: Data("payload".utf8), responseIsHTTP: false)
        )
        let destination = root.appendingPathComponent("payload.bin")
        let stream = await network.download(
            from: URL(string: "https://example.test/payload.bin")!,
            to: destination.path
        )

        let progress = await collectDownloadProgress(stream)
        XCTAssertTrue(progress.contains { $0.error == "下载失败: 未收到 HTTP 响应" })
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testNetworkDownloadRejectsMissingResponse() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let network = try makeDownloadNetwork(
            response: .init(data: Data("payload".utf8), sendsResponse: false)
        )
        let destination = root.appendingPathComponent("payload.bin")
        let stream = await network.download(
            from: URL(string: "https://example.test/payload.bin")!,
            to: destination.path
        )

        let progress = await collectDownloadProgress(stream)
        XCTAssertTrue(progress.contains { $0.error != nil })
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testWineAsset403RemainsAccessDenied() async throws {
        try await assertWineAssetHTTPFailure(statusCode: 403)
    }

    func testWineAsset404RemainsResourceNotFound() async throws {
        try await assertWineAssetHTTPFailure(statusCode: 404)
    }

    func testWineAsset429RemainsRateLimited() async throws {
        try await assertWineAssetHTTPFailure(statusCode: 429)
    }

    func testWineAsset5xxRemainsServerError() async throws {
        try await assertWineAssetHTTPFailure(statusCode: 503)
    }

    func testWineRuntimeSetupHTTPFailureIsPersistedAsFailedTask() async throws {
        let fixture = try await makeScheduler(networkProvider: makeWineNetwork(assetStatus: 403))
        let setupReceipt = try await fixture.scheduler.enqueueReceipt(
            type: .wineRuntimeSetup,
            gameId: nil,
            context: ["runtimeIdentity": WineVersionManager.fixedRuntimeTag]
        )
        let result = try await waitForTask(setupReceipt.taskID, scheduler: fixture.scheduler)
        XCTAssertEqual(result.state, .failed)
        XCTAssertTrue(result.error?.contains("403") == true, "error: \(result.error ?? "nil")")
        XCTAssertFalse(result.error?.contains("networkUnavailable") == true)
        XCTAssertNotEqual(result.outcome, "runtimePairReady")
    }

    @MainActor
    func testPerformanceOptionsArePerGameAndPersist() async throws {
        let baseURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: baseURL) }
        let store = PersistenceStore(baseURL: baseURL)
        try await store.writeAppData(AppData())
        let manager = PerformanceOptionManager(
            persistenceStore: store,
            logWriter: LogWriter(fileSystemRepository: GameFileSystemRepository())
        )
        await manager.loadOptions()

        let genshin = GameType.genshinImpact.rawValue
        let starRail = GameType.honkaiStarRail.rawValue
        let zzz = GameType.zenlessZoneZero.rawValue

        // Metal HUD 三款都可用；解锁帧率只对原神/星铁开放（绝区零原生无限帧率）。
        XCTAssertTrue(manager.getOptions(for: genshin).contains { $0.id == "metal_hud" })
        XCTAssertTrue(manager.getOptions(for: zzz).contains { $0.id == "metal_hud" })
        XCTAssertTrue(manager.getOptions(for: genshin).contains { $0.id == "fps_unlock" })
        XCTAssertTrue(manager.getOptions(for: starRail).contains { $0.id == "fps_unlock" })
        XCTAssertFalse(manager.getOptions(for: zzz).contains { $0.id == "fps_unlock" })

        // 每游戏独立：只打开原神的 Metal HUD。
        try await manager.setOption(gameId: genshin, optionId: "metal_hud", enabled: true)
        XCTAssertEqual(manager.getOption(gameId: genshin, optionId: "metal_hud")?.isEnabled, true)
        XCTAssertEqual(manager.getOption(gameId: zzz, optionId: "metal_hud")?.isEnabled, false)

        // 该选项已搁置（用户指令：Metal HUD 等移到「通用设置」的应用级开关）：
        // 即使每游戏开关仍为 true，也不会进入启动清单；HUD 现由
        // `GameEnvironmentSettings.environmentVariables` 在启动时注入。
        XCTAssertTrue(manager.getOptionsForLaunch(gameId: genshin).isEmpty)
        XCTAssertEqual(
            GameEnvironmentSettings(metalHUD: true).environmentVariables["MTL_HUD_ENABLED"],
            "1"
        )

        let persisted = try await store.readAppData()
        XCTAssertEqual(
            persisted.performanceOptions[genshin]?.first(where: { $0.id == "metal_hud" })?.isEnabled,
            true
        )
        XCTAssertEqual(
            persisted.performanceOptions[zzz]?.first(where: { $0.id == "metal_hud" })?.isEnabled,
            false
        )
    }

    @MainActor
    func testSettingsProjectsAssetHTTPFailureWithoutNetworkUnavailableFallback() async throws {
        let fixture = try await makeScheduler(networkProvider: makeWineNetwork(assetStatus: 404))
        let viewModel = SettingsViewModel(
            systemDetector: SystemEnvironmentDetector(),
            wineVersionManager: fixture.wineManager,
            gameRegistry: fixture.registry,
            fileSystemRepository: GameFileSystemRepository(appSupportDirectory: try makeTemporaryDirectory()),
            taskScheduler: fixture.scheduler,
            performanceOptionManager: PerformanceOptionManager(
                persistenceStore: fixture.persistence,
                logWriter: fixture.logger
            )
        )

        await viewModel.loadSettings()
        await viewModel.setupWineRuntime()
        let downloadDeadline = Date().addingTimeInterval(3)
        while Date() < downloadDeadline {
            if viewModel.wineDownloadTask?.state == .failed, viewModel.errorMessage != nil { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertEqual(viewModel.wineDownloadTask?.state, .failed)
        XCTAssertTrue(viewModel.errorMessage?.contains("404") == true, "error: \(viewModel.errorMessage ?? "nil")")
        XCTAssertFalse(viewModel.errorMessage?.contains("networkUnavailable") == true)
    }

    @MainActor
    func testSettingsProjectsOnlyTheFixedWineRuntime() async throws {
        let fixture = try await makeScheduler()
        let viewModel = SettingsViewModel(
            systemDetector: SystemEnvironmentDetector(),
            wineVersionManager: fixture.wineManager,
            gameRegistry: fixture.registry,
            fileSystemRepository: GameFileSystemRepository(appSupportDirectory: try makeTemporaryDirectory()),
            taskScheduler: fixture.scheduler,
            performanceOptionManager: PerformanceOptionManager(
                persistenceStore: fixture.persistence,
                logWriter: fixture.logger
            )
        )

        await viewModel.loadSettings()
        XCTAssertEqual(viewModel.fixedRuntimeTag, WineVersionManager.fixedRuntimeTag)
        XCTAssertFalse(viewModel.sharedPrefixReady)
        XCTAssertTrue(viewModel.sharedPrefixPath.isEmpty)
    }

    func testPerGameSettingsRemainIsolatedAcrossPersistenceRoundTrip() async throws {
        let baseURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: baseURL) }
        let store = PersistenceStore(baseURL: baseURL)
        let genshinID = GameType.genshinImpact.rawValue
        let starRailID = GameType.honkaiStarRail.rawValue
        try await store.writeAppData(AppData(perGameSettings: [
            genshinID: PerGameSettings(gameID: genshinID, metadataDisplayEnabled: false),
            starRailID: PerGameSettings(gameID: starRailID, metadataDisplayEnabled: true)
        ]))

        var data = try await store.readAppData()
        data.perGameSettings[genshinID]?.lastFailure = "metadata conflict"
        try await store.writeAppData(data)

        let restored = try await store.readAppData()
        XCTAssertFalse(restored.perGameSettings[genshinID]?.metadataDisplayEnabled ?? true)
        XCTAssertEqual(restored.perGameSettings[genshinID]?.lastFailure, "metadata conflict")
        XCTAssertTrue(restored.perGameSettings[starRailID]?.metadataDisplayEnabled ?? false)
        XCTAssertNil(restored.perGameSettings[starRailID]?.lastFailure)
    }

    // MARK: - I-1 background cache fingerprint

    func testBackgroundLoadsFirstParsedResource() async throws {
        let baseURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: baseURL) }
        let supportURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: supportURL) }
        let cache = MediaCacheManager(baseURL: supportURL)
        let gameID = GameType.genshinImpact.rawValue
        try await seedBackgroundCache(cache: cache, gameID: gameID, groupID: "bg-still")
        // The video group is fully cached as well; it must not be preferred
        // over the first parsed background entry.
        try await seedBackgroundCache(cache: cache, gameID: gameID, groupID: "bg-video")
        let videoFixture = await cache.cachedFileURL(
            forKey: "video.mp4",
            inDirectory: "\(gameID)/bg-video"
        )
        try Data("video fixture".utf8).write(to: videoFixture)

        let store = PersistenceStore(baseURL: baseURL)
        try await store.writeAppData(AppData())
        let service = try makeBackgroundService(
            cacheBase: supportURL,
            store: store,
            network: makeMockNetwork(response: Self.mixedBackgroundResponseJSON())
        )

        // 用户指令（2026-10-05）：每款游戏固定使用解析到的第一个背景资源。
        await service.loadMedia(for: gameID)

        guard case .ready(let path, let isVideo) = service.getMediaState(for: gameID) else {
            return XCTFail("Expected ready media for the first parsed group")
        }
        XCTAssertFalse(isVideo)
        XCTAssertTrue(path.hasSuffix("/bg-still/background.png"))
        XCTAssertEqual(service.getBackgroundStillImagePath(for: gameID), path)
    }

    func testBackgroundCachePrunedOnlyWhenCollectionFingerprintChanges() async throws {
        let baseURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: baseURL) }
        let supportURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: supportURL) }
        let cache = MediaCacheManager(baseURL: supportURL)
        let gameID = GameType.genshinImpact.rawValue
        try await seedBackgroundCache(cache: cache, gameID: gameID, groupID: "bg-1")
        try await seedBackgroundCache(cache: cache, gameID: gameID, groupID: "bg-2")
        try await writeFingerprint(
            cache: cache,
            gameID: gameID,
            groupIDs: ["bg-1"]
        )

        let store = PersistenceStore(baseURL: baseURL)
        try await store.writeAppData(AppData())
        let service = try makeBackgroundService(
            cacheBase: supportURL,
            store: store,
            network: makeMockNetwork(response: Self.backgroundResponseJSON(groupIDs: ["bg-2"]))
        )

        await service.loadMedia(for: gameID)

        let groups = try await cache.groupDirectoryNames(forGameId: gameID)
        XCTAssertEqual(groups, ["bg-2"])
        let persisted = try await cache.readCacheMetadata(
            forGameId: gameID,
            filename: ".background-fingerprint.json"
        )
        XCTAssertNotNil(persisted)
    }

    func testBackgroundCachePrunesSameGroupWhenResourceIdentityChanges() async throws {
        let baseURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: baseURL) }
        let supportURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: supportURL) }
        let cache = MediaCacheManager(baseURL: supportURL)
        let gameID = GameType.genshinImpact.rawValue
        let backgroundFile = await cache.cachedFileURL(
            forKey: "background.png",
            inDirectory: "\(gameID)/bg-1"
        )
        try Data("old cached resource".utf8).write(to: backgroundFile)
        try await writeFingerprint(
            cache: cache,
            gameID: gameID,
            groupIDs: ["bg-1"],
            resourceURLs: ["bg-1": "https://example.com/bg-1-old.webp"]
        )

        let store = PersistenceStore(baseURL: baseURL)
        try await store.writeAppData(AppData(
            backgroundModes: [gameID: BackgroundMediaService.BackgroundMode.static.rawValue]
        ))
        let service = try makeBackgroundService(
            cacheBase: supportURL,
            store: store,
            network: makeMockNetwork(
                response: Self.backgroundResponseJSON(
                    groupIDs: ["bg-1"],
                    resourceURLs: ["bg-1": "https://example.com/bg-1-new.webp"]
                )
            )
        )
        await service.loadSettings()
        await service.loadMedia(for: gameID)

        XCTAssertFalse(FileManager.default.fileExists(atPath: backgroundFile.path))
        let fingerprint = await service.loadPersistedCollectionFingerprint(for: gameID)
        XCTAssertEqual(
            fingerprint?.groups.first?.backgroundIdentity,
            "https://example.com/bg-1-new.webp"
        )
    }

    func testRefreshMetadataDoesNotDeleteDiagnosticCachedGroup() async throws {
        let baseURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: baseURL) }
        let supportURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: supportURL) }
        let cache = MediaCacheManager(baseURL: supportURL)
        let gameID = GameType.genshinImpact.rawValue
        let backgroundFile = await cache.cachedFileURL(
            forKey: "background.png",
            inDirectory: "\(gameID)/bg-1"
        )
        try Data("cached resource".utf8).write(to: backgroundFile)

        let store = PersistenceStore(baseURL: baseURL)
        try await store.writeAppData(AppData(
            backgroundModes: [gameID: BackgroundMediaService.BackgroundMode.static.rawValue],
            lastCachedBackgroundIds: [gameID: "bg-1"]
        ))
        let service = try makeBackgroundService(
            cacheBase: supportURL,
            store: store,
            network: makeMockNetwork(response: Self.backgroundResponseJSON(groupIDs: ["bg-1"]))
        )
        await service.loadSettings()
        await service.refreshCache(for: gameID)

        XCTAssertTrue(FileManager.default.fileExists(atPath: backgroundFile.path))
        guard case .ready(let localPath, let isVideo) = service.getMediaState(for: gameID) else {
            return XCTFail("Expected cached static background to remain ready")
        }
        XCTAssertEqual(localPath, backgroundFile.path)
        XCTAssertFalse(isVideo)
    }

    func testMissingBackgroundFingerprintNeverPrunesCaches() async throws {
        let baseURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: baseURL) }
        let supportURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: supportURL) }
        let cache = MediaCacheManager(baseURL: supportURL)
        let gameID = GameType.genshinImpact.rawValue
        try await seedBackgroundCache(cache: cache, gameID: gameID, groupID: "bg-1")
        try await seedBackgroundCache(cache: cache, gameID: gameID, groupID: "bg-2")

        let store = PersistenceStore(baseURL: baseURL)
        try await store.writeAppData(AppData())
        let service = try makeBackgroundService(
            cacheBase: supportURL,
            store: store,
            network: makeMockNetwork(response: Self.backgroundResponseJSON())
        )

        await service.loadMedia(for: gameID)

        let groups = try await cache.groupDirectoryNames(forGameId: gameID)
        XCTAssertEqual(Set(groups), ["bg-1", "bg-2"])
    }

    // MARK: - 转码原子性与缓存门槛

    func testTranscodeFailureLeavesNoPartialOutput() async throws {
        let baseURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: baseURL) }
        let stub = try makeStubFFmpeg(in: baseURL, exitCode: 1)
        let fileSystem = GameFileSystemRepository(appSupportDirectory: baseURL)
        let logger = LogWriter(fileSystemRepository: fileSystem)
        let transcoder = MediaTranscoder(
            processManager: ProcessManager(),
            logWriter: logger,
            ffmpegPath: stub.path
        )
        let inputURL = baseURL.appendingPathComponent("video.webm")
        let outputURL = baseURL.appendingPathComponent("video.mp4")
        try Data("webm fixture".utf8).write(to: inputURL)

        do {
            _ = try await transcoder.transcodeWebMToMP4(
                inputPath: inputURL.path,
                outputPath: outputURL.path
            )
            XCTFail("Expected stub transcode failure")
        } catch {}

        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path + ".part"))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: MediaTranscoder.temporaryOutputPath(for: outputURL.path)
            ),
            "视频临时文件（video.part.mp4）必须被清理"
        )
    }

    func testTranscodeSuccessReplacesOutputAtomically() async throws {
        let baseURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: baseURL) }
        let stub = try makeStubFFmpeg(in: baseURL, exitCode: 0)
        let fileSystem = GameFileSystemRepository(appSupportDirectory: baseURL)
        let logger = LogWriter(fileSystemRepository: fileSystem)
        let transcoder = MediaTranscoder(
            processManager: ProcessManager(),
            logWriter: logger,
            ffmpegPath: stub.path
        )
        let inputURL = baseURL.appendingPathComponent("background.webp")
        let outputURL = baseURL.appendingPathComponent("background.png")
        try Data("webp fixture".utf8).write(to: inputURL)
        try Data("stale output".utf8).write(to: outputURL)

        let result = try await transcoder.transcodeWebPToPNG(
            inputPath: inputURL.path,
            outputPath: outputURL.path
        )

        XCTAssertEqual(result, outputURL.path)
        XCTAssertEqual(try String(contentsOf: outputURL, encoding: .utf8), "stub-transcode")
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path + ".part"))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: MediaTranscoder.temporaryOutputPath(for: outputURL.path)
            ),
            "图片临时文件（background.part.png）必须被清理"
        )
    }

    func testCacheGateRejectsZeroByteArtifacts() async throws {
        let baseURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: baseURL) }
        let supportURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: supportURL) }
        let cache = MediaCacheManager(baseURL: supportURL)
        let gameID = GameType.genshinImpact.rawValue
        let artifactURL = await cache.cachedFileURL(
            forKey: "background.png",
            inDirectory: "\(gameID)/bg-1"
        )
        try Data().write(to: artifactURL)

        let store = PersistenceStore(baseURL: baseURL)
        try await store.writeAppData(AppData())
        let service = try makeBackgroundService(
            cacheBase: supportURL,
            store: store,
            network: makeMockNetwork(response: Self.backgroundResponseJSON())
        )

        let rejected = await service.hasSubCache(
            for: gameID,
            backgroundId: "bg-1",
            type: .background,
            ext: "png"
        )
        XCTAssertFalse(rejected)

        try Data("background fixture".utf8).write(to: artifactURL)
        let accepted = await service.hasSubCache(
            for: gameID,
            backgroundId: "bg-1",
            type: .background,
            ext: "png"
        )
        XCTAssertTrue(accepted)
    }

    func testVideoCacheRequiresCurrentEncodingQuality() async throws {
        let baseURL = try makeTemporaryDirectory()
        let supportURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: baseURL) }
        defer { try? FileManager.default.removeItem(at: supportURL) }
        let cache = MediaCacheManager(baseURL: supportURL)
        let gameID = GameType.genshinImpact.rawValue
        let videoURL = await cache.cachedFileURL(forKey: "video.mp4", inDirectory: "\(gameID)/bg-1")
        try Data("previous video".utf8).write(to: videoURL)
        let service = try makeBackgroundService(
            cacheBase: supportURL,
            store: PersistenceStore(baseURL: baseURL),
            network: makeMockNetwork(response: Self.backgroundResponseJSON())
        )
        var accepted = await service.hasSubCache(for: gameID, backgroundId: "bg-1", type: .video, ext: "mp4")
        XCTAssertFalse(accepted, "Old videos must be regenerated after the quality change")
        try "h264-crf18-slow".write(toFile: videoURL.path + ".quality", atomically: true, encoding: .utf8)
        accepted = await service.hasSubCache(for: gameID, backgroundId: "bg-1", type: .video, ext: "mp4")
        XCTAssertFalse(accepted)
        try MediaTranscoder.videoQualityProfile.write(toFile: videoURL.path + ".quality", atomically: true, encoding: .utf8)
        accepted = await service.hasSubCache(for: gameID, backgroundId: "bg-1", type: .video, ext: "mp4")
        XCTAssertTrue(accepted)
        try Data().write(to: videoURL)
        accepted = await service.hasSubCache(for: gameID, backgroundId: "bg-1", type: .video, ext: "mp4")
        XCTAssertFalse(accepted, "A quality marker cannot make an empty video valid")
    }

    private func makeStubFFmpeg(in directory: URL, exitCode: Int32) throws -> URL {
        let scriptURL = directory.appendingPathComponent("stub-ffmpeg-\(exitCode).sh")
        // 与真实 ffmpeg 一致：输出路径必须以可识别的扩展名结尾，否则无法选择
        // 封装器（`video.mp4.part` 这类写法必须被这里抓住）。
        let script = """
        #!/bin/sh
        for last; do :; done
        case "$last" in
          *.mp4|*.png) ;;
          *) printf "Unable to choose an output format for '%s'\\n" "$last" >&2; exit 234 ;;
        esac
        printf 'stub-transcode' > "$last"
        exit \(exitCode)
        """
        try Data(script.utf8).write(to: scriptURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: scriptURL.path
        )
        return scriptURL
    }

    private func makeBackgroundService(
        cacheBase: URL,
        store: PersistenceStore,
        network: NetworkDownloadProvider
    ) throws -> BackgroundMediaService {
        let fileSystem = GameFileSystemRepository(appSupportDirectory: cacheBase)
        let logger = LogWriter(fileSystemRepository: fileSystem)
        return BackgroundMediaService(
            mediaTranscoder: MediaTranscoder(processManager: ProcessManager(), logWriter: logger),
            mediaCacheManager: MediaCacheManager(baseURL: cacheBase),
            networkProvider: network,
            persistenceStore: store,
            logWriter: logger
        )
    }

    private func seedBackgroundCache(
        cache: MediaCacheManager,
        gameID: String,
        groupID: String
    ) async throws {
        let url = await cache.cachedFileURL(
            forKey: "background.png",
            inDirectory: "\(gameID)/\(groupID)"
        )
        try Data("background fixture".utf8).write(to: url)
    }

    private func writeFingerprint(
        cache: MediaCacheManager,
        gameID: String,
        groupIDs: [String],
        resourceURLs: [String: String] = [:]
    ) async throws {
        let groups = groupIDs.map { groupID in
            BackgroundMediaService.BackgroundGroupFingerprint(
                groupID: groupID,
                type: "BACKGROUND_TYPE_STATIC",
                version: groupID,
                backgroundIdentity: resourceURLs[groupID] ?? "https://example.com/\(groupID).webp",
                videoIdentity: nil,
                themeIdentity: nil
            )
        }
        let fingerprint = BackgroundMediaService.BackgroundCollectionFingerprint(
            sourceID: "hoyoPlay",
            groups: groups
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(fingerprint)
        try await cache.writeCacheMetadata(
            data,
            forGameId: gameID,
            filename: ".background-fingerprint.json"
        )
    }

    @MainActor
    func testMetalFXOptionExpandsValueIntoLaunchEnvironment() throws {
        let option = try XCTUnwrap(
            PerformanceOptionManager.defaultOptions.first { $0.id == "metalfx_spatial_upscale" }
        )
        XCTAssertTrue(option.requiresValue)
        XCTAssertEqual(option.displayValue, "2")

        // `launchEnvironment()` 只负责展开模板，不判断启用状态：未启用的选项由
        // `getOptionsForLaunch` 过滤，不会进入启动清单。默认系数 2 会展开进
        // `DXMT_CONFIG`，与界面显示保持一致。
        XCTAssertEqual(
            option.launchEnvironment(),
            [
                "DXMT_METALFX_SPATIAL_SWAPCHAIN": "1",
                "DXMT_CONFIG": "d3d11.metalSpatialUpscaleFactor=2;",
            ]
        )

        // 开启 + 自定义系数：开关与 `d3d11.metalSpatialUpscaleFactor` 同时下发。
        var enabled = option
        enabled.isEnabled = true
        enabled.value = "1.33"
        let environment = enabled.launchEnvironment()
        XCTAssertEqual(environment["DXMT_METALFX_SPATIAL_SWAPCHAIN"], "1")
        XCTAssertEqual(environment["DXMT_CONFIG"], "d3d11.metalSpatialUpscaleFactor=1.33;")
        XCTAssertNil(environment["DXMT_CONFIG_FILE"], "系数走 DXMT_CONFIG，不写配置文件路径")

        // 越界/缺失的值不会下发成非法系数：夹取到 1.0–2.0，缺失回落默认 2。
        var outOfRange = option
        outOfRange.value = "5"
        XCTAssertEqual(outOfRange.launchEnvironment()["DXMT_CONFIG"], "d3d11.metalSpatialUpscaleFactor=2;")
        var missingValue = option
        missingValue.value = nil
        XCTAssertEqual(missingValue.launchEnvironment()["DXMT_CONFIG"], "d3d11.metalSpatialUpscaleFactor=2;")
    }

    @MainActor
    func testLaunchEnvironmentMergesOptionsWithLaterOptionsWinning() throws {
        var upscale = try XCTUnwrap(
            PerformanceOptionManager.defaultOptions.first { $0.id == "metalfx_spatial_upscale" }
        )
        upscale.isEnabled = true
        upscale.value = "1.5"
        var hud = try XCTUnwrap(
            PerformanceOptionManager.defaultOptions.first { $0.id == "metal_hud" }
        )
        hud.isEnabled = true

        let environment = PerformanceOption.launchEnvironment(for: [hud, upscale])
        XCTAssertEqual(environment["MTL_HUD_ENABLED"], "1")
        // 不再覆盖面板元素与尺寸：使用 Metal HUD 的系统默认（Lite）布局。
        XCTAssertNil(environment["MTL_HUD_ELEMENTS"])
        XCTAssertNil(environment["MTL_HUD_SCALE"])
        XCTAssertEqual(environment["DXMT_METALFX_SPATIAL_SWAPCHAIN"], "1")
        XCTAssertEqual(environment["DXMT_CONFIG"], "d3d11.metalSpatialUpscaleFactor=1.5;")

        // 关闭的选项不产生任何环境变量。
        XCTAssertTrue(PerformanceOption.launchEnvironment(for: []).isEmpty)
    }

    @MainActor
    func testPerformanceOptionNormalizesFactorIntoSupportedRange() {
        XCTAssertEqual(PerformanceOption.normalizedValue("2"), "2")
        XCTAssertEqual(PerformanceOption.normalizedValue(" 1.5 "), "1.5")
        XCTAssertEqual(PerformanceOption.normalizedValue("1.33"), "1.33")
        XCTAssertEqual(PerformanceOption.normalizedValue("1,33"), "1.33", "小数逗号应被接受")
        // 越界夹取到 DXMT 支持的 1.0–2.0。
        XCTAssertEqual(PerformanceOption.normalizedValue("5"), "2")
        XCTAssertEqual(PerformanceOption.normalizedValue("0.5"), "1")
        // 不可解析的输入被拒绝。
        XCTAssertNil(PerformanceOption.normalizedValue(""))
        XCTAssertNil(PerformanceOption.normalizedValue("abc"))
        XCTAssertNil(PerformanceOption.normalizedValue("1.5x"))
    }

    @MainActor
    func testMetalFXOptionValuePersistsPerGameButDoesNotApplyWhileSuspended() async throws {
        let baseURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: baseURL) }
        let store = PersistenceStore(baseURL: baseURL)
        try await store.writeAppData(AppData())
        let manager = PerformanceOptionManager(
            persistenceStore: store,
            logWriter: LogWriter(fileSystemRepository: GameFileSystemRepository())
        )
        await manager.loadOptions()

        let genshin = GameType.genshinImpact.rawValue
        let zzz = GameType.zenlessZoneZero.rawValue

        try await manager.setOption(gameId: genshin, optionId: "metalfx_spatial_upscale", enabled: true)
        try await manager.setValue(gameId: genshin, optionId: "metalfx_spatial_upscale", value: "1.33")

        // 每游戏独立：绝区零保持关闭与默认系数。
        XCTAssertEqual(manager.getOption(gameId: zzz, optionId: "metalfx_spatial_upscale")?.isEnabled, false)
        XCTAssertEqual(manager.getOption(gameId: zzz, optionId: "metalfx_spatial_upscale")?.displayValue, "2")

        // 启动环境：选项已搁置（`isSuspended`），即使 AppData 里仍是启用状态，
        // 也不会把 DXMT 变量注入启动环境；持久化的开关与系数保留，恢复功能后可用。
        let launchEnvironment = PerformanceOption.launchEnvironment(
            for: manager.getOptionsForLaunch(gameId: genshin)
        )
        XCTAssertNil(launchEnvironment["DXMT_CONFIG"])
        XCTAssertNil(launchEnvironment["DXMT_METALFX_SPATIAL_SWAPCHAIN"])
        XCTAssertTrue(manager.getOptionsForLaunch(gameId: zzz).isEmpty)

        // 持久化：重新加载后系数与开关都保留。
        let persisted = try await store.readAppData()
        let saved = try XCTUnwrap(
            persisted.performanceOptions[genshin]?.first { $0.id == "metalfx_spatial_upscale" }
        )
        XCTAssertTrue(saved.isEnabled)
        XCTAssertEqual(saved.value, "1.33")

        let reloaded = PerformanceOptionManager(
            persistenceStore: store,
            logWriter: LogWriter(fileSystemRepository: GameFileSystemRepository())
        )
        await reloaded.loadOptions()
        XCTAssertEqual(
            reloaded.getOption(gameId: genshin, optionId: "metalfx_spatial_upscale")?.displayValue,
            "1.33"
        )
    }

    @MainActor
    func testPerformanceOptionRejectsUnparsableValueAndKeepsPrevious() async throws {
        let baseURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: baseURL) }
        let store = PersistenceStore(baseURL: baseURL)
        try await store.writeAppData(AppData())
        let manager = PerformanceOptionManager(
            persistenceStore: store,
            logWriter: LogWriter(fileSystemRepository: GameFileSystemRepository())
        )
        await manager.loadOptions()

        let genshin = GameType.genshinImpact.rawValue
        try await manager.setValue(gameId: genshin, optionId: "metalfx_spatial_upscale", value: "1.5")
        do {
            try await manager.setValue(gameId: genshin, optionId: "metalfx_spatial_upscale", value: "abc")
            XCTFail("非法参数应被拒绝")
        } catch let error as PerformanceOptionManager.OptionError {
            guard case .invalidValue = error else {
                return XCTFail("错误类型应为 invalidValue，实际 \(error)")
            }
        }

        // 被拒绝的输入不改变内存状态，也不写入持久化。
        XCTAssertEqual(manager.getOption(gameId: genshin, optionId: "metalfx_spatial_upscale")?.displayValue, "1.5")
        let persisted = try await store.readAppData()
        XCTAssertEqual(
            persisted.performanceOptions[genshin]?.first { $0.id == "metalfx_spatial_upscale" }?.value,
            "1.5"
        )
    }

    @MainActor
    func testSettingsViewModelPersistsMetalFXFactorAndReportsInvalidInput() async throws {
        let fixture = try await makeScheduler()
        let viewModel = SettingsViewModel(
            systemDetector: SystemEnvironmentDetector(),
            wineVersionManager: fixture.wineManager,
            gameRegistry: fixture.registry,
            fileSystemRepository: GameFileSystemRepository(appSupportDirectory: try makeTemporaryDirectory()),
            taskScheduler: fixture.scheduler,
            performanceOptionManager: PerformanceOptionManager(
                persistenceStore: fixture.persistence,
                logWriter: fixture.logger
            )
        )
        await viewModel.loadSettings()

        let genshin = GameType.genshinImpact.rawValue
        await viewModel.setPerformanceOption(
            gameID: genshin,
            optionID: "metalfx_spatial_upscale",
            enabled: true
        )
        await viewModel.setPerformanceOptionValue(
            gameID: genshin,
            optionID: "metalfx_spatial_upscale",
            value: "1.33"
        )

        XCTAssertEqual(
            viewModel.performanceOption(gameID: genshin, optionID: "metalfx_spatial_upscale")?.displayValue,
            "1.33"
        )
        XCTAssertTrue(
            viewModel.options(for: genshin).contains { $0.id == "metalfx_spatial_upscale" && $0.isEnabled }
        )

        // 其它游戏不受影响。
        let zzz = GameType.zenlessZoneZero.rawValue
        XCTAssertEqual(
            viewModel.performanceOption(gameID: zzz, optionID: "metalfx_spatial_upscale")?.isEnabled,
            false
        )

        // 不可解析的输入被拒绝并回报给设置窗口的错误呈现。
        await viewModel.setPerformanceOptionValue(
            gameID: genshin,
            optionID: "metalfx_spatial_upscale",
            value: "abc"
        )
        XCTAssertNotNil(viewModel.errorMessage)
        XCTAssertEqual(
            viewModel.performanceOption(gameID: genshin, optionID: "metalfx_spatial_upscale")?.displayValue,
            "1.33"
        )
    }

    /// 设置窗口的开关依赖 `@Observable` 的失效通知重绘。若开关状态要等异步
    /// 持久化完成才更新，SwiftUI 在 setter 返回后立刻读到的仍是旧值，开关会
    /// 弹回原位（用户实测症状）。因此这里复现 Toggle 的读写时序。
    @MainActor
    func testPerformanceOptionToggleAppliesSynchronouslyAndInvalidatesObservers() async throws {
        let fixture = try await makeScheduler()
        let viewModel = SettingsViewModel(
            systemDetector: SystemEnvironmentDetector(),
            wineVersionManager: fixture.wineManager,
            gameRegistry: fixture.registry,
            fileSystemRepository: GameFileSystemRepository(appSupportDirectory: try makeTemporaryDirectory()),
            taskScheduler: fixture.scheduler,
            performanceOptionManager: PerformanceOptionManager(
                persistenceStore: fixture.persistence,
                logWriter: fixture.logger
            )
        )
        await viewModel.loadSettings()

        let genshin = GameType.genshinImpact.rawValue
        XCTAssertFalse(
            viewModel.options(for: genshin).contains { $0.id == "metal_hud" && $0.isEnabled }
        )

        let observedChange = ObservationFlag()
        withObservationTracking {
            _ = viewModel.performanceOption(gameID: genshin, optionID: "metal_hud")?.isEnabled
        } onChange: {
            observedChange.mark()
        }

        // Toggle 的 setter：必须同步落到界面读到的状态上。
        let accepted = viewModel.applyPerformanceOptionChange(
            gameID: genshin,
            optionID: "metal_hud",
            enabled: true
        )
        XCTAssertTrue(accepted)
        XCTAssertTrue(observedChange.isSet, "同步应用必须触发观察者失效，否则界面不会重绘")
        XCTAssertEqual(
            viewModel.performanceOption(gameID: genshin, optionID: "metal_hud")?.isEnabled,
            true,
            "setter 返回后立刻读取必须已是新值，否则开关会回弹"
        )

        // 后台持久化完成后仍然一致，且写入磁盘。
        try await waitForOptionPersisted(
            gameID: genshin,
            optionID: "metal_hud",
            isEnabled: true,
            store: fixture.persistence
        )
        XCTAssertEqual(
            viewModel.performanceOption(gameID: genshin, optionID: "metal_hud")?.isEnabled,
            true
        )
    }

    /// 等待后台持久化把开关写入 AppData。
    @MainActor
    private func waitForOptionPersisted(
        gameID: String,
        optionID: String,
        isEnabled: Bool,
        store: PersistenceStore
    ) async throws {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            let persisted = try await store.readAppData()
            let saved = persisted.performanceOptions[gameID]?.first { $0.id == optionID }
            if saved?.isEnabled == isEnabled { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("性能选项未在超时前持久化")
    }

}
