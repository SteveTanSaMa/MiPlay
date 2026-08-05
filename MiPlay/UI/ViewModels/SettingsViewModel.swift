//
//  SettingsViewModel.swift
//  MiPlay
//
//  Created by Steve Tan on 2026/7/7.
//

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
    /// 芯片类型
    private(set) var chipModel: String = ""
    /// 磁盘空间
    private(set) var diskSpaceText: String = ""
    /// 游戏列表（用于管理）
    private(set) var managedGames: [Game] = []
    /// Per-game presentation settings. The key is always a fixed Game ID.
    private(set) var perGameSettings: [String: PerGameSettings] = [:]
    /// 错误信息
    private(set) var errorMessage: String?
    /// 关于信息
    private(set) var aboutInfo: AboutInfo = AboutInfo()
    /// 日志内容
    private(set) var logContent: String?
    private(set) var logExportTask: ScheduledTask?
    /// 游戏客户端更新可用通知
    private(set) var isGameUpdateNotificationEnabled = true

    // MARK: - Wine 版本状态（F-001）

    /// 可用 Wine 版本列表
    private(set) var availableWineVersions: [WineVersionInfo] = []
    /// 已安装版本数量
    private(set) var installedWineCount: Int = 0
    /// 已安装的 Wine 版本（即使网络版本列表暂时不可用也保持可见）
    private(set) var installedWineVersions: [WineVersionInfo] = []
    /// Wine 下载进度（进行中时非 nil）
    private(set) var downloadProgress: WineDownloadProgress?
    /// 当前正在下载的版本标签。与高频进度数据分离，供版本列表保持稳定布局。
    private(set) var activeWineDownloadTag: String?
    private(set) var wineDownloadTask: ScheduledTask?
    private(set) var wineCatalogTask: ScheduledTask?
    private(set) var wineRecoveryRequired: String?
    /// Wine 版本列表是否正在刷新
    private(set) var isRefreshingWineVersions = false
    /// Wine 目录查询的真实失败/空目录事实
    private(set) var wineCatalogMessage: String?

    /// 刷新 Wine 状态
    public func refreshWineState() async {
        // Settings has no implicit game selection. Do not turn a valid runtime
        // binary into WineReady before a game-specific prefix is verified.
        switch await wineVersionManager.checkReadiness() {
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

    /// 刷新 Wine 版本列表
    public func refreshWineVersions() async {
        wineCatalogGeneration &+= 1
        let generation = wineCatalogGeneration
        isRefreshingWineVersions = true
        wineCatalogMessage = nil
        do {
            let sourceID = await wineVersionManager.getSelectedSourceID()
            let policyRevision = BuiltInWineVersions.sourceDescriptor(for: sourceID)?.policyRevision ?? "unknown"
            if let existing = wineCatalogTask,
               existing.state == .pending || existing.state == .running {
                do {
                    try await taskScheduler.cancel(taskId: existing.id)
                } catch {
                    guard generation == wineCatalogGeneration else { return }
                    wineCatalogMessage = error.localizedDescription
                    isRefreshingWineVersions = false
                    return
                }
            }
            guard generation == wineCatalogGeneration else { return }
            let receipt = try await taskScheduler.enqueueReceipt(
                type: .wineCatalogQuery,
                gameId: nil,
                context: ["sourceID": sourceID, "policyRevision": policyRevision]
            )
            guard generation == wineCatalogGeneration else {
                do {
                    try await taskScheduler.cancel(taskId: receipt.taskID)
                } catch {
                    errorMessage = error.localizedDescription
                }
                return
            }
            latestWineCatalogTaskID = receipt.taskID
            wineCatalogTask = try await taskScheduler.taskSnapshot(id: receipt.taskID)
        } catch {
            guard generation == wineCatalogGeneration else { return }
            wineCatalogMessage = error.localizedDescription
            isRefreshingWineVersions = false
        }
    }

    /// 下载指定 Wine 版本
    public func downloadWineVersion(_ version: WineVersionInfo) async {
        do {
            let receipt = try await taskScheduler.enqueueReceipt(
                type: .wineVersionDownload,
                gameId: nil,
                context: ["tagName": version.tagName]
            )
            let task = try await taskScheduler.taskSnapshot(id: receipt.taskID)
            wineDownloadTask = task
            activeWineDownloadTag = task.state == .pending || task.state == .running
                ? version.tagName
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

    /// 删除一个托管 Wine 版本。
    public func deleteWineVersion(tagName: String) async {
        do {
            try await wineVersionManager.deleteVersion(tagName: tagName)
            await refreshInstalledWineProjection()
            await refreshWineVersions()
            await refreshWineState()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 选中 Wine 版本
    public func selectWineVersion(tagName: String) async {
        do {
            try await wineVersionManager.selectVersion(tagName: tagName)
            await refreshInstalledWineProjection()
            await refreshWineVersions()
            await refreshWineState()
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Dependencies

    private let persistenceStore: PersistenceStore
    private let systemDetector: SystemEnvironmentDetector
    private let wineVersionManager: WineVersionManager
    private let gameRegistry: GameRegistry
    private let fileSystemRepository: GameFileSystemRepository
    private let taskScheduler: TaskScheduler
    private var taskObservation: Task<Void, Never>?
    private var progressObservation: Task<Void, Never>?
    private var lastTaskEventSequence: UInt64 = 0
    private var wineCatalogGeneration: UInt64 = 0
    private var latestWineCatalogTaskID: ScheduledTaskID?

    public init(
        persistenceStore: PersistenceStore,
        systemDetector: SystemEnvironmentDetector,
        wineVersionManager: WineVersionManager,
        gameRegistry: GameRegistry,
        fileSystemRepository: GameFileSystemRepository,
        taskScheduler: TaskScheduler
    ) {
        self.persistenceStore = persistenceStore
        self.systemDetector = systemDetector
        self.wineVersionManager = wineVersionManager
        self.gameRegistry = gameRegistry
        self.fileSystemRepository = fileSystemRepository
        self.taskScheduler = taskScheduler
    }

    // MARK: - Initialization

    /// 加载设置
    // Source: QA Report → F-001 — Wine 状态接入 UI
    public func loadSettings() async {
        currentLanguage = UserDefaults.standard.stringArray(forKey: "AppleLanguages")?.first ?? "zh-Hans"
        isGameUpdateNotificationEnabled = UserDefaults.standard.object(forKey: "gameUpdateNotificationsEnabled") as? Bool ?? true
        systemVersion = systemDetector.getOSVersion()
        chipModel = systemDetector.getChipModel()
        managedGames = await gameRegistry.getAllGames()
        do {
            perGameSettings = try await persistenceStore.readAppData().perGameSettings
        } catch {
            errorMessage = error.localizedDescription
        }

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

        // 加载 Wine 版本列表
        await startTaskObservation()
        await refreshWineVersions()
        await restoreWineTaskProjection()
    }

    // MARK: - Language

    /// 切换语言
    public func setLanguage(_ code: String) {
        currentLanguage = code
        UserDefaults.standard.set([code], forKey: "AppleLanguages")
        UserDefaults.standard.synchronize()
    }

    /// 切换游戏客户端更新通知。
    public func setGameUpdateNotificationEnabled(_ isEnabled: Bool) {
        isGameUpdateNotificationEnabled = isEnabled
        UserDefaults.standard.set(isEnabled, forKey: "gameUpdateNotificationsEnabled")
    }

    public func metadataDisplayEnabled(for gameID: String) -> Bool {
        perGameSettings[gameID]?.metadataDisplayEnabled ?? true
    }

    public func setMetadataDisplayEnabled(for gameID: String, enabled: Bool) async {
        do {
            var appData = try await persistenceStore.readAppData()
            var settings = appData.perGameSettings[gameID] ?? PerGameSettings(gameID: gameID)
            settings.metadataDisplayEnabled = enabled
            appData.perGameSettings[gameID] = settings
            try await persistenceStore.writeAppData(appData)
            let verified = try await persistenceStore.readAppData()
            guard verified.perGameSettings[gameID]?.metadataDisplayEnabled == enabled else {
                throw PersistenceStore.StoreError.writeFailed("游戏设置写回后重读不一致")
            }
            perGameSettings = verified.perGameSettings
        } catch {
            errorMessage = error.localizedDescription
        }
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

    /// 使远程版本与本地已安装版本共存，确保离线时用户仍能管理已下载运行时。
    private func mergeWineVersions(
        available: [WineVersionInfo],
        installed: [WineVersionInfo]
    ) -> [WineVersionInfo] {
        var merged = Dictionary(uniqueKeysWithValues: available.map { version in
            var normalized = version
            // The catalog is cached; installation records are the source of
            // truth for the local downloaded state.
            normalized.isDownloaded = false
            normalized.isSelected = false
            return (normalized.tagName, normalized)
        })
        for installedVersion in installed {
            if var remoteVersion = merged[installedVersion.tagName] {
                remoteVersion.isDownloaded = true
                remoteVersion.isSelected = installedVersion.isSelected
                merged[installedVersion.tagName] = remoteVersion
            } else {
                merged[installedVersion.tagName] = installedVersion
            }
        }
        return merged.values.sorted { $0.publishedAt > $1.publishedAt }
    }

    /// Reprojects local installation facts without waiting for a catalog
    /// network request. This keeps completion and deletion visible immediately.
    private func refreshInstalledWineProjection() async {
        let installed = await wineVersionManager.getInstalledVersions()
        installedWineVersions = installed
        installedWineCount = installed.count
        guard availableWineVersions.isEmpty == false else { return }
        availableWineVersions = mergeWineVersions(
            available: availableWineVersions,
            installed: installed
        )
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
        guard let task = try? await taskScheduler.taskSnapshot(id: progress.taskId),
              task.type == .wineVersionDownload || task.type == .wineCatalogQuery else { return }
        if task.type == .wineCatalogQuery {
            if task.state == .pending || task.state == .running {
                wineCatalogTask = task
                isRefreshingWineVersions = true
                wineCatalogMessage = nil
            } else {
                await project(task)
            }
            return
        }
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
        guard event.snapshot.type == .wineVersionDownload || event.snapshot.type == .wineCatalogQuery else { return }
        if event.snapshot.type == .wineCatalogQuery,
           let latestWineCatalogTaskID,
           event.snapshot.id != latestWineCatalogTaskID {
            return
        }
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
        activeWineDownloadTag = task.context["tagName"]
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
        if let task = tasks.first(where: { $0.type == .wineVersionDownload }) {
            await project(task, refreshCatalog: false)
        }
        if let task = tasks.first(where: { $0.type == .wineCatalogQuery }) {
            await project(task)
        }
    }

    private func project(_ task: ScheduledTask, refreshCatalog: Bool = true) async {
        if task.type == .wineCatalogQuery {
            wineCatalogTask = task
            latestWineCatalogTaskID = task.id
            switch task.state {
            case .pending, .running:
                isRefreshingWineVersions = true
                wineCatalogMessage = nil
            case .completed:
                isRefreshingWineVersions = false
                let available = await wineVersionManager.cachedAvailableVersions()
                let installed = await wineVersionManager.getInstalledVersions()
                installedWineVersions = installed
                installedWineCount = installed.count
                availableWineVersions = mergeWineVersions(available: available, installed: installed)
                wineCatalogMessage = available.isEmpty ? "当前没有符合产品范围的托管 Wine 版本" : nil
            case .failed:
                isRefreshingWineVersions = false
                wineCatalogMessage = task.error ?? task.recovery ?? "Wine 版本目录不可用"
            case .cancelled:
                isRefreshingWineVersions = false
                wineCatalogMessage = "Wine 版本目录查询已取消"
            }
            return
        }

        wineDownloadTask = task
        switch task.state {
        case .pending, .running:
            projectProgress(task: task, phase: task.phaseDescription, progress: task.progress)
        case .completed:
            guard task.outcome == "wineInstalled" else {
                wineRecoveryRequired = "Wine 任务缺少已安装结果"
                errorMessage = wineRecoveryRequired
                activeWineDownloadTag = nil
                downloadProgress = nil
                return
            }
            activeWineDownloadTag = nil
            downloadProgress = nil
            wineRecoveryRequired = nil
            await refreshInstalledWineProjection()
            if refreshCatalog {
                await refreshWineVersions()
            }
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
}
