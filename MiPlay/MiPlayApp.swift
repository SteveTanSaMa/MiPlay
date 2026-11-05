//
//  MiPlayApp.swift
//  MiPlay
//
//  Created by Steve Tan on 2026/7/7.
//

import SwiftUI

/// Set only by the shared scheme's Test action. XCTest loads this application
/// as its host, but individual tests construct and initialize their own fixtures.
enum UnitTestHost {
    static func isEnabled(environment: [String: String] = ProcessInfo.processInfo.environment) -> Bool {
        environment["MIPLAY_UNIT_TEST_HOST"] == "1"
    }
}

// Source: Architecture Design → 分层架构
// Source: UI Design → Screen Inventory → 主界面/设置窗口

/// MiPlay 应用入口
// Source: UI-9 — 窗口固定不可缩放
// Source: 用户反馈 — 设置窗口关闭 + 位置突变
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// 主窗口与设置窗口引用（设置窗口由 Settings 场景在建立后注册）。
    private weak var mainWindow: NSWindow?
    private weak var settingsWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let mainWindow = NSApp.windows.first(where: { !($0 is NSPanel) }) else { return }
        registerMainWindow(mainWindow)
    }

    /// 由主窗口视图注册，监听焦点通知，避免覆盖 SwiftUI 的窗口委托。
    func registerMainWindow(_ window: NSWindow) {
        NotificationCenter.default.removeObserver(self, name: NSWindow.didBecomeKeyNotification, object: nil)
        mainWindow = window
        window.minSize = NSSize(width: 1280, height: 688)
        window.maxSize = NSSize(width: 1280, height: 688)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(windowDidBecomeKey(_:)),
            name: NSWindow.didBecomeKeyNotification,
            object: window
        )
    }

    /// 设置窗口建立后注册自己。
    func registerSettingsWindow(_ window: NSWindow) {
        if let settingsWindow {
            NotificationCenter.default.removeObserver(
                self, name: NSWindow.didBecomeMainNotification, object: settingsWindow
            )
        }
        settingsWindow = window
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(settingsWindowDidBecomeMain(_:)),
            name: NSWindow.didBecomeMainNotification,
            object: window
        )
        if window.isMainWindow {
            preserveMainWindowAppearance()
        }
    }

    @objc private func settingsWindowDidBecomeMain(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === settingsWindow else { return }
        preserveMainWindowAppearance()
    }

    /// key 决定键盘输入，main 决定主窗口的活动外观；设置只接管 key。
    /// makeMain 不转移键盘焦点，因此设置仍可正常输入，主窗口的 Liquid Glass 也保留。
    private func preserveMainWindowAppearance() {
        // 等 AppKit 完成本次 main/key 切换，避免在 didBecomeMain 通知中重入 makeMain。
        DispatchQueue.main.async { [weak self] in
            guard let self, let mainWindow = self.mainWindow,
                  let settingsWindow = self.settingsWindow,
                  mainWindow.isVisible, settingsWindow.isVisible, settingsWindow.isKeyWindow,
                  mainWindow !== settingsWindow else { return }
            mainWindow.makeMain()
        }
    }

    /// 菜单和 ⌘, 共用切换逻辑；关闭后仍可通过 Settings 场景重新打开。
    func toggleSettings(openSettings: () -> Void) {
        if let settingsWindow, settingsWindow.isVisible {
            settingsWindow.close()
        } else {
            openSettings()
        }
    }

    /// 用户指令：设置窗口打开时点击主窗口，不仅要切换焦点，还要关闭设置窗口。
    /// 主窗口成为 key（点击任意位置、从菜单切换等）时关闭设置窗口即可满足；
    /// 其它窗口获得焦点时设置窗口保持打开。
    @objc func windowDidBecomeKey(_ notification: Notification) {
        guard let focused = notification.object as? NSWindow, focused === mainWindow else { return }
        settingsWindow?.close()
    }
}

