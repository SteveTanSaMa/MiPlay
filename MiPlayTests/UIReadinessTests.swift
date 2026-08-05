// Source: Implementation maintenance split -> UI state and accessibility contracts
import XCTest
@testable import MiPlay

@MainActor extension MiPlayCoreTests {
    func testPrimaryButtonAndSettingsAccessibilityContractsAreStable() {
        let enabled = LibraryViewModel.PrimaryButtonState.enabled(label: "启动", action: .launch)
        XCTAssertTrue(enabled.isEnabled)
        XCTAssertEqual(enabled.label, "启动")
        if case .launch = enabled.action {
            // Expected action mapping.
        } else {
            XCTFail("Expected launch action")
        }

        let disabled = LibraryViewModel.PrimaryButtonState.disabled("启动中…")
        XCTAssertFalse(disabled.isEnabled)
        XCTAssertEqual(disabled.label, "启动中…")
        XCTAssertNil(disabled.action)

        XCTAssertEqual(SettingsSidebarItem.allCases.count, 6)
        for item in SettingsSidebarItem.allCases {
            XCTAssertFalse(item.rawValue.isEmpty)
            XCTAssertFalse(item.icon.isEmpty)
        }
        XCTAssertEqual(SettingsSidebarItem.gameGenshin.gameType, .genshinImpact)
        XCTAssertEqual(SettingsSidebarItem.gameStarRail.gameType, .honkaiStarRail)
        XCTAssertEqual(SettingsSidebarItem.gameZZZ.gameType, .zenlessZoneZero)
    }

    func testWineReadinessRequiresGameSpecificPrefixBeforeWineReady() async throws {
        let appSupport = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: appSupport) }
        let fileSystem = GameFileSystemRepository(appSupportDirectory: appSupport)
        let persistence = PersistenceStore(baseURL: try makeTemporaryDirectory())
        let process = ProcessManager()
        let logger = LogWriter(fileSystemRepository: fileSystem)
        let runtimeRoot = appSupport
            .appendingPathComponent("WineVersions/wine-devel-9.0/bin", isDirectory: true)
        try FileManager.default.createDirectory(at: runtimeRoot, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: runtimeRoot.appendingPathComponent("wine"),
            withDestinationURL: URL(fileURLWithPath: "/bin/sh")
        )
        try await persistence.writeAppData(AppData(
            selectedWineVersion: "wine-devel-9.0",
            installedWineVersions: ["wine-devel-9.0"]
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
            return XCTFail("Settings readiness must not report WineReady without a game prefix")
        }
        let gameID = GameType.genshinImpact.rawValue
        guard case .prefixNotReady(gameID: gameID) = await manager.checkReadiness(for: gameID) else {
            return XCTFail("Missing game prefix should remain a readiness failure")
        }

        let prefix = appSupport.appendingPathComponent("WinePrefixes/\(gameID)/drive_c", isDirectory: true)
        try FileManager.default.createDirectory(at: prefix, withIntermediateDirectories: true)
        guard case .ready = await manager.checkReadiness(for: gameID) else {
            return XCTFail("A verified game prefix should complete WineReady")
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

}
