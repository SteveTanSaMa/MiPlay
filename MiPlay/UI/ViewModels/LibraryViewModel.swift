//
//  LibraryViewModel.swift
//  MiPlay
//
//  Created by Steve Tan on 2026/7/7.
//

import SwiftUI

// Source: Architecture Design → ViewModel Layer → LibraryViewModel
// Review Issue: P1-007 — TaskScheduler 集成到启动/安装流程

/// 主界面视图模型。管理游戏列表、选中游戏、主按钮状态。
@MainActor
@Observable
public final class LibraryViewModel {
    // MARK: - Published State
    /// 所有游戏列表
    private(set) var games: [Game] = []
    /// 当前选中游戏的 ID（nil 表示库为空，由 UI 层处理占位选中）
    private(set) var selectedGameId: String?
    /// 是否正在加载
    internal var isLoading = true
    /// 错误信息
    private(set) var errorMessage: String?
    /// 启动进度
    private(set) var launchProgress: LaunchProgress?
    /// 游戏库是否已初始化
    private(set) var isInitialized = false
    private(set) var activeTaskId: ScheduledTaskID?
    private(set) var recoveryRecords: [RecoveryRecord] = []
    private(set) var recoveryRequired: String?

    // MARK: - Computed Properties

    /// 当前选中游戏
    public var selectedGame: Game? {
        guard let id = selectedGameId else { return nil }
        return games.first { $0.id == id }
    }

    /// 主按钮状态
    public var primaryButtonState: PrimaryButtonState {
        guard let game = selectedGame else { return .disabled("请选择游戏") }
        if recoveryRecords.contains(where: { $0.gameID == game.id && $0.resolvedAt == nil }) {
            return .disabled("需要恢复")
        }

        switch game.state {
        case .notInstalled:
            return .enabled(label: "定位游戏", action: .locate)
        case .installed:
            return .enabled(label: "启动", action: .launch)
        case .updateAvailable:
            return .enabled(label: "更新", action: .update)
        case .launchFailed:
            return .enabled(label: "查看修复方案", action: .viewFix)
        case .gameUpdating:
            return .disabled("更新中…")
        case .launching:
            return .disabled("启动中…")
        case .running:
            return .disabled("正在运行")
        }
    }

    /// 背景素材状态（由 BackgroundMediaService 提供）
    internal var backgroundMediaState: BackgroundMediaService.MediaState = .notLoaded
    /// Theme 装饰图本地路径
    private(set) var backgroundThemePath: String?
    /// 三款游戏的视频路径字典
    private(set) var videoPaths: [GameType: String] = [:]
    /// 三款游戏的图片路径字典
    private(set) var imagePaths: [GameType: String] = [:]
    /// 三款游戏的完整媒体数据字典
    private(set) var backgroundMedia: [GameType: BackgroundMedia] = [:]
    /// Available background groups for the selected Game ID.
    private(set) var backgroundGroups: [BackgroundMediaService.BackgroundGroup] = []
    private(set) var selectedBackgroundGroupID: String?
    private(set) var backgroundGroupError: String?

    // MARK: - Dependencies

    private let gameRegistry: GameRegistry
    private let launchOrchestrator: LaunchOrchestrator
    private let backgroundMediaService: BackgroundMediaService?
    private let persistenceStore: PersistenceStore
    private let taskScheduler: TaskScheduler
    private let logWriter: LogWriter
    private var taskObservation: Task<Void, Never>?
    private var progressObservation: Task<Void, Never>?
    private var lastTaskEventSequence: UInt64 = 0
    private var selectionGeneration: UInt64 = 0
    private var selectionMediaTask: Task<Void, Never>?
    private var selectionPersistenceTask: Task<Void, Never>?

    public init(
        gameRegistry: GameRegistry,
        launchOrchestrator: LaunchOrchestrator,
        backgroundMediaService: BackgroundMediaService? = nil,
        persistenceStore: PersistenceStore,
        taskScheduler: TaskScheduler,
        logWriter: LogWriter
    ) {
        self.gameRegistry = gameRegistry
        self.launchOrchestrator = launchOrchestrator
        self.backgroundMediaService = backgroundMediaService
        self.persistenceStore = persistenceStore
        self.taskScheduler = taskScheduler
        self.logWriter = logWriter
    }

    // MARK: - Initialization

