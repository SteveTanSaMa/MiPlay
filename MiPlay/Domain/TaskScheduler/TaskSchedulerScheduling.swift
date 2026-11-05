// TaskSchedulerScheduling.swift
// MiPlay

import Foundation

// Source: Architecture Design -> Task Queue -> Scheduling and execution
extension TaskScheduler {
    // MARK: - Scheduling

    internal func schedule() {
        if activeForeground == nil {
            if let index = queue.firstIndex(where: { id in
                guard let task = tasks[id], !task.type.isBackground else { return false }
                return resourcesAvailable(for: task)
            }) {
                let id = queue.remove(at: index)
                activeForeground = id
                lockResources(for: tasks[id]!)
                let execution = Task { [weak self] in
                    guard let self else { return }
                    await self.run(taskID: id)
                }
                executionTasks[id] = execution
            }
        }

        let backgroundIDs = queue.compactMap { id -> ScheduledTaskID? in
            guard let task = tasks[id], task.type.isBackground, resourcesAvailable(for: task) else { return nil }
            return id
        }
        for id in backgroundIDs {
            // Earlier tasks in this batch may have acquired an overlapping
            // game lock since the initial queue scan.
            guard let task = tasks[id], resourcesAvailable(for: task) else { continue }
            // Do not let a long background download take resources needed by
            // a waiting foreground task while another foreground task runs.
            // Unrelated background work remains free to proceed.
            let keys = resourceKeys(for: task)
            let conflictsWithWaitingForeground = queue.contains { queuedID in
                guard let queued = tasks[queuedID], !queued.type.isBackground else { return false }
                return !keys.isDisjoint(with: resourceKeys(for: queued))
            }
            guard !conflictsWithWaitingForeground else { continue }
            queue.removeAll { $0 == id }
            activeBackground.insert(id)
            lockResources(for: task)
            let execution = Task { [weak self] in
                guard let self else { return }
                await self.run(taskID: id)
            }
            executionTasks[id] = execution
        }
    }

