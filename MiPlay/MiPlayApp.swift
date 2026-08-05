//
//  MiPlayApp.swift
//  MiPlay
//
//  Created by Steve Tan on 2026/7/7.
//

import SwiftUI

// Source: Architecture Design → 分层架构
// Source: UI Design → Screen Inventory → 主界面/设置窗口/游戏安装窗口/游戏详情窗口

/// MiPlay 应用入口
// Source: UI-9 — 窗口固定不可缩放
// Source: 用户反馈 — 设置窗口关闭 + 位置突变
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let mainWindow = NSApp.windows.first(where: { !($0 is NSPanel) }) else { return }
        mainWindow.delegate = self
        mainWindow.minSize = NSSize(width: 1280, height: 688)
        mainWindow.maxSize = NSSize(width: 1280, height: 688)
    }

}

@main
struct MiPlayApp: App {
    // Source: UI-9 — 窗口固定不可缩放
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    // MARK: - Dependencies

    /// 基础设施层
    let persistenceStore: PersistenceStore
    let fileSystemRepository: GameFileSystemRepository
    let processManager: ProcessManager
    let networkProvider: NetworkDownloadProvider
    let wineRuntimeProvider: WineRuntimeProvider
    let wineVersionDownloader: WineVersionDownloader
    let systemDetector: SystemEnvironmentDetector
    let logWriter: LogWriter

    /// 领域层
    let stateMachine: GameStateMachine
    let gameRegistry: GameRegistry
    let launchOrchestrator: LaunchOrchestrator
    let preLaunchValidator: PreLaunchValidator
    let solutionEngine: SolutionEngine
    let performanceOptionManager: PerformanceOptionManager
    let integrityVerifier: FileIntegrityVerifier
    let versionChecker: VersionChecker
    let wineVersionManager: WineVersionManager
    let taskScheduler: TaskScheduler

    /// 视图模型层
    let libraryViewModel: LibraryViewModel
    let settingsViewModel: SettingsViewModel

    init() {
        // 基础设施层初始化
        let fileSystem = GameFileSystemRepository()
        let network = NetworkDownloadProvider()
        let system = SystemEnvironmentDetector()
        let log = LogWriter(fileSystemRepository: fileSystem)
        let persistence = PersistenceStore(logWriter: log)
        let process = ProcessManager(logWriter: log)
        let wine = WineRuntimeProvider(
            processManager: process,
            fileSystemRepository: fileSystem,
            logWriter: log
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
            gameRegistry: registry
        )
        let scheduler = TaskScheduler(
            launchOrchestrator: launch,
            solutionEngine: solution,
            gameRegistry: registry,
            integrityVerifier: verifier,
            versionChecker: version,
            persistenceStore: persistence,
            logWriter: log,
            wineVersionManager: wineVersionMgr
        )

        // 存储引用
        self.persistenceStore = persistence
        self.fileSystemRepository = fileSystem
        self.processManager = process
        self.networkProvider = network
        self.wineRuntimeProvider = wine
        self.wineVersionDownloader = wineDownloader
        self.systemDetector = system
        self.logWriter = log
        self.stateMachine = stateMachine
        self.gameRegistry = registry
        self.launchOrchestrator = launch
        self.preLaunchValidator = preLaunch
        self.solutionEngine = solution
        self.performanceOptionManager = performance
        self.integrityVerifier = verifier
        self.versionChecker = version
        self.wineVersionManager = wineVersionMgr
        self.taskScheduler = scheduler

        // 背景素材服务初始化
        let mediaTranscoder = MediaTranscoder(
            processManager: process,
            logWriter: log
        )
        let mediaCache = MediaCacheManager()
        let backgroundMedia = BackgroundMediaService(
            mediaTranscoder: mediaTranscoder,
            mediaCacheManager: mediaCache,
            networkProvider: network,
            persistenceStore: persistence,
            logWriter: log
        )

        // ViewModel 层初始化
        self.libraryViewModel = LibraryViewModel(
            gameRegistry: registry,
            launchOrchestrator: launch,
            backgroundMediaService: backgroundMedia,
            persistenceStore: persistence,
            taskScheduler: scheduler,
            logWriter: log
        )
        self.settingsViewModel = SettingsViewModel(
            persistenceStore: persistence,
            systemDetector: system,
            wineVersionManager: wineVersionMgr,
            gameRegistry: registry,
            fileSystemRepository: fileSystem,
            taskScheduler: scheduler
        )

        // Source: QA Report → F-007 — 初始化 Wine 版本管理器
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
        }
    }

    var body: some Scene {
        // Source: ADR 020 — 主窗口简化，设置移入独立窗口
        MainWindowScene(libraryViewModel: libraryViewModel)

        // Source: ADR 020 — 设置独立窗口（Settings Scene，自动注册 ⌘, 快捷键）
        Settings {
            SettingsWindowScene(settingsViewModel: settingsViewModel)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)

        // Source: P1-011 — LaunchFailed 修复方案入口
        WindowGroup(id: "game-detail", for: String.self) { $gameId in
            GameDetailWindowView(
                gameRegistry: gameRegistry,
                solutionEngine: solutionEngine,
                performanceOptionManager: performanceOptionManager,
                taskScheduler: taskScheduler,
                initialGameId: gameId ?? libraryViewModel.selectedGameId
            )
        }
        .windowResizability(.contentSize)
    }
}
