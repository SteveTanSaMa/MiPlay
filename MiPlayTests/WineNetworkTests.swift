// Source: Implementation maintenance split -> Wine catalog and HTTP asset semantics
import XCTest
@testable import MiPlay

@MainActor extension MiPlayCoreTests {
    func testCurrentGitHubWineReleaseAssetsAreDiscoverable() async throws {
        let network = try makeMockNetwork(response: Self.currentWineReleasesJSON(assetSize: 128))
        let fixture = try await makeScheduler(networkProvider: network)

        let versions = try await fixture.wineManager.fetchAvailableVersions()

        XCTAssertEqual(
            Set(versions.map(\.tagName)),
            Set([
                "wine-crossover-11.0-1-signed",
                "wine-crossover-11.0-1",
                "wine-11.0-signed",
                "wine-11.8-signed"
            ])
        )
        XCTAssertTrue(versions.allSatisfy { $0.assetName.contains("osx64") })
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
        let rejectedEntry = await rejectedAsset.wineManager.cachedAvailableVersion(tagName: "wine-devel-9.0")
        XCTAssertNil(rejectedEntry)

        let invalidVersion = WineVersionInfo(
            id: "wine-devel-9.0",
            tagName: "wine-devel-9.0",
            name: "Untrusted fixture",
            downloadURL: URL(string: "https://unapproved.example/wine-arm64.tar.xz")!,
            fileSize: 1,
            publishedAt: Date()
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
            tagName: "wine-devel-9.0",
            url: URL(string: "https://github.com/yaagl/anime-game-wine/releases/download/wine-devel-9.0/wine-arm64.tar.xz")!,
            assetName: "wine-arm64.tar.xz",
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

    func testWineAssetHTTPFailureIsPersistedAsFailedTask() async throws {
        let fixture = try await makeScheduler(networkProvider: makeWineNetwork(assetStatus: 403))
        let catalogReceipt = try await fixture.scheduler.enqueueReceipt(
            type: .wineCatalogQuery,
            gameId: nil,
            context: ["sourceID": "officialGitHub", "policyRevision": "2026-08-03"]
        )
        let catalogResult = try await waitForTask(catalogReceipt.taskID, scheduler: fixture.scheduler)
        XCTAssertEqual(catalogResult.state, .completed)

        let downloadReceipt = try await fixture.scheduler.enqueueReceipt(
            type: .wineVersionDownload,
            gameId: nil,
            context: ["tagName": "wine-devel-9.0"]
        )
        let result = try await waitForTask(downloadReceipt.taskID, scheduler: fixture.scheduler)
        XCTAssertEqual(result.state, .failed)
        XCTAssertTrue(result.error?.contains("403") == true, "error: \(result.error ?? "nil")")
        XCTAssertFalse(result.error?.contains("networkUnavailable") == true)
        XCTAssertNotEqual(result.outcome, "wineInstalled")
    }

    @MainActor
    func testSettingsProjectsAssetHTTPFailureWithoutNetworkUnavailableFallback() async throws {
        let fixture = try await makeScheduler(networkProvider: makeWineNetwork(assetStatus: 404))
        let viewModel = SettingsViewModel(
            persistenceStore: fixture.persistence,
            systemDetector: SystemEnvironmentDetector(),
            wineVersionManager: fixture.wineManager,
            gameRegistry: fixture.registry,
            fileSystemRepository: GameFileSystemRepository(appSupportDirectory: try makeTemporaryDirectory()),
            taskScheduler: fixture.scheduler
        )

        await viewModel.loadSettings()
        let catalogDeadline = Date().addingTimeInterval(3)
        while Date() < catalogDeadline && viewModel.availableWineVersions.isEmpty {
            try await Task.sleep(for: .milliseconds(25))
        }
        guard let version = viewModel.availableWineVersions.first else {
            return XCTFail("Settings did not project the verified Wine catalog")
        }

        await viewModel.downloadWineVersion(version)
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
    func testSettingsReflectsWineDeletionAsDownloadableImmediately() async throws {
        let archive = try makeWineArchive(fillerBytes: 1_000)
        let fixture = try await makeScheduler(networkProvider: makeWineNetwork(archive: archive))
        let viewModel = SettingsViewModel(
            persistenceStore: fixture.persistence,
            systemDetector: SystemEnvironmentDetector(),
            wineVersionManager: fixture.wineManager,
            gameRegistry: fixture.registry,
            fileSystemRepository: GameFileSystemRepository(appSupportDirectory: try makeTemporaryDirectory()),
            taskScheduler: fixture.scheduler
        )

        await viewModel.loadSettings()
        let catalogDeadline = Date().addingTimeInterval(3)
        while Date() < catalogDeadline && viewModel.availableWineVersions.isEmpty {
            try await Task.sleep(for: .milliseconds(25))
        }
        guard let version = viewModel.availableWineVersions.first else {
            return XCTFail("Settings did not project the verified Wine catalog")
        }

        await viewModel.downloadWineVersion(version)
        let installDeadline = Date().addingTimeInterval(5)
        while Date() < installDeadline {
            if viewModel.wineDownloadTask?.state == .completed,
               viewModel.availableWineVersions.first(where: { $0.tagName == version.tagName })?.isDownloaded == true {
                break
            }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertTrue(
            viewModel.availableWineVersions.first(where: { $0.tagName == version.tagName })?.isDownloaded == true,
            "Wine download did not project as installed"
        )

        await viewModel.deleteWineVersion(tagName: version.tagName)
        let deleteDeadline = Date().addingTimeInterval(3)
        while Date() < deleteDeadline {
            if viewModel.availableWineVersions.first(where: { $0.tagName == version.tagName })?.isDownloaded == false {
                break
            }
            try await Task.sleep(for: .milliseconds(25))
        }

        XCTAssertFalse(
            viewModel.availableWineVersions.first(where: { $0.tagName == version.tagName })?.isDownloaded ?? true
        )
        XCTAssertFalse(viewModel.installedWineVersions.contains { $0.tagName == version.tagName })
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

    func testBackgroundGroupSelectionPersistsAndFailedSwitchKeepsPreviousGroup() async throws {
        let baseURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: baseURL) }
        let supportURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: supportURL) }
        let customURL = supportURL.appendingPathComponent("custom.png")
        try Data("custom image fixture".utf8).write(to: customURL)

        let store = PersistenceStore(baseURL: baseURL)
        try await store.writeAppData(AppData())
        let fileSystem = GameFileSystemRepository(appSupportDirectory: supportURL)
        let logger = LogWriter(fileSystemRepository: fileSystem)
        let network = try makeMockNetwork(response: Self.backgroundResponseJSON())
        let service = BackgroundMediaService(
            mediaTranscoder: MediaTranscoder(processManager: ProcessManager(), logWriter: logger),
            mediaCacheManager: MediaCacheManager(),
            networkProvider: network,
            persistenceStore: store,
            logWriter: logger
        )
        let gameID = GameType.genshinImpact.rawValue

        await service.setBackgroundMode(for: gameID, mode: .custom, customPath: customURL.path)
        try await service.selectBackgroundGroup(for: gameID, groupID: "bg-2")
        XCTAssertEqual(service.getSelectedBackgroundGroupID(for: gameID), "bg-2")
        let persisted = try await store.readAppData()
        XCTAssertEqual(persisted.backgroundGroupSelections[gameID], "bg-2")
        XCTAssertEqual(persisted.perGameSettings[gameID]?.selectedBackgroundGroupID, "bg-2")

        do {
            try await service.selectBackgroundGroup(for: gameID, groupID: "missing")
            XCTFail("Expected unavailable background group")
        } catch let error as BackgroundMediaService.BackgroundError {
            guard case .unavailable = error else {
                return XCTFail("Unexpected background error: \(error)")
            }
        }
        XCTAssertEqual(service.getSelectedBackgroundGroupID(for: gameID), "bg-2")
    }

}
