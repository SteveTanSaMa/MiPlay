// TaskSchedulerPersistence.swift
// MiPlay

import Foundation

// Source: Architecture Design -> ADR 008 -> persistence and recovery facts
extension TaskScheduler {
    // MARK: - Resource and persistence

    internal func resourceKeys(for task: ScheduledTask) -> Set<String> {
        var keys = Set<String>()
        if let gameID = task.gameId {
            switch task.type {
            case .gameInstall, .gameUpdate:
                keys.formUnion(["game:\(gameID):files", "game:\(gameID):lifecycle", "game:\(gameID):evidence"])
            case .gamePredownload:
                // Predownload only reads installed files and writes its own
                // cache. Allow launching/playing while preventing concurrent
                // installs, updates, verification, or another predownload.
                keys.formUnion(["game:\(gameID):files", "game:\(gameID):evidence"])
            case .solutionApply, .solutionRevert: keys.insert("game:\(gameID):files")
            // Read-only evidence scans (version/integrity) keep their own
            // domain: they must not hold the game's lifecycle key while a
            // multi-minute pkg_version validation runs, or the game's launch
            // and background-media tasks would wait behind them.
            case .versionCheck, .integrityVerification: keys.insert("game:\(gameID):evidence")
            // Media loading reads and writes only the app-owned media cache
            // (per-game directories) and never touches game files or lifecycle
            // state. Loads for different games run in parallel and overlap
            // their download/transcode phases; repeated loads for the same
            // game still deduplicate on the per-game key.
            case .backgroundMediaLoad: keys.insert("game:\(gameID):media")
            default: keys.insert("game:\(gameID):lifecycle")
            }
        }
        if task.type == .solutionApply || task.type == .solutionRevert { keys.insert("systemModification") }
        if task.type == .wineRuntimeSetup {
            keys.insert("wineRuntime")
            keys.insert("sharedWinePrefix")
        }
        if task.type == .wineCatalogQuery {
            let source = task.context["sourceID"] ?? "officialGitHub"
            let policy = task.context["policyRevision"] ?? "2026-08-03"
            keys.insert("wineCatalog:\(source):\(policy)")
        }
        if task.type == .logExport { keys.insert("logExport") }
        return keys
    }

    internal func resourcesAvailable(for task: ScheduledTask) -> Bool { resourceKeys(for: task).isDisjoint(with: activeResources) }
    internal func lockResources(for task: ScheduledTask) { activeResources.formUnion(resourceKeys(for: task)) }
    internal func unlockResources(for task: ScheduledTask) { activeResources.subtract(resourceKeys(for: task)) }

    internal func conflictingTask(for task: ScheduledTask) -> ScheduledTask? {
        tasks.values.first { existing in
            (existing.state == .pending || existing.state == .running) &&
            !resourceKeys(for: task).isDisjoint(with: resourceKeys(for: existing))
        }
    }

    internal func commit(_ task: ScheduledTask) async throws {
        try await persist(task)
        tasks[task.id] = task
        emit(task, persistence: .committed)
    }

    /// Persistence failure is itself a user-visible task fact. The scheduler
    /// keeps the conservative failed state in memory and marks the event so UI
    /// does not mistake it for a committed success.
    internal func publishPersistenceFailure(taskID: ScheduledTaskID, detail: String) async {
        guard var task = tasks[taskID] else { return }
        recoveryHeldTasks.insert(taskID)
        task.state = .failed
        task.endedAt = Date()
        task.phaseDescription = "任务结果无法持久化"
        task.progress = nil
        task.outcome = nil
        task.error = detail
        task.recovery = "请检查 AppData 恢复状态后重试"
        task.revision += 1
        tasks[taskID] = task
        downloadProgressDetails.removeValue(forKey: taskID)
        emit(task, persistence: .recoveryRequired)
        await recordTaskEvent(
            task,
            eventName: "task.recovery.required",
            phase: "recovering",
            result: "recoveryRequired",
            errorCategory: "writeFailed",
            messageCode: "task.recovery.required"
        )

        // The execution has ended, but its side-effect resource remains held
        // until retryPersistence commits and verifies the terminal fact.
        activeForeground = activeForeground == taskID ? nil : activeForeground
        activeBackground.remove(taskID)
        executionTasks.removeValue(forKey: taskID)
        wineSessionIDs.removeValue(forKey: taskID)
    }