    internal func run(taskID: ScheduledTaskID) async {
        guard var task = tasks[taskID] else { return }
        do {
            task.state = .running
            task.startedAt = Date()
            task.phaseDescription = "开始执行"
            task.revision += 1
            try await commit(task)
            await recordTaskEvent(
                task,
                eventName: "task.running",
                phase: "running",
                result: "started",
                messageCode: "task.running"
            )

            switch task.type {
            case .gameInstall, .gameUpdate:
                try await runSophon(taskID: taskID, task: task)
            case .gamePredownload:
                try await runSophonPredownload(taskID: taskID, task: task)
            case .gameLaunch:
                try await phase(taskID, "正在检查游戏文件和权限", progress: nil)
                guard let gameID = task.gameId, let game = await gameRegistry.getGame(by: gameID) else { throw SchedulerError.invalidRequest("游戏不存在") }
                let launchResult = await launchOrchestrator.launch(game: game)
                switch launchResult {
                case .success: try await finish(taskID, state: .completed, outcome: "runningConfirmed", error: nil, recovery: nil, phase: "已确认游戏正在运行")
                case .failure(let error):
                    if case .cancelled = error { try await finish(taskID, state: .cancelled, outcome: "cleanupVerified", error: nil, recovery: nil, phase: "已取消，清理已确认") }
                    else { try await finish(taskID, state: .failed, outcome: nil, error: error.localizedDescription, recovery: "根据失败事实修复后重试", phase: "启动未完成") }
                }

            case .integrityVerification:
                try await phase(taskID, "正在校验完整性", progress: nil)
                guard let gameID = task.gameId, let game = await gameRegistry.getGame(by: gameID) else { throw SchedulerError.invalidRequest("游戏不存在") }
                let result = try await integrityVerifier.verify(game: game)
                try await gameRegistry.updateIntegrity(id: gameID, result: result)
                try await finish(taskID, state: .completed, outcome: result.status.rawValue, error: nil, recovery: nil, phase: result.status == .passed ? "完整性校验通过" : "已取得完整性结果")

            case .versionCheck:
                // context["fileVerification"] = "true" 时执行逐文件 MD5 校验
                //（设置页的"校验文件完整性"手动入口）。
                let deepVerification = task.context["fileVerification"] == "true"
                try await phase(taskID, deepVerification ? "正在校验游戏文件" : "正在检测版本", progress: nil)
                guard let gameID = task.gameId, let game = await gameRegistry.getGame(by: gameID), let versionChecker else { throw SchedulerError.invalidRequest("版本检查器未配置") }
                let verificationProgress: (@Sendable (Double) async throws -> Void)?
                if deepVerification {
                    verificationProgress = { @Sendable [weak self] progress in
                        guard let self else { throw CancellationError() }
                        try await self.phase(taskID, "正在校验游戏文件", progress: progress)
                    }
                } else {
                    verificationProgress = nil
                }
                let result = try await versionChecker.checkVersion(
                    for: game, fileVerification: deepVerification, verificationProgress: verificationProgress
                )
                if deepVerification {
                    try await phase(taskID, "正在确认版本信息", progress: nil)
                }
                if result.outcome == .versionEvidenceConflict {
                    try await gameRegistry.recordMetadataFailure(
                        id: gameID,
                        detail: result.conflictDetails.joined(separator: "; ")
                    )
                    try await finish(
                        taskID,
                        state: .failed,
                        outcome: "versionEvidenceConflict",
                        error: result.conflictDetails.joined(separator: "; "),
                        recovery: "确认同一游戏、渠道和 manifest 后重试",
                        phase: "版本证据冲突，未改变游戏状态"
                    )
                } else {
                    try await gameRegistry.commitVersionCheck(id: gameID, result: result)
                    try await finish(
                        taskID,
                        state: .completed,
                        outcome: result.updateAvailable ? "updateAvailable" : "upToDate",
                        error: nil,
                        recovery: nil,
                        phase: "版本检测完成"
                    )
                }

            case .solutionApply:
                try await phase(taskID, "正在检查兼容方案能力", progress: nil)
                guard let gameID = task.gameId, let solutionID = task.context["solutionId"], let game = await gameRegistry.getGame(by: gameID) else { throw SchedulerError.invalidRequest("方案任务参数无效") }
                let application = try await solutionEngine.applySolution(solutionId: solutionID, for: game)
                try await gameRegistry.addSolutionApplication(id: gameID, application: application)
                try await finish(taskID, state: .completed, outcome: "solutionApplied", error: nil, recovery: nil, phase: "兼容方案已应用并验证")

            case .solutionRevert:
                try await phase(taskID, "正在恢复应用前状态", progress: nil)
                guard let gameID = task.gameId, let applicationID = task.context["applicationId"], let game = await gameRegistry.getGame(by: gameID), let application = game.solutionApplications.first(where: { $0.id == applicationID }) else { throw SchedulerError.invalidRequest("回滚任务参数无效") }
                try await solutionEngine.rollbackSolution(application: application, game: game)
                try await gameRegistry.updateSolutionApplicationState(id: gameID, applicationId: applicationID, newState: .rolledBack)
                try await finish(taskID, state: .completed, outcome: "rolledBack", error: nil, recovery: nil, phase: "恢复已确认")

            case .wineRuntimeSetup:
                guard let manager = wineVersionManager else {
                    throw SchedulerError.invalidRequest("Wine 下载任务参数无效")
                }
                if try await manager.setupExistingManagedRuntimeIfPresent() {
                    try await phase(taskID, "正在确认已有 MiPlay Wine", progress: nil)
                    try await finish(taskID, state: .completed, outcome: "runtimePairReady", error: nil, recovery: nil, phase: "固定 Wine runtime 和共享 prefix 已就绪")
                } else {
                    try await phase(taskID, "正在读取固定 Wine 版本信息", progress: nil)
                    let version = try await manager.fetchAvailableVersions().first {
                        $0.tagName == WineVersionManager.fixedRuntimeTag
                    }
                    guard let version else {
                        throw SchedulerError.invalidRequest("未找到固定 Wine 目录条目")
                    }
                    let sessionID = UUID()
                    wineSessionIDs[taskID] = sessionID
                    var terminal = false
                    var recoveryDetail: String?
                    let stream = await manager.downloadAndInstall(version: version, taskID: sessionID)
                    for await downloadPhase in stream {
                        try Task.checkCancellation()
                        switch downloadPhase {
                        case .fetchingMetadata:
                            try await phase(taskID, "正在获取 Wine 版本信息", progress: nil)
                        case .downloading(let progress, let speed, let bytesReceived, let totalBytes):
                            try await phase(
                                taskID,
                                "正在下载 Wine",
                                progress: progress,
                                downloadProgress: TaskDownloadProgress(
                                    bytesReceived: bytesReceived,
                                    totalBytes: totalBytes,
                                    speed: speed
                                )
                            )
                        case .verifying:
                            try await phase(taskID, "正在校验下载归档", progress: nil)
                        case .extracting(let progress):
                            try await phase(taskID, "正在解压 Wine", progress: progress)
                        case .installing:
                            try await phase(taskID, "正在提交 Wine 安装", progress: nil)
                        case .installed:
                            try await phase(taskID, "Wine 文件已安装，正在确认记录", progress: nil)
                        case .completed:
                            terminal = true
                        case .cancelled:
                            throw CancellationError()
                        case .recoveryRequired(let detail):
                            recoveryDetail = detail
                        case .failed(let detail):
                            throw SchedulerError.invalidRequest(detail)
                        case .failedWithFailure(let failure):
                            if let statusCode = failure.statusCode {
                                throw SchedulerError.wineAssetHTTPFailure(
                                    statusCode: statusCode,
                                    detail: failure.localizedDescription
                                )
                            }
                            throw SchedulerError.invalidRequest(failure.localizedDescription)
                        }
                    }
                    if let recoveryDetail {
                        try await finish(taskID, state: .failed, outcome: nil, error: recoveryDetail, recovery: recoveryDetail, phase: "Wine 安装需要恢复")
                    } else if terminal {
                        try await finish(taskID, state: .completed, outcome: "runtimePairReady", error: nil, recovery: nil, phase: "固定 Wine runtime 和共享 prefix 已就绪")
                    } else {
                        throw SchedulerError.invalidRequest("Wine 下载未产生完成事实")
                    }
                }
            case .wineVersionDownload, .wineCatalogQuery:
                // These task names remain decodable for old task history only;
                // new callers must use the single WineRuntimeSetup task.
                throw SchedulerError.unsupported(task.type)
            case .backgroundMediaLoad:
                guard let gameID = task.gameId, let backgroundMediaService else {
                    throw SchedulerError.invalidRequest("背景素材服务未配置")
                }
                try await phase(taskID, "正在加载背景素材", progress: nil)
                await backgroundMediaService.loadMedia(for: gameID)
                try Task.checkCancellation()
                switch await backgroundMediaService.getMediaState(for: gameID) {
                case .ready:
                    try await finish(
                        taskID,
                        state: .completed,
                        outcome: "mediaReady",
                        error: nil,
                        recovery: nil,
                        phase: "背景素材已就绪"
                    )
                case .failed(let detail):
                    try await finish(
                        taskID,
                        state: .failed,
                        outcome: nil,
                        error: detail,
                        recovery: "检查网络或素材缓存后重试",
                        phase: "背景素材加载失败"
                    )
                case .loading, .notLoaded:
                    try await finish(
                        taskID,
                        state: .failed,
                        outcome: nil,
                        error: "背景素材未产生可确认结果",
                        recovery: "重试背景素材加载",
                        phase: "背景素材状态未确认"
                    )
                }
            case .logExport:
                try await phase(taskID, "正在刷新日志缓冲", progress: nil)
                let content = try await logWriter.exportLogs()
                try Task.checkCancellation()
                logExportResults[taskID] = content
                try await finish(
                    taskID,
                    state: .completed,
                    outcome: content.isEmpty ? "empty" : "exported",
                    error: nil,
                    recovery: nil,
                    phase: content.isEmpty ? "没有可导出的日志" : "日志导出已完成"
                )
            }
        } catch is CancellationError {
            do {
                let isGameDownload = task.type == .gameInstall || task.type == .gameUpdate || task.type == .gamePredownload
                let isGameRecovery = task.type == .gameUpdate && task.context["recoveryOnly"] == "true"
                let isPredownload = task.type == .gamePredownload
                let resumeDescription = task.type == .gameUpdate ? "可继续更新" : (task.type == .gameInstall ? "可继续安装" : "可继续下载")
                let cancelledPhase: String
                if task.type == .gameUpdate { cancelledPhase = "更新已暂停，可继续更新" }
                else if task.type == .gameInstall { cancelledPhase = "安装已暂停，可继续安装" }
                else if isPredownload { cancelledPhase = "预下载已取消，可继续下载" }
                else { cancelledPhase = "已取消，清理已确认" }
                try await finish(taskID, state: .cancelled,
                                 outcome: isGameRecovery ? "recoveryInterrupted" : (isGameDownload ? "downloadInterrupted" : "cleanupVerified"),
                                 error: nil, recovery: isGameDownload ? resumeDescription : nil,
                                 phase: cancelledPhase)
            } catch {
                await publishPersistenceFailure(taskID: taskID, detail: error.localizedDescription)
            }
        } catch {
            do {
                let recovery = task.type == .gameUpdate ? "排除错误后可继续更新；更新完成前无法启动游戏。"
                    : (task.type == .gameInstall ? "排除错误后可继续安装。" : "检查失败事实后手动重试")
                try await finish(taskID, state: .failed, outcome: nil, error: error.localizedDescription, recovery: recovery, phase: "任务未完成")
            } catch {
                await publishPersistenceFailure(taskID: taskID, detail: "原始错误: \(error.localizedDescription); 结果持久化失败")
            }
        }

        if let finished = tasks[taskID], !recoveryHeldTasks.contains(taskID) {
            unlockResources(for: finished)
        }
        activeForeground = activeForeground == taskID ? nil : activeForeground
        activeBackground.remove(taskID)
        executionTasks.removeValue(forKey: taskID)
        wineSessionIDs.removeValue(forKey: taskID)
        schedule()
    }

