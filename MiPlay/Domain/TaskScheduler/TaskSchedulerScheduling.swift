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
            queue.removeAll { $0 == id }
            activeBackground.insert(id)
            lockResources(for: tasks[id]!)
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
                try await phase(taskID, "正在检测版本", progress: nil)
                guard let gameID = task.gameId, let game = await gameRegistry.getGame(by: gameID), let versionChecker else { throw SchedulerError.invalidRequest("版本检查器未配置") }
                let result = try await versionChecker.checkVersion(for: game)
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

            case .wineVersionDownload:
                guard let manager = wineVersionManager,
                      let tagName = task.context["tagName"] else {
                    throw SchedulerError.invalidRequest("Wine 下载任务参数无效")
                }
                let version = await manager.cachedAvailableVersion(tagName: tagName)
                guard let version else {
                    throw SchedulerError.invalidRequest("未找到已验证的 Wine 目录条目 \(tagName)，请先刷新版本列表")
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
                    try await finish(taskID, state: .completed, outcome: "wineInstalled", error: nil, recovery: nil, phase: "Wine 下载和安装完成")
                } else {
                    throw SchedulerError.invalidRequest("Wine 下载未产生完成事实")
                }
            case .wineCatalogQuery:
                guard let manager = wineVersionManager else {
                    throw SchedulerError.invalidRequest("Wine 版本管理器未配置")
                }
                try await phase(taskID, "正在获取 Wine 版本目录", progress: nil)
                let versions = try await manager.fetchAvailableVersions()
                try await finish(
                    taskID,
                    state: .completed,
                    outcome: versions.isEmpty ? "noAvailableManagedVersion" : "availableManagedVersions",
                    error: nil,
                    recovery: nil,
                    phase: versions.isEmpty ? "没有可用托管 Wine 版本" : "Wine 版本目录已更新"
                )
            case .backgroundMediaLoad:
                throw SchedulerError.unsupported(task.type)
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
                try await finish(taskID, state: .cancelled, outcome: "cleanupVerified", error: nil, recovery: nil, phase: "已取消，清理已确认")
            } catch {
                await publishPersistenceFailure(taskID: taskID, detail: error.localizedDescription)
            }
        } catch {
            do {
                try await finish(taskID, state: .failed, outcome: nil, error: error.localizedDescription, recovery: "检查失败事实后手动重试", phase: "任务未完成")
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
        task.phaseDescription = description
        task.progress = progress
        if let downloadProgress {
            downloadProgressDetails[id] = downloadProgress
        } else {
            downloadProgressDetails.removeValue(forKey: id)
        }
        task.revision += 1
        try await commit(task)
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