@main
struct MiPlayApp: App {
    // Source: UI-9 — 窗口固定不可缩放
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    // MARK: - ViewModels

    let libraryViewModel: LibraryViewModel
    let settingsViewModel: SettingsViewModel
    let newsProvider: HoYoPlayNewsProvider
    let newsImageCache: NewsBannerImageCache
    private let isUnitTestHost: Bool

    init() {
        let isUnitTestHost = UnitTestHost.isEnabled()
        self.isUnitTestHost = isUnitTestHost
        // Defense in depth: even if a test explicitly opens another scene, its
        // app-owned repositories must never point at the user's real data.
        let testRoot = isUnitTestHost
            ? FileManager.default.temporaryDirectory.appendingPathComponent("MiPlayTestHost-\(UUID().uuidString)", isDirectory: true)
            : nil
        // 基础设施层初始化
        let fileSystem = GameFileSystemRepository(appSupportDirectory: testRoot)
        let network = NetworkDownloadProvider()
        let system = SystemEnvironmentDetector()
        let log = LogWriter(fileSystemRepository: fileSystem)
        self.newsProvider = HoYoPlayNewsProvider(network: network, logger: log)
        self.newsImageCache = NewsBannerImageCache(network: network)
        let persistence = PersistenceStore(baseURL: testRoot, logWriter: log)
        let process = ProcessManager(logWriter: log)
        let wine = WineRuntimeProvider(
            processManager: process,
            fileSystemRepository: fileSystem,
            logWriter: log,
            // Wine "Mac Driver"（Retina / 左 Command）设置来自 AppData
            persistenceStore: persistence
        )
        let wineDownloader = WineVersionDownloader(
            networkProvider: network,
            fileSystemRepository: fileSystem,
            processManager: process,
            logWriter: log
        )

        // 领域层初始化
        let stateMachine = GameStateMachine()
        let performance = PerformanceOptionManager(
            persistenceStore: persistence,
            logWriter: log
        )
        let wineVersionMgr = WineVersionManager(
            networkProvider: network,
            fileSystemRepository: fileSystem,
            persistenceStore: persistence,
            wineVersionDownloader: wineDownloader,
            logWriter: log,
            wineRuntimeProvider: wine
        )
        let registry = GameRegistry(
            persistenceStore: persistence,
            fileSystemRepository: fileSystem,
            stateMachine: stateMachine,
            systemDetector: system,
            logWriter: log
        )
        let verifier = FileIntegrityVerifier(
            fileSystemRepository: fileSystem,
            gameRegistry: registry,
            logWriter: log
        )
        let preLaunch = PreLaunchValidator(
            fileSystemRepository: fileSystem,
            systemDetector: system,
            wineRuntimeProvider: wine,
            wineVersionManager: wineVersionMgr,
            integrityVerifier: verifier,
            gameRegistry: registry,
            logWriter: log
        )
        let launch = LaunchOrchestrator(
            preLaunchValidator: preLaunch,
            wineRuntimeProvider: wine,
            wineVersionManager: wineVersionMgr,
            processManager: process,
            performanceOptionManager: performance,
            gameRegistry: registry,
            fileSystemRepository: fileSystem,
            logWriter: log
        )
        let solution = SolutionEngine(
            fileSystemRepository: fileSystem,
            processManager: process,
            systemDetector: system,
            logWriter: log
        )
        let version = VersionChecker(
            fileSystemRepository: fileSystem,
            networkProvider: network,
            logWriter: log,
            remoteManifestURL: VersionChecker.defaultRemoteManifestURL,
            gameRegistry: registry
        )
        let mediaTranscoder = MediaTranscoder(
            processManager: process,
            logWriter: log
        )
        let gameIconProvider = GameIconProvider(
            networkProvider: network,
            processManager: process,
            fileSystemRepository: fileSystem,
            logWriter: log
        )
        let mediaCache = MediaCacheManager(baseURL: testRoot)
        let backgroundMedia = BackgroundMediaService(
            mediaTranscoder: mediaTranscoder,
            mediaCacheManager: mediaCache,
            networkProvider: network,
            persistenceStore: persistence,
            logWriter: log
        )
        let scheduler = TaskScheduler(
            launchOrchestrator: launch,
            solutionEngine: solution,
            gameRegistry: registry,
            integrityVerifier: verifier,
            versionChecker: version,
            persistenceStore: persistence,
            logWriter: log,
            wineVersionManager: wineVersionMgr,
            backgroundMediaService: backgroundMedia
        )

        // ViewModel 层初始化
        self.libraryViewModel = LibraryViewModel(
            gameRegistry: registry,
            launchOrchestrator: launch,
            backgroundMediaService: backgroundMedia,
            persistenceStore: persistence,
            taskScheduler: scheduler,
            logWriter: log,
            // 启动准备第一阶段（Wine 运行时 + 共享 prefix）由主界面视图模型驱动
            wineVersionManager: wineVersionMgr,
            // 官方游戏图标（侧栏显示 + 游戏 .app 打包）由视图模型在启动准备时补齐
            gameIconProvider: gameIconProvider,
            predownloadLookup: { try await SophonMetadataClient().fetchPreDownloadVersion(for: $0) }
        )
        self.settingsViewModel = SettingsViewModel(
            systemDetector: system,
            wineVersionManager: wineVersionMgr,
            gameRegistry: registry,
            fileSystemRepository: fileSystem,
            taskScheduler: scheduler,
            performanceOptionManager: performance,
            backgroundMediaService: backgroundMedia
        )

        // Source: QA Report → F-007 — 初始化 Wine 版本管理器
        if !isUnitTestHost {
            Task {
                await log.record(.init(
                    level: .info,
                    module: "App",
                    eventName: "app.dependencies.initialized",
                    phase: "initialized",
                    result: "completed",
                    messageCode: "app.dependencies.initialized"
                ))
                await wineVersionMgr.initialize()
                await scheduler.initialize()

                // Wine 与素材的并行启动准备由 LibraryViewModel 统一驱动。
                // 这里只保留管理器初始化，让设置窗口能尽早读到状态。
            }
        }
    }

