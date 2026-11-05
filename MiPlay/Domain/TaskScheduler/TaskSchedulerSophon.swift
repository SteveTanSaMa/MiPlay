import Foundation

extension TaskScheduler {
    /// Predownload owns only the verified cache. In particular it must never
    /// invoke recovery or transition the installed game's business state.
    internal func runSophonPredownload(taskID: ScheduledTaskID, task: ScheduledTask) async throws {
        guard let gameID = task.gameId, let game = await gameRegistry.getGame(by: gameID) else {
            throw SchedulerError.invalidRequest("游戏不存在")
        }
        guard game.type.definition.contentCapabilities.sophonPredownload else {
            throw SchedulerError.invalidRequest("此游戏暂不支持预下载")
        }
        guard game.state == .installed || game.state == .updateAvailable || game.state == .launchFailed || game.state == .running else {
            throw SchedulerError.invalidRequest("请先定位游戏并完成当前操作，再进行预下载")
        }
        guard let expectedVersion = task.context["predownloadVersion"], !expectedVersion.isEmpty else {
            throw SchedulerError.invalidRequest("预下载目标版本无效，请重新检查")
        }
        guard let location = game.location, location.bookmarkData != nil, location.scope == .readWrite else {
            throw SchedulerError.invalidRequest("游戏目录没有写入授权")
        }
        // Bind every queued predownload to the directory the user selected.
        // A later re-location must not silently redirect a pending download.
        guard let rawTarget = task.context["predownloadLocationBookmark"],
              let targetBookmark = Data(base64Encoded: rawTarget), !targetBookmark.isEmpty,
              targetBookmark == location.bookmarkData else {
            throw SchedulerError.invalidRequest("预下载目录授权已变化，请重新选择预下载")
        }
        let confirmedMainland = task.context["confirmedMainland"] == "true"
        if confirmedMainland {
            guard let raw = task.context["confirmedLocationBookmark"],
                  let confirmedBookmark = Data(base64Encoded: raw), confirmedBookmark == location.bookmarkData else {
                throw SchedulerError.invalidRequest("确认后的游戏目录已变化，请重新确认国服客户端")
            }
        }
        let repository = gameRegistry.fileSystemRepository
        let access = try repository.acquireSecurityScopedAccess(location)
        defer { access.stop() }
        let installer = SophonInstaller()
        let directoryLock = try await installer.acquireExclusiveAccess(destination: access.url)
        defer { directoryLock.release() }
        if access.resolvedLocation.requiresPersistenceUpdate(from: location) {
            try await gameRegistry.updateResolvedLocation(id: gameID, location: access.resolvedLocation)
        }
        guard !(await installer.hasPendingTransaction(destination: access.url)) else {
            throw SchedulerError.recoveryRequired("游戏存在未完成的下载事务，请先恢复游戏文件")
        }
        let result = try await installer.preDownload(
            game: game.type, destination: access.url, confirmedMainland: confirmedMainland,
            expectedVersion: expectedVersion, holding: directoryLock
        ) { [weak self] progress in
            guard let self else { return }
            await self.reportSophonProgress(progress, taskID: taskID)
        }
        try Task.checkCancellation()
        guard result.version == expectedVersion else {
            throw SchedulerError.invalidRequest("预下载版本发生变化，请重新检查")
        }
        try await finish(taskID, state: .completed, outcome: "gamePredownloaded", error: nil,
                         recovery: nil, phase: "预下载完成（\(result.version)）")
    }