    /// 初始化视图模型
    public func initialize() async {
        isLoading = true

        // A recovery error must not be replaced with a default user setting.
        do {
            let appData = try await persistenceStore.readAppData()
            selectedGameId = appData.lastSelectedGame ?? GameType.genshinImpact.rawValue
        } catch {
            selectedGameId = nil
            errorMessage = error.localizedDescription
        }
        backgroundMediaState = .loading

        await gameRegistry.initialize()
        await taskScheduler.initialize()
        await startTaskObservation()
        await refreshGames()
        await refreshRecoveryRecords()

        // 预加载全部 3 款游戏的背景素材
        if let mediaService = backgroundMediaService {
            for gameType in GameType.allCases {
                await mediaService.loadMedia(for: gameType.rawValue)
            }
            // 加载完成后刷新当前选中游戏的素材状态
            if let sid = selectedGameId {
                backgroundMediaState = mediaService.getMediaState(for: sid)
                backgroundThemePath = mediaService.getThemeImagePath(for: sid)
                refreshMediaPaths()
                await loadBackgroundGroups(for: sid)
            }
        }

        isLoading = false
        isInitialized = true

        // 确保选中在有效游戏上
        if let sid = selectedGameId, !games.contains(where: { $0.id == sid }) {
            selectedGameId = games.first?.id
        }
    }

    /// 刷新游戏列表
    public func refreshGames() async {
        games = await gameRegistry.getAllGames()
        await refreshRecoveryRecords()

        // Validate selected game still exists
        if let selectedId = selectedGameId {
            if !games.contains(where: { $0.id == selectedId }) {
                // 选中游戏已被移除，自动选中列表中的第一款
                selectedGameId = games.first?.id
            }
        }
    }

    // MARK: - Game Selection

    /// 选择游戏（切换背景素材展示，已预加载的素材直接从缓存读取，持久化选中状态）
    public func selectGame(id: String) {
        selectionGeneration &+= 1
        let generation = selectionGeneration
        selectionMediaTask?.cancel()
        selectionPersistenceTask?.cancel()
        selectedGameId = id
        let persistenceStore = self.persistenceStore
        selectionPersistenceTask = Task { [weak self, persistenceStore] in
            do {
                var appData = try await persistenceStore.readAppData()
                appData.lastSelectedGame = id
                try await persistenceStore.writeAppData(appData)
                guard let self, self.selectionGeneration == generation else { return }
            } catch {
                guard let self, self.selectionGeneration == generation else { return }
                self.errorMessage = error.localizedDescription
            }
        }
        if let mediaService = backgroundMediaService {
            // 如果尚未加载过则触发加载，否则直接读取缓存状态
            let currentState = mediaService.getMediaState(for: id)
            if case .notLoaded = currentState {
                selectionMediaTask = Task { [weak self] in
                    guard let self else { return }
                    await mediaService.loadMedia(for: id)
                    guard !Task.isCancelled, self.selectionGeneration == generation, self.selectedGameId == id else { return }
                    backgroundMediaState = mediaService.getMediaState(for: id)
                    backgroundThemePath = mediaService.getThemeImagePath(for: id)
                    refreshMediaPaths()
                    await loadBackgroundGroups(for: id)
                }
            } else {
                backgroundMediaState = currentState
                backgroundThemePath = mediaService.getThemeImagePath(for: id)
                refreshMediaPaths()
                selectionMediaTask = Task { [weak self] in
                    guard let self else { return }
                    guard !Task.isCancelled, self.selectionGeneration == generation, self.selectedGameId == id else { return }
                    await loadBackgroundGroups(for: id)
                }
            }
        }
    }

    /// 刷新背景素材状态
    public func refreshBackgroundMedia() async {
        guard let gameId = selectedGameId, let mediaService = backgroundMediaService else { return }
        backgroundMediaState = mediaService.getMediaState(for: gameId)
        backgroundThemePath = mediaService.getThemeImagePath(for: gameId)
        refreshMediaPaths()
        await loadBackgroundGroups(for: gameId)
    }

    public func loadBackgroundGroups(for gameId: String) async {
        guard let mediaService = backgroundMediaService else { return }
        guard selectedGameId == gameId else { return }
        do {
            let groups = try await mediaService.getBackgroundGroups(for: gameId)
            guard selectedGameId == gameId else { return }
            backgroundGroups = groups
            selectedBackgroundGroupID = mediaService.getSelectedBackgroundGroupID(for: gameId)
            backgroundGroupError = nil
        } catch {
            guard selectedGameId == gameId else { return }
            backgroundGroups = []
            selectedBackgroundGroupID = mediaService.getSelectedBackgroundGroupID(for: gameId)
            backgroundGroupError = error.localizedDescription
        }
    }