    var body: some Scene {
        // Source: ADR 020 — 主窗口简化，设置移入独立窗口
        MainWindowScene(
            libraryViewModel: libraryViewModel,
            newsProvider: newsProvider,
            newsImageCache: newsImageCache,
            isUnitTestHost: isUnitTestHost,
            registerWindow: appDelegate.registerMainWindow
        )
        .commands {
            SettingsCommands(appDelegate: appDelegate)
        }

        // Source: ADR 020 — 设置独立窗口，⌘, 由 SettingsCommands 切换打开/关闭。
        Settings {
            SettingsWindowScene(
                settingsViewModel: settingsViewModel,
                registerWindow: appDelegate.registerSettingsWindow
            )
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
    }
}

private struct SettingsCommands: Commands {
    let appDelegate: AppDelegate
    @Environment(\.openSettings) private var openSettings

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("设置…") {
                appDelegate.toggleSettings { openSettings() }
            }
            .keyboardShortcut(",", modifiers: .command)
        }
    }
}

/// 在视图实际附着到窗口时注册，通过回调直接使用应用持有的 AppDelegate。
struct WindowRegistrar: NSViewRepresentable {
    let registerWindow: (NSWindow) -> Void

    func makeNSView(context: Context) -> RegistrarView {
        RegistrarView(registerWindow: registerWindow)
    }

    func updateNSView(_ nsView: RegistrarView, context: Context) {
        nsView.registerWindow = registerWindow
    }

    final class RegistrarView: NSView {
        var registerWindow: (NSWindow) -> Void

        init(registerWindow: @escaping (NSWindow) -> Void) {
            self.registerWindow = registerWindow
            super.init(frame: .zero)
        }

        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            guard let window else { return }
            registerWindow(window)
        }
    }
}
