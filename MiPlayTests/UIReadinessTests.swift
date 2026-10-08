// Source: Implementation maintenance split -> UI state and accessibility contracts
import XCTest
@testable import MiPlay

@MainActor extension MiPlayCoreTests {
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

        XCTAssertEqual(SettingsSidebarItem.allCases.count, 6)
        for item in SettingsSidebarItem.allCases {
            XCTAssertFalse(item.rawValue.isEmpty)
            XCTAssertFalse(item.icon.isEmpty)
        }
        XCTAssertEqual(SettingsSidebarItem.gameGenshin.gameType, .genshinImpact)
        XCTAssertEqual(SettingsSidebarItem.gameStarRail.gameType, .honkaiStarRail)
        XCTAssertEqual(SettingsSidebarItem.gameZZZ.gameType, .zenlessZoneZero)
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