    internal func recordTaskEvent(
        _ task: ScheduledTask,
        eventName: String,
        phase: String,
        result: String,
        errorCategory: String = "none",
        messageCode: String
    ) async {
        await logWriter.record(.init(
            level: result == "failed" || result == "recoveryRequired" ? .error : result == "cancelled" ? .warning : .info,
            module: "TaskScheduler",
            eventName: eventName,
            operationID: task.intentID,
            taskID: task.id.id,
            gameID: task.gameId,
            wineTag: task.context["tagName"],
            phase: phase,
            result: result,
            errorCategory: errorCategory,
            messageCode: messageCode
        ))
    }

    internal func persist(_ task: ScheduledTask) async throws {
        do {
            let record = PersistedTaskRecord(
                id: task.id.id,
                type: task.type.rawValue,
                gameID: task.gameId,
                status: task.state.rawValue,
                phase: task.phaseDescription,
                progress: task.progress,
                outcome: task.outcome,
                error: task.error,
                recovery: task.recovery,
                createdAt: task.createdAt,
                startedAt: task.startedAt,
                endedAt: task.endedAt,
                intentID: task.intentID,
                context: task.context,
                resourceKeys: Array(resourceKeys(for: task)).sorted()
            )
            try await persistenceStore.updateAppData { appData in
                if let index = appData.taskHistory.firstIndex(where: { $0.id == record.id }) {
                    appData.taskHistory[index] = record
                } else {
                    appData.taskHistory.append(record)
                }
            }
            let verified = try await persistenceStore.readAppData()
            guard let persisted = verified.taskHistory.first(where: { $0.id == record.id }),
                  persisted.status == record.status,
                  persisted.phase == record.phase,
                  persisted.error == record.error,
                  persisted.recovery == record.recovery,
                  (persisted.startedAt != nil) == (record.startedAt != nil),
                  (persisted.endedAt != nil) == (record.endedAt != nil) else {
                throw SchedulerError.persistenceFailed("任务终态写入后重读不一致")
            }
        } catch let error as SchedulerError {
            throw error
        } catch {
            throw SchedulerError.persistenceFailed(error.localizedDescription)
        }
    }

    internal func makeReceipt(_ task: ScheduledTask) -> TaskReceipt {
        TaskReceipt(
            taskID: task.id,
            intentID: task.intentID,
            eventCursor: sequence,
            resourceKeys: Array(resourceKeys(for: task)).sorted(),
            cancellationPolicy: task.cancellationPolicy,
            persistence: .committed
        )
    }

    internal func emit(_ task: ScheduledTask, persistence: TaskEvent.PersistenceMarker) {
        sequence += 1
        let event = TaskEvent(sequence: sequence, snapshot: task, persistence: persistence)
        eventContinuation?.yield(event)
        for continuation in eventSubscribers.values { continuation.yield(event) }
        let progress = TaskProgress(
            taskId: task.id,
            phase: task.phaseDescription,
            progress: task.progress,
            statusText: task.phaseDescription,
            download: downloadProgressDetails[task.id]
        )
        progressContinuation?.yield(progress)
        for continuation in progressSubscribers.values { continuation.yield(progress) }
    }

    internal func removeEventSubscriber(_ id: UUID) {
        eventSubscribers.removeValue(forKey: id)
    }

    internal func removeProgressSubscriber(_ id: UUID) {
        progressSubscribers.removeValue(forKey: id)
    }
}
