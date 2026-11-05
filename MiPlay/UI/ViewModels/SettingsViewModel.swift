//
//  SettingsViewModel.swift
//  MiPlay
//
//  Created by Steve Tan on 2026/7/7.
//

import AppKit
import SwiftUI

// Source: Architecture Design → ViewModel Layer → SettingsViewModel
// Source: UI Design → View Responsibility → SettingsView

/// 设置视图模型。管理全局应用配置。
@MainActor
@Observable
public final class SettingsViewModel {
    // MARK: - Published State
    /// 当前语言
    private(set) var currentLanguage: String = "zh-Hans"
    /// 可用语言列表
    private(set) var availableLanguages: [(code: String, name: String)] = [
        ("zh-Hans", "简体中文"),
        ("en", "English"),
    ]
    /// Wine 就绪状态
    private(set) var wineStatus: WineStatusText = .unknown
    /// Wine 路径
    private(set) var winePath: String = ""
    /// 系统版本
    private(set) var systemVersion: String = ""
    /// I-5: system-provided machine marketing name, e.g. "MacBook Pro".
    private(set) var machineName: String = ""
    /// 芯片类型
    private(set) var chipName: String = ""
    /// Hardware identifier retained for diagnostics; the settings UI does not display it.
    private(set) var modelIdentifier: String = ""
    /// I-5: readable physical memory, e.g. "16 GB".
    private(set) var physicalMemoryText: String = ""
    /// 磁盘空间
    private(set) var diskSpaceText: String = ""
    /// 游戏列表（用于管理）
    private(set) var managedGames: [Game] = []
    /// 错误信息
    private(set) var errorMessage: String?
    /// 关于信息
    private(set) var aboutInfo: AboutInfo = AboutInfo()
    /// 日志内容
    private(set) var logContent: String?
    private(set) var logExportTask: ScheduledTask?
    // MARK: - Wine runtime setup

    /// WineRuntimeSetup 的进度（进行中时非 nil）
    private(set) var downloadProgress: WineDownloadProgress?
    /// 当前正在准备的固定 runtime 标签。
    private(set) var activeWineDownloadTag: String?
    private(set) var wineDownloadTask: ScheduledTask?
    private(set) var wineRecoveryRequired: String?
    /// Fixed Wine target and shared prefix projection for the simplified UI.
    private(set) var fixedRuntimeTag = WineVersionManager.fixedRuntimeTag
    /// Wine 运行时来源的仓库页面地址（设置页「来源」展示并用浏览器打开）。
    var wineSourceRepositoryURL: URL { BuiltInWineVersions.officialSource.repositoryWebURL }
    private(set) var sharedPrefixPath = ""
    private(set) var sharedPrefixReady = false
    private(set) var versionCheckTasks: [String: ScheduledTask] = [:]
    /// 每游戏性能选项（Metal HUD / 解锁帧率…）
    private(set) var performanceOptions: [String: [PerformanceOption]] = [:]
    /// 影响游戏运行的应用级设置（Metal HUD、帧率解锁、Retina、左 Command）。
    /// 对照 YAAGL 的全局开关；保存后在下一次启动游戏时生效。
    private(set) var gameEnvironmentSettings = GameEnvironmentSettings()
    /// Saved launch requests, kept separate from runtime frame-generation status.
    private(set) var lsfgSettingsByGame: [String: LSFGSettings] = [:]
    private(set) var lsfgComponentInstalled = false
    private(set) var lsfgShaderImported = false
    private(set) var isImportingLSFGShader = false
    private var lsfgSaveTasks: [String: Task<Void, Never>] = [:]
    /// 手动"校验文件完整性"任务的快照（每游戏）
    private(set) var integrityCheckTasks: [String: ScheduledTask] = [:]
    /// 游戏内容下载任务与瞬时网络进度（每游戏）。
    private(set) var gameDownloadTasks: [String: ScheduledTask] = [:]
    private(set) var gameDownloadProgress: [String: TaskDownloadProgress] = [:]
    private var gameDownloadSubmissions: Set<String> = []