    internal func phase(
        _ id: ScheduledTaskID,
        _ description: String,
        progress: Double?,
        downloadProgress: TaskDownloadProgress? = nil
    ) async throws {
        guard var task = tasks[id] else { throw SchedulerError.taskNotFound(id) }
        let previousDescription = task.phaseDescription
        let previousProgress = task.progress
        task.phaseDescription = description
        task.progress = progress
        if let downloadProgress {
            downloadProgressDetails[id] = downloadProgress
        } else if let previousDownloadProgress = downloadProgressDetails[id] {
            // Keep the completed transfer size visible while verification,
            // extraction, and installation continue. The speed is no longer
            // live once the download phase has ended.
            downloadProgressDetails[id] = TaskDownloadProgress(
                bytesReceived: previousDownloadProgress.bytesReceived,
                totalBytes: previousDownloadProgress.totalBytes,
                speed: 0
            )
        }
        task.revision += 1

        // 进度 tick 的落盘节流：下载/解压每秒会产出大量 tick，若每个 tick 都
        // `commit`（= 全量写一次 AppData），事件与进度会排在写盘后面，界面看起来
        // 卡住（用户实测：下载进度停在 5%，解压阶段完全不动）。
        // 内存状态与事件流每次 tick 都更新（界面即时）；预下载按 5 秒节流，
        // 其他任务保持 300ms。阶段切换和首次到达 0/1 时照常立即落盘。
        let isPredownload = task.type == .gamePredownload
        let interval: Duration = isPredownload ? .seconds(5) : .milliseconds(300)
        let progressPersistedRecently: Bool
        if let last = lastProgressPersistAt[id] {
            progressPersistedRecently = ContinuousClock.now - last < interval
        } else {
            progressPersistedRecently = false
        }
        let shouldPersist: Bool
        if isPredownload {
            shouldPersist = previousDescription != description
                || (previousProgress == nil) != (progress == nil)
                || (previousProgress != progress && (progress == 0 || progress == 1))
                || !progressPersistedRecently
        } else {
            shouldPersist = previousDescription != description
                || progress == nil || progress == 0 || progress == 1 || !progressPersistedRecently
        }
        if shouldPersist {
            try await commit(task)
            lastProgressPersistAt[id] = ContinuousClock.now
        } else {
            tasks[id] = task
            emit(task, persistence: .memoryOnly)
        }
        await recordTaskEvent(
            task,
            eventName: "task.phase",
            phase: "phaseTransition",
            result: "inProgress",
            messageCode: "task.phase"
        )
    }

    internal func finish(
        _ id: ScheduledTaskID,
        state: ScheduledTaskState,
        outcome: String?,
        error: String?,
        recovery: String?,
        phase: String
    ) async throws {
        guard var task = tasks[id] else { throw SchedulerError.taskNotFound(id) }
        task.state = state
        task.endedAt = Date()
        task.phaseDescription = phase
        task.progress = state == .completed ? 1 : nil
        task.outcome = outcome
        task.error = error
        task.recovery = recovery
        task.revision += 1
        downloadProgressDetails.removeValue(forKey: id)
        try await commit(task)
        await recordTaskEvent(
            task,
            eventName: "task.terminal",
            phase: "terminal",
            result: state == .completed ? "completed" : state == .cancelled ? "cancelled" : "failed",
            errorCategory: state == .failed ? "unknown" : state == .cancelled ? "userCancelled" : "none",
            messageCode: "task.terminal"
        )
    }

}