    public func selectBackgroundGroup(id groupID: String) async {
        guard let gameID = selectedGameId, let mediaService = backgroundMediaService else { return }
        do {
            try await mediaService.selectBackgroundGroup(for: gameID, groupID: groupID)
            selectedBackgroundGroupID = mediaService.getSelectedBackgroundGroupID(for: gameID)
            backgroundMediaState = mediaService.getMediaState(for: gameID)
            backgroundThemePath = mediaService.getThemeImagePath(for: gameID)
            refreshMediaPaths()
            await loadBackgroundGroups(for: gameID)
        } catch {
            selectedBackgroundGroupID = mediaService.getSelectedBackgroundGroupID(for: gameID)
            backgroundGroupError = error.localizedDescription
        }
    }

    /// 刷新三款游戏的路径字典 + 完整媒体数据
    private func refreshMediaPaths() {
        guard let service = backgroundMediaService else { return }
        var videos: [GameType: String] = [:]
        var images: [GameType: String] = [:]
        var media: [GameType: BackgroundMedia] = [:]
        for type in GameType.allCases {
            let state = service.getMediaState(for: type.rawValue)
            let themePath = service.getThemeImagePath(for: type.rawValue)
            if case .ready(let path, let isVideo) = state {
                if isVideo {
                    videos[type] = path
                    media[type] = BackgroundMedia(imagePath: path, videoPath: path, themePath: themePath)
                } else {
                    images[type] = path
                    media[type] = BackgroundMedia(imagePath: path, themePath: themePath)
                }
            }
        }
        videoPaths = videos
        imagePaths = images
        backgroundMedia = media
    }

    /// 悬停预加载背景素材（仅在 notLoaded 状态触发）
    public func preloadMedia(for gameId: String) async {
        guard let mediaService = backgroundMediaService else { return }
        if case .notLoaded = mediaService.getMediaState(for: gameId) {
            await mediaService.loadMedia(for: gameId)
        }
    }

    /// 为占位游戏类型加载背景素材（库中无此游戏时使用）
    public func loadMediaForPlaceholder(type: GameType) async {
        guard let mediaService = backgroundMediaService else { return }
        let gameId = type.rawValue
        await mediaService.loadMedia(for: gameId)
        backgroundMediaState = mediaService.getMediaState(for: gameId)
        backgroundThemePath = mediaService.getThemeImagePath(for: gameId)
        refreshMediaPaths()
        await loadBackgroundGroups(for: gameId)
    }


    // MARK: - Actions

    /// 处理主按钮操作
    public func performPrimaryAction() async {
        guard let game = selectedGame else { return }
        guard case .enabled(_, let action) = primaryButtonState else { return }

        switch action {
        case .locate:
            // View 层已通过 onPrimaryAction 闭包直接调用 locateGame(type:)
            break
        case .launch:
            // Review Issue: P1-007 — 启动请求通过 TaskScheduler 提交
            await launchGame(game: game)
        case .update:
            errorMessage = "完整游戏更新未在当前版本发布"
            break
        case .viewFix:
            // 触发查看修复方案 - 通过 openWindow 打开详情窗口
            break
        }
    }

    /// 启动游戏 — P1-007: 通过 TaskScheduler.enqueue(.gameLaunch) 提交
    public func launchGame(game: Game) async {
        launchProgress = LaunchProgress(phase: "已提交，等待执行", progress: nil)

        do {
            activeTaskId = try await taskScheduler.enqueue(type: .gameLaunch, gameId: game.id)
        } catch {
            errorMessage = error.localizedDescription
            await refreshGames()
        }
    }

    /// 定位游戏：选择 exe 路径后更新或添加游戏
    public func locateGame(type: GameType, path: String) async {
        if let game = games.first(where: { $0.type == type }) {
            do {
                try await gameRegistry.updateGamePath(id: game.id, newPath: path)
                await refreshGames()
                selectGame(id: game.id)
            } catch {
                errorMessage = error.localizedDescription
            }
        } else {
            await addGame(type: type, path: path)
        }
    }