    /// 刷新 Wine 状态
    public func refreshWineState() async {
        let readiness = await wineVersionManager.checkReadiness()
        let prefix = await wineVersionManager.validatedSharedPrefix()
        sharedPrefixReady = prefix != nil
        sharedPrefixPath = prefix?.path ?? ""
        switch readiness {
        case .ready(let versionPath):
            wineStatus = .ready(version: URL(fileURLWithPath: versionPath).lastPathComponent)
            winePath = URL(fileURLWithPath: versionPath).appendingPathComponent("bin/wine").path
        case .notSelected:
            wineStatus = .notSelected
            winePath = ""
        case .notDownloaded:
            wineStatus = .notDownloaded
            winePath = ""
        case .prefixNotReady(let gameID):
            wineStatus = .prefixNotReady(gameID: gameID)
            winePath = ""
        case .error(let detail):
            wineStatus = .error(detail)
            winePath = ""
        }
    }

    /// Enqueues the one fixed WineRuntimeSetup task. The UI never supplies a
    /// version tag, source, URL or per-game target.
    public func setupWineRuntime() async {
        do {
            let receipt = try await taskScheduler.enqueueReceipt(
                type: .wineRuntimeSetup,
                gameId: nil,
                context: ["runtimeIdentity": WineVersionManager.fixedRuntimeTag]
            )
            let task = try await taskScheduler.taskSnapshot(id: receipt.taskID)
            wineDownloadTask = task
            activeWineDownloadTag = task.state == .pending || task.state == .running
                ? WineVersionManager.fixedRuntimeTag
                : nil
            wineRecoveryRequired = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func cancelWineDownload() async {
        guard let taskID = wineDownloadTask?.id else { return }
        do {
            try await taskScheduler.cancel(taskId: taskID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func checkVersion(for gameID: String) async {
        guard managedGames.contains(where: { $0.id == gameID }) else {
            errorMessage = "游戏尚未定位，无法检查版本"
            return
        }
        do {
            let receipt = try await taskScheduler.enqueueReceipt(
                type: .versionCheck,
                gameId: gameID
            )
            versionCheckTasks[gameID] = try await taskScheduler.taskSnapshot(id: receipt.taskID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func isCheckingVersion(for gameID: String) -> Bool {
        guard let task = versionCheckTasks[gameID] else { return false }
        return task.state == .pending || task.state == .running
    }

    // MARK: - Game content downloads

    public func isDownloadingGame(for gameID: String) -> Bool {
        gameDownloadSubmissions.contains(gameID) || GameDownloadPresentation.isActive(gameDownloadTasks[gameID])
    }

    public func canUpdateGame(for gameID: String) -> Bool {
        guard let game = managedGames.first(where: { $0.id == gameID }),
              !isDownloadingGame(for: gameID), !isCheckingVersion(for: gameID), !isVerifyingFiles(for: gameID) else { return false }
        return GameDownloadPresentation.canSubmitUpdate(for: game, task: gameDownloadTasks[gameID])
    }

    public func recoverGameFiles(for gameID: String) async {
        guard let game = await gameRegistry.getGame(by: gameID), game.state == .gameUpdating,
              !isDownloadingGame(for: gameID), !isCheckingVersion(for: gameID), !isVerifyingFiles(for: gameID) else { return }
        gameDownloadSubmissions.insert(gameID)
        defer { gameDownloadSubmissions.remove(gameID) }
        do {
            let receipt = try await taskScheduler.enqueueReceipt(type: .gameUpdate, gameId: gameID, context: ["recoveryOnly": "true"])
            await projectGameDownload(try await taskScheduler.taskSnapshot(id: receipt.taskID))
        } catch { errorMessage = error.localizedDescription }
    }

    public func canResumeGameDownload(for gameID: String) -> Bool {
        guard let game = managedGames.first(where: { $0.id == gameID }),
              !isDownloadingGame(for: gameID), !isCheckingVersion(for: gameID), !isVerifyingFiles(for: gameID) else { return false }
        return GameDownloadPresentation.canResume(gameDownloadTasks[gameID], for: game)
    }

    public func canReauthorizeGameDirectory(for gameID: String) -> Bool {
        guard let game = managedGames.first(where: { $0.id == gameID }),
              !isDownloadingGame(for: gameID), !isCheckingVersion(for: gameID), !isVerifyingFiles(for: gameID) else { return false }
        return GameDownloadPresentation.canReauthorizeDirectory(for: game, task: gameDownloadTasks[gameID])
    }

    public func reauthorizeGameDirectory(for gameID: String, selectedURL: URL) async {
        guard canReauthorizeGameDirectory(for: gameID), let game = await gameRegistry.getGame(by: gameID),
              !isDownloadingGame(for: gameID),
              GameDownloadPresentation.canReauthorizeDirectory(for: game, task: gameDownloadTasks[gameID]) else {
            errorMessage = "请先等待当前下载结束；仅可为尚未恢复的更新重新授权原目录。"
            return
        }
        gameDownloadSubmissions.insert(gameID)
        defer { gameDownloadSubmissions.remove(gameID) }
        do {
            _ = try await gameRegistry.reauthorizePendingGame(id: gameID, selectedURL: selectedURL)
            managedGames = await gameRegistry.getAllGames()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 继续下载创建新的任务；此前取消/失败事实与原目录授权均保留在历史中。
    public func resumeGameDownload(for gameID: String, confirmedMainland: Bool = false, confirmedLocationBookmark: Data? = nil) async {
        guard canResumeGameDownload(for: gameID),
              let previous = gameDownloadTasks[gameID], let game = await gameRegistry.getGame(by: gameID),
              !isDownloadingGame(for: gameID) else {
            errorMessage = "当前没有可继续的游戏下载任务。"
            return
        }
        if previous.type == .gameUpdate,
           GameDownloadPresentation.mainlandEligibility(for: game) == .requiresConfirmation, !confirmedMainland {
            errorMessage = "此游戏目录的区服尚未确认，继续更新前请再次确认国服身份。"
            return
        }
        gameDownloadSubmissions.insert(gameID)
        defer { gameDownloadSubmissions.remove(gameID) }
        do {
            var context = previous.context
            if previous.type == .gameInstall {
                context = try GameDownloadPresentation.refreshedInstallContext(from: previous, game: game, repository: fileSystemRepository)
            } else {
                context.removeValue(forKey: "confirmedMainland")
                context.removeValue(forKey: "confirmedLocationBookmark")
                if confirmedMainland {
                    context.merge(try GameDownloadPresentation.mainlandConfirmationContext(for: game, bookmark: confirmedLocationBookmark)) { _, fresh in fresh }
                }
                guard GameDownloadPresentation.canResume(previous, for: game) else {
                    throw GameRegistry.RegistrationError.permissionRequired("当前游戏目录的区服或状态已变化，请重新检查。")
                }
            }
            let receipt = try await taskScheduler.enqueueReceipt(type: previous.type, gameId: gameID, context: context)
            gameDownloadProgress.removeValue(forKey: gameID)
            await projectGameDownload(try await taskScheduler.taskSnapshot(id: receipt.taskID))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 仅把用户实际选择的目录书签交给调度器；裸路径不构成写入授权。
    public func installGame(type: GameType, selectedURL: URL) async {
        let gameID = type.rawValue
        guard !isDownloadingGame(for: gameID) else { return }
        gameDownloadSubmissions.insert(gameID)
        defer { gameDownloadSubmissions.remove(gameID) }
        guard selectedURL.startAccessingSecurityScopedResource() else {
            errorMessage = "无法取得所选安装目录的访问权限，请重新选择目录。"
            return
        }
        defer { selectedURL.stopAccessingSecurityScopedResource() }
        do {
            let location = try fileSystemRepository.makeGameLocation(gameID: gameID, for: selectedURL, scope: .readWrite)
            guard let bookmark = location.bookmarkData else {
                throw GameRegistry.RegistrationError.permissionRequired("安装目录书签未创建")
            }
            let receipt = try await taskScheduler.enqueueReceipt(
                type: .gameInstall,
                gameId: gameID,
                context: ["installBookmark": bookmark.base64EncodedString(), "installPath": selectedURL.path]
            )
            gameDownloadProgress.removeValue(forKey: gameID)
            await projectGameDownload(try await taskScheduler.taskSnapshot(id: receipt.taskID))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func updateGame(for gameID: String, confirmedMainland: Bool = false, confirmedLocationBookmark: Data? = nil) async {
        guard canUpdateGame(for: gameID), let game = await gameRegistry.getGame(by: gameID),
              !isDownloadingGame(for: gameID) else {
            errorMessage = "请先检查更新并确认这是已授权的国服官方客户端。"
            return
        }
        guard GameDownloadPresentation.mainlandEligibility(for: game) != .requiresConfirmation || confirmedMainland else {
            errorMessage = "此游戏目录的区服尚未确认，请先确认它属于国服官方客户端。"
            return
        }
        gameDownloadSubmissions.insert(gameID)
        defer { gameDownloadSubmissions.remove(gameID) }
        do {
            let context = confirmedMainland
                ? try GameDownloadPresentation.mainlandConfirmationContext(for: game, bookmark: confirmedLocationBookmark) : [:]
            guard GameDownloadPresentation.canSubmitUpdate(for: game, task: gameDownloadTasks[gameID]) else {
                throw GameRegistry.RegistrationError.permissionRequired("当前游戏目录的区服或状态已变化，请重新检查。")
            }
            let receipt = try await taskScheduler.enqueueReceipt(
                type: .gameUpdate, gameId: gameID,
                context: context
            )
            gameDownloadProgress.removeValue(forKey: gameID)
            await projectGameDownload(try await taskScheduler.taskSnapshot(id: receipt.taskID))
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func cancelGameDownload(for gameID: String) async {
        guard let task = gameDownloadTasks[gameID], GameDownloadPresentation.isActive(task) else { return }
        do {
            try await taskScheduler.cancel(taskId: task.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Dependencies

    private let systemDetector: SystemEnvironmentDetector
    private let wineVersionManager: WineVersionManager
    private let gameRegistry: GameRegistry
    private let fileSystemRepository: GameFileSystemRepository
    private let taskScheduler: TaskScheduler
    private let performanceOptionManager: PerformanceOptionManager
    private let backgroundMediaService: BackgroundMediaService?
    private var taskObservation: Task<Void, Never>?
    private var progressObservation: Task<Void, Never>?
    private var lastTaskEventSequence: UInt64 = 0

    public init(
        systemDetector: SystemEnvironmentDetector,
        wineVersionManager: WineVersionManager,
        gameRegistry: GameRegistry,
        fileSystemRepository: GameFileSystemRepository,
        taskScheduler: TaskScheduler,
        performanceOptionManager: PerformanceOptionManager,
        backgroundMediaService: BackgroundMediaService? = nil
    ) {
        self.systemDetector = systemDetector
        self.wineVersionManager = wineVersionManager
        self.gameRegistry = gameRegistry
        self.fileSystemRepository = fileSystemRepository
        self.taskScheduler = taskScheduler
        self.performanceOptionManager = performanceOptionManager
        self.backgroundMediaService = backgroundMediaService
    }

    /// Apply a changed background retention preference to active cache work.
    func backgroundRetentionSettingDidChange(forGameID gameID: String? = nil) {
        backgroundMediaService?.retentionSettingDidChange(forGameID: gameID)
    }

    // MARK: - Initialization

    /// 加载设置
    // Source: QA Report → F-001 — Wine 状态接入 UI
    public func loadSettings() async {
        currentLanguage = UserDefaults.standard.stringArray(forKey: "AppleLanguages")?.first ?? "zh-Hans"
        systemVersion = systemDetector.getOSVersion()
        chipName = systemDetector.getChipName()
        modelIdentifier = systemDetector.getModelIdentifier()
        machineName = systemDetector.getMachineName()
        physicalMemoryText = systemDetector.getPhysicalMemoryText()
        managedGames = await gameRegistry.getAllGames()

        // 检测 Wine（统一通过 WineVersionManager）
        await refreshWineState()

        // 磁盘空间
        do {
            let (free, total) = try systemDetector.getDiskSpace(at: NSHomeDirectory())
            diskSpaceText = "可用 \(ByteCountFormatter.string(fromByteCount: Int64(free), countStyle: .file)) / 共 \(ByteCountFormatter.string(fromByteCount: Int64(total), countStyle: .file))"
        } catch {
            diskSpaceText = "检测失败"
        }

        aboutInfo = AboutInfo()

        await startTaskObservation()
        await restoreWineTaskProjection()
        await restoreCheckTaskProjections()
        await restoreGameDownloadProjections()
        await loadPerformanceOptions()
        gameEnvironmentSettings = await wineVersionManager.gameEnvironmentSettings()
        await loadLSFGSettings()
    }

    // MARK: - LSFG requests (each game, next launch)

    func lsfgSettings(for gameID: String) -> LSFGSettings {
        lsfgSettingsByGame[gameID] ?? LSFGSettings()
    }

    func loadLSFGSettings() async {
        await waitForLSFGSettingsSave()
        do {
            let data = try await gameRegistry.persistenceStore.readAppData()
            lsfgSettingsByGame = data.perGameSettings.mapValues(\.lsfg)
        } catch {
            errorMessage = error.localizedDescription
        }
        refreshLSFGResourceStatus()
    }

    private func refreshLSFGResourceStatus() {
        lsfgComponentInstalled = LSFGResources.isInstalled
        lsfgShaderImported = FileManager.default.fileExists(atPath: LSFGResources.shaderPackageURL.path)
    }

    func importLSFGShader(from url: URL) async {
        guard !isImportingLSFGShader else { return }
        isImportingLSFGShader = true
        defer { isImportingLSFGShader = false }
        do {
            try await LSFGResources.importShaderPackage(from: url)
            refreshLSFGResourceStatus()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// Update immediately for Toggle bindings, then serialize writes per game.
    /// Each transaction changes only LSFG so unrelated game facts are retained.
    func applyLSFGSettingsChange(for gameID: String, _ mutate: (inout LSFGSettings) -> Void) {
        let previous = lsfgSettings(for: gameID)
        var updated = previous
        mutate(&updated)
        do { try updated.validated() }
        catch {
            // Disabling must remain a recovery path even if a hand-edited or
            // older snapshot contains parameters that cannot be launched.
            guard !updated.enabled, previous.enabled else {
                errorMessage = error.localizedDescription
                return
            }
            updated = LSFGSettings()
        }
        guard updated != previous else { return }
        lsfgSettingsByGame[gameID] = updated
        let store = gameRegistry.persistenceStore
        lsfgSaveTasks[gameID] = LSFGSettingsPersistence.enqueue(store: store, gameID: gameID) { [weak self, updated] in
            do {
                try await store.updateAppData { data in
                    var settings = data.perGameSettings[gameID] ?? PerGameSettings(gameID: gameID)
                    settings.lsfg = updated
                    data.perGameSettings[gameID] = settings
                }
            } catch {
                guard let self else { return }
                if self.lsfgSettingsByGame[gameID] == updated {
                    let saved = try? await store.readAppData()
                    // Another edit may have arrived while reading the saved value.
                    if self.lsfgSettingsByGame[gameID] == updated {
                        self.lsfgSettingsByGame[gameID] = saved?.perGameSettings[gameID]?.lsfg ?? previous
                    }
                }
                self.errorMessage = error.localizedDescription
            }
        }
    }

    /// Also used before reloading settings, so an in-flight write cannot make
    /// a newly opened settings window briefly display an older preference.
    func waitForLSFGSettingsSave() async {
        for task in lsfgSaveTasks.values { await task.value }
    }

    // MARK: - 游戏运行设置（通用设置页；对照 YAAGL 的全局开关）

    /// 切换 Metal HUD（启动时注入 `MTL_HUD_*`）。
    public func applyMetalHUD(_ isEnabled: Bool) {
        updateGameEnvironmentSettings { $0.metalHUD = isEnabled }
    }

    /// 切换解锁帧率（等待解锁工具接入后生效）。
    public func applyFPSUnlock(_ isEnabled: Bool) {
        updateGameEnvironmentSettings { $0.fpsUnlock = isEnabled }
    }

    public func applyDLSSCompatibility(_ isEnabled: Bool) {
        updateGameEnvironmentSettings { $0.dlssCompatibility = isEnabled }
    }

    /// 切换 Retina 模式（`RetinaMode`：y = 按设备像素渲染）。
    public func applyRetinaMode(_ isEnabled: Bool) {
        updateGameEnvironmentSettings { $0.retinaMode = isEnabled }
    }

    /// 切换「左 Command 映射为 Control」（`LeftCommandIsCtrl`）。
    public func applyLeftCommandIsCtrl(_ isEnabled: Bool) {
        updateGameEnvironmentSettings { $0.leftCommandIsCtrl = isEnabled }
    }

    /// 同步更新内存状态（`Toggle` 的 setter 返回后立刻读到新值，开关不回弹），
    /// 持久化转后台；失败回滚并报错。与 `applyPerformanceOptionChange` 同一模式。
    private func updateGameEnvironmentSettings(_ mutate: (inout GameEnvironmentSettings) -> Void) {
        var updated = gameEnvironmentSettings
        mutate(&updated)
        guard updated != gameEnvironmentSettings else { return }
        let previous = gameEnvironmentSettings
        gameEnvironmentSettings = updated
        // 显式捕获 manager：`[weak self]` 下不能隐式访问 self 的成员。
        Task { [weak self, wineVersionManager] in
            do {
                try await wineVersionManager.updateGameEnvironmentSettings(updated)
            } catch {
                guard let self else { return }
                // 只有当前值仍是本次写入的值时才回滚，避免覆盖后续修改。
                if self.gameEnvironmentSettings == updated {
                    self.gameEnvironmentSettings = previous
                }
                self.errorMessage = error.localizedDescription
            }
        }
    }

    /// 恢复最近一次版本检查/完整校验任务的投影（应用重启后按钮状态正确）。
    private func restoreCheckTaskProjections() async {
        let tasks = await taskScheduler.allTaskSnapshots().sorted(by: { $0.createdAt < $1.createdAt })
        for task in tasks where task.type == .versionCheck {
            guard let gameID = task.gameId else { continue }
            if task.context["fileVerification"] == "true" {
                integrityCheckTasks[gameID] = task
            } else {
                versionCheckTasks[gameID] = task
            }
        }
    }

    private func restoreGameDownloadProjections() async {
        let tasks = await taskScheduler.allTaskSnapshots().sorted { $0.createdAt < $1.createdAt }
        for task in tasks where task.type == .gameInstall || task.type == .gameUpdate || task.type == .gamePredownload {
            guard let gameID = task.gameId,
                  GameDownloadPresentation.shouldProject(task, replacing: gameDownloadTasks[gameID]) else { continue }
            gameDownloadTasks[gameID] = task
        }
    }

    private func projectGameDownload(_ task: ScheduledTask) async {
        guard let gameID = task.gameId else { return }
        guard GameDownloadPresentation.shouldProject(task, replacing: gameDownloadTasks[gameID]) else { return }
        gameDownloadTasks[gameID] = task
        guard !GameDownloadPresentation.isActive(task) else { return }
        gameDownloadProgress.removeValue(forKey: gameID)
        managedGames = await gameRegistry.getAllGames()
        if task.state == .completed,
           !GameDownloadPresentation.resultConfirmed(for: task, game: managedGames.first(where: { $0.id == gameID })) {
            errorMessage = "游戏下载任务已结束，但安装版本与目录尚未确认。"
        }
    }

    // MARK: - Language

    /// 切换语言
    public func setLanguage(_ code: String) {
        currentLanguage = code
        UserDefaults.standard.set([code], forKey: "AppleLanguages")
        UserDefaults.standard.synchronize()
    }

    // MARK: - Game Library Management

    /// 添加游戏路径
    public func addGamePath(type: GameType, path: String) async {
        do {
            try await gameRegistry.addGame(type: type, installPath: path)
            managedGames = await gameRegistry.getAllGames()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 移除游戏
    public func removeGame(id: String) async {
        do {
            try await gameRegistry.removeGame(id: id)
            managedGames = await gameRegistry.getAllGames()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Logs

    /// 导出日志
    public func exportLogs() async {
        var exportTaskID: ScheduledTaskID?
        do {
            let receipt = try await taskScheduler.enqueueReceipt(type: .logExport, gameId: nil)
            exportTaskID = receipt.taskID
            logExportTask = try await taskScheduler.taskSnapshot(id: receipt.taskID)
            while !Task.isCancelled {
                try await Task.sleep(for: .milliseconds(25))
                let snapshot = try await taskScheduler.taskSnapshot(id: receipt.taskID)
                logExportTask = snapshot
                guard snapshot.state == .completed || snapshot.state == .failed || snapshot.state == .cancelled else {
                    continue
                }
                switch snapshot.state {
                case .completed:
                    logContent = await taskScheduler.logExportResult(for: receipt.taskID) ?? ""
                case .failed:
                    errorMessage = snapshot.error ?? snapshot.recovery ?? "日志导出失败"
                case .cancelled:
                    errorMessage = snapshot.recovery ?? "日志导出已取消"
                case .pending, .running:
                    break
                }
                return
            }
            if let exportTaskID {
                try? await taskScheduler.cancel(taskId: exportTaskID)
            }
        } catch is CancellationError {
            if let exportTaskID {
                try? await taskScheduler.cancel(taskId: exportTaskID)
            }
            errorMessage = "日志导出已取消"
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 清除错误
    public func clearError() {
        errorMessage = nil
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

    private func consume(_ progress: TaskProgress) async {
        guard let task = try? await taskScheduler.taskSnapshot(id: progress.taskId) else { return }
        if task.type == .gameInstall || task.type == .gameUpdate || task.type == .gamePredownload {
            guard let gameID = task.gameId,
                  GameDownloadPresentation.shouldProject(task, replacing: gameDownloadTasks[gameID]) else { return }
            if GameDownloadPresentation.isActive(task) {
                gameDownloadProgress[gameID] = progress.download
            }
            await projectGameDownload(task)
            return
        }
        if task.type == .versionCheck {
            await projectVersionCheck(task)
            return
        }
        guard task.type == .wineRuntimeSetup else { return }
        if task.state == .pending || task.state == .running {
            projectProgress(
                task: task,
                phase: progress.phase,
                progress: progress.progress,
                download: progress.download
            )
        } else {
            await project(task)
        }
    }

    private func consume(_ event: TaskEvent) async {
        if event.snapshot.type == .gameInstall || event.snapshot.type == .gameUpdate || event.snapshot.type == .gamePredownload {
            await projectGameDownload(event.snapshot)
            return
        }
        if event.snapshot.type == .versionCheck {
            await projectVersionCheck(event.snapshot)
            return
        }
        guard event.snapshot.type == .wineRuntimeSetup else { return }
        if lastTaskEventSequence != 0, event.sequence > lastTaskEventSequence + 1,
           let snapshot = try? await taskScheduler.taskSnapshot(id: event.snapshot.id) {
            await project(snapshot)
        }
        lastTaskEventSequence = max(lastTaskEventSequence, event.sequence)
        await project(event.snapshot)
    }

    private func projectProgress(
        task: ScheduledTask,
        phase: String,
        progress: Double?,
        download: TaskDownloadProgress? = nil
    ) {
        wineDownloadTask = task
        activeWineDownloadTag = WineVersionManager.fixedRuntimeTag
        downloadProgress = WineDownloadProgress(
            phase: phase,
            progress: progress,
            bytesReceived: download?.bytesReceived,
            totalBytes: download?.totalBytes,
            speed: download?.speed
        )
    }

    private func restoreWineTaskProjection() async {
        let tasks = await taskScheduler.allTaskSnapshots().sorted(by: { $0.createdAt > $1.createdAt })
        if let task = tasks.first(where: { $0.type == .wineRuntimeSetup }) {
            await project(task, refreshCatalog: false)
        }
    }

    private func projectVersionCheck(_ task: ScheduledTask) async {
        guard let gameID = task.gameId else { return }
        if task.context["fileVerification"] == "true" {
            integrityCheckTasks[gameID] = task
        } else {
            versionCheckTasks[gameID] = task
        }
        switch task.state {
        case .pending, .running:
            return
        case .completed:
            managedGames = await gameRegistry.getAllGames()
        case .failed, .cancelled:
            if task.state == .failed {
                errorMessage = task.error ?? task.recovery ?? "版本检查失败"
            }
        }
    }

    private func project(_ task: ScheduledTask, refreshCatalog: Bool = true) async {
        _ = refreshCatalog
        wineDownloadTask = task
        switch task.state {
        case .pending, .running:
            projectProgress(task: task, phase: task.phaseDescription, progress: task.progress)
        case .completed:
            guard task.outcome == "runtimePairReady" || task.outcome == "wineInstalled" else {
                wineRecoveryRequired = "Wine 任务缺少已安装结果"
                errorMessage = wineRecoveryRequired
                activeWineDownloadTag = nil
                downloadProgress = nil
                return
            }
            activeWineDownloadTag = nil
            downloadProgress = nil
            wineRecoveryRequired = nil
            await refreshWineState()
        case .cancelled:
            activeWineDownloadTag = nil
            downloadProgress = nil
            if task.outcome == "cleanupVerified" {
                wineRecoveryRequired = nil
            } else {
                wineRecoveryRequired = task.recovery ?? "Wine 取消清理未确认"
                errorMessage = wineRecoveryRequired
            }
        case .failed:
            activeWineDownloadTag = nil
            downloadProgress = nil
            wineRecoveryRequired = task.recovery
            errorMessage = task.error ?? "Wine 下载未完成"
        }
    }

    // MARK: - 性能选项（每游戏）

    /// 加载三款游戏的性能选项投影。
    public func loadPerformanceOptions() async {
        var options: [String: [PerformanceOption]] = [:]
        for game in managedGames {
            options[game.id] = performanceOptionManager.getOptions(for: game.id)
        }
        performanceOptions = options
    }

    public func options(for gameID: String) -> [PerformanceOption] {
        performanceOptions[gameID] ?? []
    }

    /// 单个选项的当前快照（含参数值）。
    public func performanceOption(gameID: String, optionID: String) -> PerformanceOption? {
        options(for: gameID).first { $0.id == optionID }
    }

    public func setPerformanceOption(gameID: String, optionID: String, enabled: Bool) async {
        do {
            try await performanceOptionManager.setOption(
                gameId: gameID,
                optionId: optionID,
                enabled: enabled
            )
            performanceOptions[gameID] = performanceOptionManager.getOptions(for: gameID)
        } catch {
            // 失败时回滚乐观应用的内存状态，界面开关回到真实值。
            performanceOptions[gameID] = performanceOptionManager.getOptions(for: gameID)
            errorMessage = error.localizedDescription
        }
    }

    /// 同步应用开关状态并返回是否被接受。
    ///
    /// SwiftUI 的 `Toggle` 在 setter 返回后会立刻重新读取绑定值：若状态要等
    /// `Task` 里的异步持久化才更新，开关会先弹回原位。因此这里同步写入内存
    /// 状态（界面立即停在正确位置），持久化在后台进行，失败再回滚。
    @discardableResult
    public func applyPerformanceOptionChange(
        gameID: String,
        optionID: String,
        enabled: Bool
    ) -> Bool {
        var options = performanceOptionManager.getOptions(for: gameID)
        guard let index = options.firstIndex(where: { $0.id == optionID }) else {
            return false
        }
        let previous = options[index].isEnabled
        guard previous != enabled else { return true }
        options[index].isEnabled = enabled
        performanceOptions[gameID] = options
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.performanceOptionManager.setOption(
                    gameId: gameID,
                    optionId: optionID,
                    enabled: enabled
                )
                self.performanceOptions[gameID] = self.performanceOptionManager.getOptions(for: gameID)
            } catch {
                // 持久化失败：回滚内存状态并报告，避免界面显示未保存的开关。
                var reverted = self.performanceOptionManager.getOptions(for: gameID)
                if let index = reverted.firstIndex(where: { $0.id == optionID }) {
                    reverted[index].isEnabled = previous
                }
                self.performanceOptions[gameID] = reverted
                self.errorMessage = error.localizedDescription
            }
        }
        return true
    }

    /// 更新选项参数（如 MetalFX 空间缩放系数）。非法输入由领域层拒绝并回报。
    public func setPerformanceOptionValue(gameID: String, optionID: String, value: String) async {
        do {
            try await performanceOptionManager.setValue(
                gameId: gameID,
                optionId: optionID,
                value: value
            )
            performanceOptions[gameID] = performanceOptionManager.getOptions(for: gameID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 报告无法解析的选项参数输入（视图层已回落到已保存值）。
    public func reportInvalidPerformanceParameter(optionName: String, rawValue: String) {
        let shown = rawValue.isEmpty ? "空" : rawValue
        errorMessage = "「\(optionName)」的参数「\(shown)」不是数字：请输入 1.0–2.0 之间的值"
    }

    /// 报告被夹取到合法区间的参数输入（视图层已显示实际生效值）。
    public func reportParameterClamped(optionName: String, appliedValue: String) {
        errorMessage = "「\(optionName)」的参数超出 1.0–2.0，已按 \(appliedValue) 生效"
    }

    // MARK: - 校验文件完整性（手动入口）

    /// 排入逐文件 MD5 完整校验（耗时数分钟；不阻塞启动与媒体加载）。
    public func verifyGameFiles(for gameID: String) async {
        guard managedGames.contains(where: { $0.id == gameID }) else {
            errorMessage = "游戏尚未定位，无法校验文件"
            return
        }
        do {
            let receipt = try await taskScheduler.enqueueReceipt(
                type: .versionCheck,
                gameId: gameID,
                context: ["fileVerification": "true"]
            )
            integrityCheckTasks[gameID] = try await taskScheduler.taskSnapshot(id: receipt.taskID)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    public func isVerifyingFiles(for gameID: String) -> Bool {
        guard let task = integrityCheckTasks[gameID] else { return false }
        return task.state == .pending || task.state == .running
    }

    // MARK: - 打开目录（快速操作）

    public func openGameDirectory(for gameID: String) {
        guard let game = managedGames.first(where: { $0.id == gameID }),
              let path = game.installPath, !path.isEmpty else {
            errorMessage = "游戏尚未定位"
            return
        }
        NSWorkspace.shared.open(URL(fileURLWithPath: path, isDirectory: true))
    }

    public func openDataDirectory() async {
        let url = await fileSystemRepository.appSupportDirectory()
        NSWorkspace.shared.open(url)
    }

    public func openLogsDirectory() async {
        let url = await fileSystemRepository.appSupportDirectory()
            .appendingPathComponent("Logs", isDirectory: true)
        NSWorkspace.shared.open(url)
    }

}