    /// Keep the selected directory's scope and the per-game resource locks for
    /// the whole download, verification, commit and registration operation.
    internal func runSophon(taskID: ScheduledTaskID, task: ScheduledTask) async throws {
        guard let gameID = task.gameId, let game = await gameRegistry.getGame(by: gameID) else {
            throw SchedulerError.invalidRequest("游戏不存在")
        }
        let isInstall = task.type == .gameInstall
        let recoveryOnly = !isInstall && task.context["recoveryOnly"] == "true"
        if recoveryOnly && game.state != .gameUpdating {
            throw SchedulerError.invalidRequest("游戏没有需要恢复的下载事务")
        }
        if isInstall {
            guard game.state == .notInstalled else { throw SchedulerError.invalidRequest("游戏已定位，请使用更新") }
        } else {
            guard game.state == .installed || game.state == .updateAvailable || game.state == .launchFailed || game.state == .gameUpdating else {
                throw SchedulerError.invalidRequest("游戏正在运行或尚未定位，无法更新")
            }
        }
        let location: GameLocation
        if isInstall {
            guard let raw = task.context["installBookmark"], let bookmark = Data(base64Encoded: raw) else {
                throw SchedulerError.invalidRequest("安装目录缺少授权")
            }
            location = GameLocation(gameID: gameID, bookmarkData: bookmark,
                                    lastKnownPath: task.context["installPath"], scope: .readWrite,
                                    resolutionState: .resolvable)
        } else {
            guard let existing = game.location, existing.bookmarkData != nil, existing.scope == .readWrite else {
                throw SchedulerError.invalidRequest("游戏目录没有写入授权")
            }
            if task.context["confirmedMainland"] == "true" {
                guard let raw = task.context["confirmedLocationBookmark"],
                      let confirmedBookmark = Data(base64Encoded: raw),
                      confirmedBookmark == existing.bookmarkData else {
                    throw SchedulerError.invalidRequest("确认后的游戏目录已变化，请重新确认国服客户端")
                }
            }
            location = existing
        }
        let repository = gameRegistry.fileSystemRepository
        let access = try repository.acquireSecurityScopedAccess(location)
        defer { access.stop() }
        let installer = SophonInstaller()
        let directoryLock = try await installer.acquireExclusiveAccess(destination: access.url)
        defer { directoryLock.release() }
        if !isInstall, access.resolvedLocation.requiresPersistenceUpdate(from: location) {
            try await gameRegistry.updateResolvedLocation(id: gameID, location: access.resolvedLocation)
        }
        var recoveredInstall: SophonInstallResult?
        var resumesForwardUpdate = false
        if await installer.hasPendingTransaction(destination: access.url) {
            resumesForwardUpdate = try await installer.hasResumableUpdate(destination: access.url, game: game.type)
            guard !isInstall || !resumesForwardUpdate else {
                throw SchedulerError.invalidRequest("所选目录存在未完成的更新，请先定位该游戏并继续更新")
            }
            try await phase(taskID, resumesForwardUpdate ? "正在继续上次中断的更新" : "正在恢复上次中断的下载", progress: nil)
            recoveredInstall = try await installer.recover(destination: access.url, game: game.type, holding: directoryLock)
            if resumesForwardUpdate, let completed = recoveredInstall {
                try await finishSophon(taskID: taskID, game: game, isInstall: false, directory: access.url, result: completed, installer: installer, holding: directoryLock)
                return
            }
            if let completed = recoveredInstall, isInstall {
                try await finishSophon(taskID: taskID, game: game, isInstall: true, directory: access.url, result: completed, installer: installer, holding: directoryLock)
                return
            }
        }
        if recoveryOnly && !resumesForwardUpdate {
            // A crash may occur after the transaction was recovered but before
            // the registry state was saved. Re-check the authorized directory
            // and complete that state change without fetching any new files.
            guard !(await installer.hasPendingTransaction(destination: access.url)) else {
                throw SchedulerError.recoveryRequired("下载事务尚未恢复，请保留游戏目录并重试")
            }
            if let completed = recoveredInstall {
                try await gameRegistry.updateGameVersion(id: gameID, version: completed.version)
            }
            let isInstalled = game.type.firstExistingExecutable(at: access.url.path) != nil
            try await gameRegistry.transitionGame(id: gameID, to: isInstalled ? .installed : .notInstalled)
            if recoveredInstall != nil {
                try await installer.finalizeCommittedInstall(destination: access.url, game: game.type, holding: directoryLock)
            }
            try await finish(taskID, state: .completed, outcome: "gameRecovered", error: nil,
                             recovery: nil, phase: isInstalled ? "游戏文件已恢复" : "未完成的安装已回滚")
            return
        }
        guard (recoveryOnly && resumesForwardUpdate) || (isInstall ? game.type.definition.contentCapabilities.sophonInstall
                        : game.type.definition.contentCapabilities.sophonUpdate) else {
            throw SchedulerError.invalidRequest("此游戏暂不支持该下载操作")
        }
        if !isInstall, game.state != .gameUpdating {
            try await gameRegistry.transitionGame(id: gameID, to: .gameUpdating)
        }
        let result: SophonInstallResult
        do {
            let mode: SophonInstallMode = isInstall ? .install :
                (task.context["confirmedMainland"] == "true" ? .updateConfirmedMainland : .update)
            result = try await installer.run(game: game.type, destination: access.url,
                                             mode: mode, holding: directoryLock) { [weak self] progress in
                guard let self else { return }
                await self.reportSophonProgress(progress, taskID: taskID)
            }
        } catch {
            // A forward update keeps its journal and mixed-version state until
            // it is resumed. Only a completed rollback can release this state.
            if !isInstall, !(await installer.hasPendingTransaction(destination: access.url)) {
                try await gameRegistry.transitionGame(id: gameID, to: .updateAvailable)
            }
            throw error
        }
        try await finishSophon(taskID: taskID, game: game, isInstall: isInstall, directory: access.url, result: result, installer: installer, holding: directoryLock)
    }