    /// Receives the URL selected by NSOpenPanel so Domain can create a scoped bookmark.
    public func locateGame(type: GameType, selectedURL: URL) async {
        do {
            _ = try await gameRegistry.locateGame(type: type, selectedURL: selectedURL)
            await refreshGames()
            if let game = games.first(where: { $0.type == type }) { selectGame(id: game.id) }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 添加游戏
    public func addGame(type: GameType, path: String?) async {
        do {
            let game = try await gameRegistry.addGame(type: type, installPath: path)
            await refreshGames()

            // 如果提供了路径但游戏状态为未安装，说明路径验证未通过
            if let path = path, !path.isEmpty, game.state == .notInstalled {
                let validationResult = await gameRegistry.validateGamePath(gameType: type, path: path)
                if case .executableNotFound(let execPath) = validationResult {
                    errorMessage = "未找到游戏文件：在所选目录中未找到 \(URL(fileURLWithPath: execPath).lastPathComponent)。请确认选择了正确的游戏安装目录。"
                } else if case .pathNotAccessible = validationResult {
                    errorMessage = "无法访问所选目录，请检查路径是否有效"
                }
            }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 移除游戏
    public func removeGame(id: String) async {
        do {
            try await gameRegistry.removeGame(id: id)
            await refreshGames()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 清除错误信息
    public func clearError() {
        errorMessage = nil
    }

    public func retryProcessExitRecovery(recordID: String) async {
        do {
            try await launchOrchestrator.retryProcessExitRecovery(recordID: recordID)
            recoveryRequired = nil
            await refreshGames()
        } catch {
            recoveryRequired = error.localizedDescription
            errorMessage = recoveryRequired
        }
    }

    private func startTaskObservation() async {
        taskObservation?.cancel()
        progressObservation?.cancel()
        lastTaskEventSequence = 0
        let eventStream = await taskScheduler.makeEventStream()
        let progressStream = await taskScheduler.makeProgressStream()
        taskObservation = Task { [weak self] in
            for await event in eventStream {
                guard !Task.isCancelled else { return }
                await self?.consume(event)
            }
        }
        progressObservation = Task { [weak self] in
            for await progress in progressStream {
                guard !Task.isCancelled else { return }
                await self?.consume(progress)
            }
        }
    }

    /// Progress is consumed from the scheduler's progress stream. The task
    /// snapshot supplies the type and game projection because progress events
    /// intentionally carry no UI-specific ownership fields.
    private func consume(_ progress: TaskProgress) async {
        guard let task = try? await taskScheduler.taskSnapshot(id: progress.taskId),
              task.type == .gameLaunch,
              task.gameId == selectedGameId || task.id == activeTaskId else { return }
        guard task.state == .pending || task.state == .running else {
            await project(task)
            return
        }
        activeTaskId = task.id
        launchProgress = LaunchProgress(phase: progress.phase, progress: progress.progress)
    }

    private func consume(_ event: TaskEvent) async {
        guard event.snapshot.type == .gameLaunch else { return }
        guard event.snapshot.gameId == selectedGameId || event.snapshot.id == activeTaskId else { return }
        if lastTaskEventSequence != 0, event.sequence > lastTaskEventSequence + 1 {
            // A dropped event is repaired from the scheduler-owned snapshot.
            if let snapshot = try? await taskScheduler.taskSnapshot(id: event.snapshot.id) {
                await project(snapshot)
            }
        }
        lastTaskEventSequence = max(lastTaskEventSequence, event.sequence)
        await project(event.snapshot)
    }

    private func project(_ snapshot: ScheduledTask) async {
        guard snapshot.type == .gameLaunch else { return }
        guard snapshot.gameId == selectedGameId || snapshot.id == activeTaskId else { return }
        activeTaskId = snapshot.id
        launchProgress = LaunchProgress(
            phase: snapshot.phaseDescription,
            progress: snapshot.progress
        )
        switch snapshot.state {
        case .failed:
            errorMessage = snapshot.error ?? "启动未完成"
            recoveryRequired = snapshot.recovery
            launchProgress = nil
            await refreshGames()
        case .completed:
            guard snapshot.outcome != nil else {
                errorMessage = "任务已结束，但结果无法确认"
                launchProgress = nil
                return
            }
            launchProgress = nil
            await refreshGames()
        case .cancelled:
            guard snapshot.outcome == "cleanupVerified" else {
                errorMessage = snapshot.error ?? "取消清理未确认"
                launchProgress = nil
                return
            }
            launchProgress = nil
            await refreshGames()
        case .pending, .running:
            break
        }
    }

    private func refreshRecoveryRecords() async {
        recoveryRecords = await gameRegistry.pendingRecoveryRecords(gameID: selectedGameId)
        recoveryRequired = recoveryRecords.first?.detail
    }
}
