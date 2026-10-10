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
    /// 启动准备阶段（Wine 与背景素材并行 → 就绪）。首帧即为 `.preparingWine`，
    /// 全屏遮罩据此覆盖整个准备过程。
    private(set) var startupPhase: StartupPhase = .preparingWine
    /// 全屏遮罩上的说明文字（如「正在准备背景素材…（1/3）」）。
    private(set) var startupDetail: String?
    /// 全屏遮罩的进度（0…1；nil 表示不确定进度）。
    private(set) var startupProgress: Double?
    /// 启动准备失败原因（非 nil 时遮罩展示"重试"入口，且不放行到主页）。
    private(set) var startupFailure: String?
    private(set) var activeTaskId: ScheduledTaskID?
    private(set) var recoveryRecords: [RecoveryRecord] = []
    private(set) var recoveryRequired: String?

    /// 官方游戏图标缓存路径（`GameIcons/<GameType>.icns`）。
    /// 侧栏（`GameSelectionRailView`）与打包的游戏 `.app` 共用同一份缓存。
    private(set) var gameIconURLs: [GameType: URL] = [:]

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
            return .disabled("有可用更新，暂不自动更新")
        case .launchFailed:
            return .enabled(label: "启动", action: .launch)
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

    // MARK: - Dependencies

    private let gameRegistry: GameRegistry
    private let launchOrchestrator: LaunchOrchestrator
    private let backgroundMediaService: BackgroundMediaService?
    private let persistenceStore: PersistenceStore
    private let taskScheduler: TaskScheduler
    private let logWriter: LogWriter
    /// Wine 运行时/共享 prefix 的决策者。启动准备的 Wine 阶段由它驱动；
    /// nil（测试或未接线）时只等待背景素材准备。
    private let wineVersionManager: WineVersionManager?
    /// 官方游戏图标获取（best-effort）。nil（测试或未接线）时跳过图标补齐，
    /// 仍会读取本地已有缓存。
    private let gameIconProvider: GameIconProvider?
    private var taskObservation: Task<Void, Never>?
    private var progressObservation: Task<Void, Never>?
    private var registryObservation: Task<Void, Never>?
    private var lastTaskEventSequence: UInt64 = 0
    private var lastRegistryEventSequence: UInt64 = 0
    private var selectionGeneration: UInt64 = 0
    private var selectionMediaTask: Task<Void, Never>?
    private var selectionPersistenceTask: Task<Void, Never>?
    private var backgroundMediaTaskIDs: [String: ScheduledTaskID] = [:]
    private var versionCheckTaskIDs: [String: ScheduledTaskID] = [:]
    /// 已自动尝试过恢复的记录（每个记录每会话只自动重试一次，失败则保留手动入口）。
    private var autoRecoveryAttemptedRecordIDs: Set<String> = []

    public init(
        gameRegistry: GameRegistry,
        launchOrchestrator: LaunchOrchestrator,
        backgroundMediaService: BackgroundMediaService? = nil,
        persistenceStore: PersistenceStore,
        taskScheduler: TaskScheduler,
        logWriter: LogWriter,
        wineVersionManager: WineVersionManager? = nil,
        gameIconProvider: GameIconProvider? = nil
    ) {
        self.gameRegistry = gameRegistry
        self.launchOrchestrator = launchOrchestrator
        self.backgroundMediaService = backgroundMediaService
        self.persistenceStore = persistenceStore
        self.taskScheduler = taskScheduler
        self.logWriter = logWriter
        self.wineVersionManager = wineVersionManager
        self.gameIconProvider = gameIconProvider
    }

    // MARK: - Startup preparation

    /// Wine 与素材并行准备；Wine 先完成时显示剩余素材进度。
    public enum StartupPhase: Sendable, Equatable {
        case preparingWine
        case preparingMedia
        case ready
    }

    // MARK: - Initialization

    /// 初始化视图模型。背景下载/转码与 Wine 下载/解压/配置重叠，
    /// 全屏遮罩等待 Wine 就绪以及素材任务进入终态。
    public func initialize() async {
        guard !isInitialized else { return }
        isLoading = true
        startupPhase = .preparingWine
        startupDetail = "正在检查 Wine 环境…"
        startupProgress = nil

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
        await startRegistryObservation()
        await startTaskObservation()
        await refreshGames()
        await refreshRecoveryRecords()
        await scheduleAutomaticVersionChecks()
        // 官方图标与启动准备并行（best-effort，不阻塞任何阶段）。
        Task { await refreshGameIcons() }

        // 调度器独立管理素材后台任务，不占 Wine runtime / prefix 的资源锁。
        // 提前提交，让下载与转码覆盖 Wine 下载、解压和配置的等待时间。
        let mediaTaskIDs = await startBackgroundMediaPreparation()
        let wineReady = await prepareWineEnvironment()
        guard wineReady else {
            // Wine 失败时保留遮罩；素材任务继续填充缓存，重试复用进行中的任务。
            isLoading = false
            isInitialized = true
            return
        }

        // Wine 先结束时只等待尚未完成的素材；素材已结束则立即通过。
        startupPhase = .preparingMedia
        await finishBackgroundMediaPreparation(mediaTaskIDs)

        startupPhase = .ready
        startupDetail = nil
        startupProgress = nil
        isLoading = false
        isInitialized = true

        // 确保选中在有效游戏上
        if let sid = selectedGameId, !games.contains(where: { $0.id == sid }) {
            selectedGameId = games.first?.id
        }
    }

    /// 准备界面上的「重试」：并行准备，复用正在运行的素材任务与缓存。
    public func retryStartupPreparation() async {
        guard isInitialized else { return }
        startupFailure = nil
        startupPhase = .preparingWine
        startupDetail = "正在重试…"
        startupProgress = nil

        let mediaTaskIDs = await startBackgroundMediaPreparation()
        guard await prepareWineEnvironment() else { return }

        startupPhase = .preparingMedia
        await finishBackgroundMediaPreparation(mediaTaskIDs)

        startupPhase = .ready
        startupDetail = nil
        startupProgress = nil
    }

    // MARK: - 启动准备阶段

    /// 阶段 1：确保固定 Wine runtime 与共享 prefix 就绪。
    /// 已就绪时立即返回；否则提交（或复用）Wine 环境准备任务并等待其进入终态，
    /// 期间把任务的阶段与进度投影到全屏遮罩。
    /// - Returns: 环境是否可用（false 时调用方应停在准备界面）。
    private func prepareWineEnvironment() async -> Bool {
        guard let wineVersionManager else { return true }
        await wineVersionManager.initialize()

        // 下载已完成但应用被中断：先恢复本地安装，避免网络失败挡住已完整的运行时。
        _ = try? await wineVersionManager.setupExistingManagedRuntimeIfPresent()

        if await wineVersionManager.validatedRuntime() != nil,
           await wineVersionManager.validatedSharedPrefix() != nil {
            return true
        }

        startupDetail = "正在准备 Wine 运行时…"
        do {
            let taskID = try await wineSetupTaskID()
            await waitForTask(taskID) { task in
                self.projectStartupWineProgress(task)
            }
        } catch {
            await logWriter.warning(
                "Wine 环境准备任务无法提交: \(error.localizedDescription)",
                module: "LibraryViewModel"
            )
            startupFailure = "Wine 环境准备任务无法提交：\(error.localizedDescription)"
            startupDetail = startupFailure
            return false
        }

        // 任务终态 + 结果复核：任务报告完成但运行时仍不可用同样算失败。
        guard await wineVersionManager.validatedRuntime() != nil,
              await wineVersionManager.validatedSharedPrefix() != nil else {
            let detail = startupFailure ?? "Wine 运行时或共享 prefix 未就绪"
            startupFailure = detail
            startupDetail = detail
            await logWriter.error("Wine 环境准备失败: \(detail)", module: "LibraryViewModel")
            return false
        }
        return true
    }

    /// 复用进行中的 wine 环境准备任务（例如上次会话中断后由调度器恢复），
    /// 否则提交一个新任务。
    private func wineSetupTaskID() async throws -> ScheduledTaskID {
        let snapshots = await taskScheduler.allTaskSnapshots()
        if let existing = snapshots.first(where: {
            $0.type == .wineRuntimeSetup && ($0.state == .pending || $0.state == .running)
        }) {
            return existing.id
        }
        return try await taskScheduler.enqueueReceipt(type: .wineRuntimeSetup, gameId: nil).taskID
    }

    private func projectStartupWineProgress(_ task: ScheduledTask) {
        switch task.state {
        case .pending, .running:
            startupProgress = task.progress
            startupDetail = task.error ?? task.recovery ?? task.phaseDescription
        case .completed:
            startupProgress = 1
            startupDetail = "Wine 环境已就绪"
        case .failed:
            startupProgress = nil
            let detail = task.error ?? task.recovery ?? "Wine 环境准备失败"
            startupFailure = detail
            startupDetail = detail
        case .cancelled:
            startupProgress = nil
            startupFailure = "Wine 环境准备已取消"
            startupDetail = startupFailure
        }
    }

    /// 只提交后台任务，不等待完成，也不覆盖 Wine 在遮罩上的进度。
    private func startBackgroundMediaPreparation() async -> Set<ScheduledTaskID> {
        guard let mediaService = backgroundMediaService else { return [] }
        await mediaService.loadSettings()
        // 恢复任务可能早于当前 ViewModel 创建，先从调度器事实补齐引用。
        for task in await taskScheduler.allTaskSnapshots()
        where task.type == .backgroundMediaLoad && (task.state == .pending || task.state == .running) {
            if let gameID = task.gameId { backgroundMediaTaskIDs[gameID] = task.id }
        }
        var taskIDs = Set<ScheduledTaskID>()
        for gameType in GameType.allCases {
            await enqueueBackgroundMediaLoad(for: gameType.rawValue)
            if let taskID = backgroundMediaTaskIDs[gameType.rawValue] {
                taskIDs.insert(taskID)
            }
        }
        // 使用本次任务 ID 的独立快照：终态事件会清理字典，但不能丢失等待条件。
        return taskIDs
    }

    private func finishBackgroundMediaPreparation(_ taskIDs: Set<ScheduledTaskID>) async {
        guard let mediaService = backgroundMediaService else { return }
        if !taskIDs.isEmpty {
            await waitForTasks(taskIDs)
        }

        // 全部结束后刷新当前选中游戏的素材状态
        if let sid = selectedGameId {
            backgroundMediaState = mediaService.getMediaState(for: sid)
            backgroundThemePath = mediaService.getThemeImagePath(for: sid)
            refreshMediaPaths()
        }
    }

    /// 轮询单个任务直到进入终态（每 400ms 一次快照），过程中投影进度。
    private func waitForTask(_ taskID: ScheduledTaskID, project: (ScheduledTask) -> Void) async {
        while !Task.isCancelled {
            guard let task = try? await taskScheduler.taskSnapshot(id: taskID) else { return }
            project(task)
            switch task.state {
            case .pending, .running:
                try? await Task.sleep(for: .milliseconds(400))
            case .completed, .failed, .cancelled:
                return
            }
        }
    }

    /// 等待一组后台任务进入终态，按「已完成/总数」更新遮罩进度。
    /// 设 20 分钟上限，避免个别任务卡住时遮罩永不消失（失败/取消同样计入完成）。
    private func waitForTasks(_ taskIDs: Set<ScheduledTaskID>) async {
        let total = taskIDs.count
        guard total > 0 else { return }
        var pending = taskIDs
        let deadline = ContinuousClock.now + .seconds(1200)
        while !pending.isEmpty, ContinuousClock.now < deadline, !Task.isCancelled {
            for taskID in pending {
                guard let task = try? await taskScheduler.taskSnapshot(id: taskID) else {
                    pending.remove(taskID)
                    continue
                }
                switch task.state {
                case .pending, .running:
                    break
                case .completed, .failed, .cancelled:
                    pending.remove(taskID)
                }
            }
            let finished = total - pending.count
            startupProgress = Double(finished) / Double(total)
            startupDetail = "正在准备背景素材…（\(finished)/\(total)）"
            if pending.isEmpty { break }
            try? await Task.sleep(for: .milliseconds(400))
        }
        startupProgress = 1
    }

    /// Runs the opt-in startup version check for already located games. The
    /// scheduler owns deduplication and persistence; this projection only
    /// retains task IDs so repeated state events cannot submit duplicates.
    private func scheduleAutomaticVersionChecks() async {
        guard UserDefaults.standard.object(forKey: "gameUpdateNotificationsEnabled") as? Bool ?? true else {
            return
        }

        for game in games where game.location?.bookmarkData != nil && game.state != .notInstalled {
            if let taskID = versionCheckTaskIDs[game.id],
               let task = try? await taskScheduler.taskSnapshot(id: taskID),
               task.state == .pending || task.state == .running {
                continue
            }
            do {
                let receipt = try await taskScheduler.enqueueReceipt(
                    type: .versionCheck,
                    gameId: game.id
                )
                versionCheckTaskIDs[game.id] = receipt.taskID
            } catch TaskScheduler.SchedulerError.conflict {
                continue
            } catch {
                await logWriter.warning(
                    "启动版本检查未提交（\(game.type.displayName)）: \(error.localizedDescription)",
                    module: "LibraryViewModel"
                )
            }
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
        // Recovery facts are game-scoped: the previous game's records must not
        // keep the new selection's primary action enabled. Refresh before any
        // action can be submitted for the newly selected game.
        Task { [weak self] in
            await self?.refreshRecoveryRecords()
        }
        let persistenceStore = self.persistenceStore
        selectionPersistenceTask = Task { [weak self, persistenceStore] in
            do {
                try await persistenceStore.updateAppData { appData in
                    appData.lastSelectedGame = id
                }
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
                    await enqueueBackgroundMediaLoad(for: id)
                    guard !Task.isCancelled, self.selectionGeneration == generation, self.selectedGameId == id else { return }
                    backgroundMediaState = mediaService.getMediaState(for: id)
                    backgroundThemePath = mediaService.getThemeImagePath(for: id)
                    refreshMediaPaths()
                }
            } else {
                backgroundMediaState = currentState
                backgroundThemePath = mediaService.getThemeImagePath(for: id)
                refreshMediaPaths()
            }
        }
    }

    /// 刷新背景素材状态
    public func refreshBackgroundMedia() async {
        guard let gameId = selectedGameId, let mediaService = backgroundMediaService else { return }
        backgroundMediaState = mediaService.getMediaState(for: gameId)
        backgroundThemePath = mediaService.getThemeImagePath(for: gameId)
        refreshMediaPaths()
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
                    // The still image stays under the video layer so a missing
                    // frame or failed playback never leaves a black background.
                    let stillPath = service.getBackgroundStillImagePath(for: type.rawValue) ?? path
                    media[type] = BackgroundMedia(imagePath: stillPath, videoPath: path, themePath: themePath)
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
            await enqueueBackgroundMediaLoad(for: gameId)
        }
    }

    /// 为占位游戏类型加载背景素材（库中无此游戏时使用）
    public func loadMediaForPlaceholder(type: GameType) async {
        guard let mediaService = backgroundMediaService else { return }
        let gameId = type.rawValue
        await enqueueBackgroundMediaLoad(for: gameId)
        backgroundMediaState = mediaService.getMediaState(for: gameId)
        backgroundThemePath = mediaService.getThemeImagePath(for: gameId)
        refreshMediaPaths()
    }


    // MARK: - Actions

    private func enqueueBackgroundMediaLoad(for gameId: String) async {
        if case .loading = backgroundMediaService?.getMediaState(for: gameId) {
            return
        }
        if let taskID = backgroundMediaTaskIDs[gameId],
           let task = try? await taskScheduler.taskSnapshot(id: taskID),
           task.state == .pending || task.state == .running {
            return
        }
        do {
            let receipt = try await taskScheduler.enqueueReceipt(
                type: .backgroundMediaLoad,
                gameId: gameId
            )
            backgroundMediaTaskIDs[gameId] = receipt.taskID
        } catch {
            // A concurrent caller may have submitted the same media load
            // between the state check and enqueue. The existing task is the
            // authoritative operation and does not need a second UI error.
            if case TaskScheduler.SchedulerError.conflict = error {
                return
            }
            errorMessage = error.localizedDescription
        }
    }

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
            errorMessage = "已检测到新版本，但当前版本不执行游戏文件更新"
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

    /// 定位游戏：选择游戏安装目录后更新或添加游戏
    public func locateGame(type: GameType, path: String) async {
        if let game = games.first(where: { $0.type == type }) {
            do {
                try await gameRegistry.updateGamePath(id: game.id, newPath: path)
                await refreshGames()
                selectGame(id: game.id)
                // 定位后立刻补图标，不必等下次启动。
                Task { await refreshGameIcons() }
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
            // 定位后立刻补图标（区服由安装目录的 config.ini 判定），不必等下次启动。
            Task { await refreshGameIcons() }
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 添加游戏
    public func addGame(type: GameType, path: String?) async {
        do {
            let game = try await gameRegistry.addGame(type: type, installPath: path)
            await refreshGames()
            Task { await refreshGameIcons() }

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

    // MARK: - 官方游戏图标

    /// 纯函数：列出图标缓存里已存在的条目（不触网，可测试）。
    nonisolated static func cachedGameIconURLs(assetRootURL: URL) -> [GameType: URL] {
        var urls: [GameType: URL] = [:]
        for type in GameType.allCases {
            let url = LaunchCompatibilityEnvironment.iconCacheURL(
                for: type,
                assetRootURL: assetRootURL
            )
            if FileManager.default.fileExists(atPath: url.path) {
                urls[type] = url
            }
        }
        return urls
    }

    /// 刷新侧栏图标（只读本地缓存；图标缓存出现后调用即可生效）。
    /// `assetRootURL` 仅用于测试注入，默认取应用数据目录下的运行时资源根。
    public func refreshGameIconURLs(assetRootURL: URL? = nil) {
        gameIconURLs = Self.cachedGameIconURLs(
            assetRootURL: assetRootURL ?? LaunchCompatibilityEnvironment.defaultAssetRootURL()
        )
    }

    /// 补齐官方图标缓存后刷新侧栏。
    /// 三款游戏都准备（未定位时按国服取图，与 `GameIconProvider` 的兜底一致），
    /// 已定位的游戏用其安装路径判定区服。best-effort：失败只留日志，不影响启动。
    public func refreshGameIcons() async {
        for type in GameType.allCases {
            let installPath = games.first { $0.type == type }?.installPath
            await gameIconProvider?.provisionIcon(for: type, installPath: installPath)
        }
        refreshGameIconURLs()
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

    private func startRegistryObservation() async {
        registryObservation?.cancel()
        lastRegistryEventSequence = 0
        let eventStream = await gameRegistry.makeEventStream()
        registryObservation = Task { [weak self] in
            for await event in eventStream {
                guard !Task.isCancelled else { return }
                await self?.consume(event)
            }
        }
    }

    /// Projects committed Game facts, including the asynchronous process-exit
    /// transition that happens after the launch task has completed.
    private func consume(_ event: GameRegistry.RegistryEvent) async {
        guard event.sequence > lastRegistryEventSequence else { return }
        lastRegistryEventSequence = event.sequence
        if let index = games.firstIndex(where: { $0.id == event.game.id }) {
            games[index] = event.game
        } else if isInitialized {
            games.append(event.game)
        }
        if event.game.id == selectedGameId {
            await refreshRecoveryRecords()
        }
    }

    /// Progress is consumed from the scheduler's progress stream. The task
    /// snapshot supplies the type and game projection because progress events
    /// intentionally carry no UI-specific ownership fields.
    private func consume(_ progress: TaskProgress) async {
        guard let task = try? await taskScheduler.taskSnapshot(id: progress.taskId) else { return }
        if task.type == .wineRuntimeSetup {
            // 启动准备第一阶段：进度事件直达遮罩（无需等待 400ms 轮询）。
            guard startupPhase == .preparingWine, startupFailure == nil else { return }
            startupProgress = progress.progress
            if !progress.phase.isEmpty { startupDetail = progress.phase }
            return
        }
        if task.type == .backgroundMediaLoad {
            if task.gameId == selectedGameId {
                backgroundMediaState = backgroundMediaService?.getMediaState(for: task.gameId ?? "") ?? .notLoaded
            }
            return
        }
        guard task.type == .gameLaunch,
              task.gameId == selectedGameId || task.id == activeTaskId else { return }
        guard task.state == .pending || task.state == .running else {
            await project(task)
            return
        }
        activeTaskId = task.id
        launchProgress = LaunchProgress(phase: progress.phase, progress: progress.progress)
    }

    private func consume(_ event: TaskEvent) async {
        if event.snapshot.type == .versionCheck {
            if let gameID = event.snapshot.gameId {
                versionCheckTaskIDs[gameID] = event.snapshot.state == .pending || event.snapshot.state == .running
                    ? event.snapshot.id
                    : nil
            }
            return
        }
        if event.snapshot.type == .backgroundMediaLoad {
            guard let gameID = event.snapshot.gameId else { return }
            backgroundMediaTaskIDs[gameID] = event.snapshot.state == .pending || event.snapshot.state == .running
                ? event.snapshot.id
                : nil
            if event.snapshot.state == .completed || event.snapshot.state == .failed || event.snapshot.state == .cancelled {
                guard let mediaService = backgroundMediaService else { return }
                let state = mediaService.getMediaState(for: gameID)
                if gameID == selectedGameId {
                    backgroundMediaState = state
                    backgroundThemePath = mediaService.getThemeImagePath(for: gameID)
                }
                // The projection covers all three games: a finished load for a
                // non-selected game must materialize as well.
                refreshMediaPaths()
            }
            return
        }
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
        await autoRecoverPendingRecords()
    }

    /// 未完成的进程退出恢复事实由这里自动提交，无需用户点击。
    /// 只处理进程退出类事实（processExit / restartReconciliation）；
    /// 每个记录每会话自动尝试一次，失败则保留记录与手动重试入口。
    private func autoRecoverPendingRecords() async {
        let pending = await gameRegistry.pendingRecoveryRecords(gameID: nil).filter {
            $0.resolvedAt == nil && ($0.kind == "processExit" || $0.kind == "restartReconciliation")
        }
        guard !pending.isEmpty else { return }
        var resolvedAny = false
        for record in pending {
            guard !autoRecoveryAttemptedRecordIDs.contains(record.id) else { continue }
            // 启动进行中先不恢复：共享 prefix lease 与进程守卫属于当前启动，
            // 本次跳过，待启动任务结束后的下一次刷新再提交。
            guard launchProgress == nil else { return }
            autoRecoveryAttemptedRecordIDs.insert(record.id)
            do {
                try await launchOrchestrator.retryProcessExitRecovery(recordID: record.id)
                await logWriter.info(
                    "已自动提交未完成的退出状态恢复: \(record.id)",
                    module: "LibraryViewModel"
                )
                resolvedAny = true
            } catch {
                await logWriter.warning(
                    "自动状态恢复未完成，保留手动重试入口: \(error.localizedDescription)",
                    module: "LibraryViewModel"
                )
            }
        }
        if resolvedAny {
            await refreshGames()
        }
    }
}