    private func reportSophonProgress(_ progress: SophonProgress, taskID: ScheduledTaskID) async {
        if progress.message == ScheduledTask.sophonCommitPhaseDescription,
           var task = tasks[taskID], task.phaseDescription != progress.message {
            // Publish the cancellation boundary before awaiting persistence.
            // Even if that write fails, a concurrent cancellation must not
            // interrupt a commit that has already begun.
            task.phaseDescription = progress.message
            task.progress = progress.fractionCompleted
            task.revision += 1
            tasks[taskID] = task
            emit(task, persistence: .memoryOnly)
        }
        let download = progress.bytesTotal.map {
            TaskDownloadProgress(bytesReceived: progress.bytesCompleted, totalBytes: $0, speed: 0)
        }
        try? await phase(taskID, progress.message, progress: progress.fractionCompleted, downloadProgress: download)
    }

    private func finishSophon(taskID: ScheduledTaskID, game: Game, isInstall: Bool,
                              directory: URL, result: SophonInstallResult, installer: SophonInstaller,
                              holding directoryLock: SophonDirectoryLock) async throws {
        if isInstall {
            do {
                _ = try await gameRegistry.locateGame(type: game.type, selectedURL: directory, installedVersion: result.version)
            } catch {
                throw SchedulerError.recoveryRequired("游戏文件已下载，但目录登记失败。请在主窗口定位该目录：\(error.localizedDescription)")
            }
        }
        if !isInstall {
            try await gameRegistry.updateGameVersion(id: game.id, version: result.version)
            try await gameRegistry.transitionGame(id: game.id, to: .installed)
            do {
                try await installer.finalizeCommittedUpdate(destination: directory, game: game.type, holding: directoryLock)
            } catch {
                // A retained receipt must continue to block launch and expose
                // the resume action if final cleanup could not be confirmed.
                try? await gameRegistry.transitionGame(id: game.id, to: .gameUpdating)
                throw error
            }
        } else {
            try await installer.finalizeCommittedInstall(destination: directory, game: game.type, holding: directoryLock)
        }
        let isRecovery = tasks[taskID]?.context["recoveryOnly"] == "true"
        try await finish(taskID, state: .completed, outcome: isInstall ? "gameInstalled" : (isRecovery ? "gameRecovered" : "gameUpdated"),
                         error: nil, recovery: nil, phase: isInstall ? "游戏安装已完成" : "游戏更新已完成")
    }

}
