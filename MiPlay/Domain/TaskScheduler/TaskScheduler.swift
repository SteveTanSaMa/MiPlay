//
//  TaskScheduler.swift
//  MiPlay
//

import Foundation

// Source: Architecture Design -> Task Queue -> TaskScheduler
// Source: Architecture Design -> ADR 008 -> task facts are separate from business outcome
// Task contracts are kept in TaskSchedulerModels.swift; this file owns the actor.

/// Actor-owned task catalog with foreground serialization and background tasks.
public actor TaskScheduler {
    public enum SchedulerError: Error, LocalizedError, Sendable {
        case taskNotFound(ScheduledTaskID)
        case conflict(taskId: ScheduledTaskID, conflictingTaskId: ScheduledTaskID, reason: String)
        case notCancellable(ScheduledTaskID)
        case unsupported(ScheduledTaskType)
        case invalidRequest(String)
        case wineAssetHTTPFailure(statusCode: Int, detail: String)
        case persistenceFailed(String)
        case recoveryRequired(String)

        public var errorDescription: String? {
            switch self {
            case .taskNotFound(let id): return "任务未找到: \(id.id)"
            case .conflict(_, let other, let reason): return "任务冲突: \(reason) (\(other.id))"
            case .notCancellable(let id): return "任务不可取消: \(id.id)"
            case .unsupported(let type): return "任务类型当前未实现: \(type.rawValue)"
            case .invalidRequest(let detail): return "任务参数无效: \(detail)"
            case .wineAssetHTTPFailure(let statusCode, let detail):
                return "Wine 下载资源 HTTP 错误 \(statusCode): \(detail)"
            case .persistenceFailed(let detail): return "任务持久化失败: \(detail)"
            case .recoveryRequired(let detail): return "任务需要恢复: \(detail)"
            }
        }
    }

    public let progressStream: AsyncStream<TaskProgress>
    public let eventStream: AsyncStream<TaskEvent>

    internal var progressContinuation: AsyncStream<TaskProgress>.Continuation?
    internal var eventContinuation: AsyncStream<TaskEvent>.Continuation?
    internal var progressSubscribers: [UUID: AsyncStream<TaskProgress>.Continuation] = [:]
    internal var eventSubscribers: [UUID: AsyncStream<TaskEvent>.Continuation] = [:]
    internal var tasks: [ScheduledTaskID: ScheduledTask] = [:]
    /// 进度 tick 的落盘节流时间戳（见 `phase(_:_:progress:downloadProgress:)`）。
    internal var lastProgressPersistAt: [ScheduledTaskID: ContinuousClock.Instant] = [:]
    internal var queue: [ScheduledTaskID] = []
    internal var activeForeground: ScheduledTaskID?
    internal var activeBackground: Set<ScheduledTaskID> = []
    internal var activeResources: Set<String> = []
    /// Resources remain held after a terminal fact failed to persist. This is
    /// deliberately separate from active execution so unrelated work may run,
    /// while conflicting side effects remain blocked until recovery succeeds.
    internal var recoveryHeldTasks: Set<ScheduledTaskID> = []
    internal var executionTasks: [ScheduledTaskID: Task<Void, Never>] = [:]
    internal var wineSessionIDs: [ScheduledTaskID: UUID] = [:]
    internal var logExportResults: [ScheduledTaskID: String] = [:]
    internal var sequence: UInt64 = 0
    internal var initialized = false
    /// Download-only metrics are transient UI facts and are intentionally not
    /// persisted with the task record.
    internal var downloadProgressDetails: [ScheduledTaskID: TaskDownloadProgress] = [:]

    internal let launchOrchestrator: LaunchOrchestrator
    internal let solutionEngine: SolutionEngine
    internal let gameRegistry: GameRegistry
    internal let integrityVerifier: FileIntegrityVerifier
    internal let versionChecker: VersionChecker?
    internal let wineVersionManager: WineVersionManager?
    internal let backgroundMediaService: BackgroundMediaService?
    internal let persistenceStore: PersistenceStore
    internal let logWriter: LogWriter

    public init(
        launchOrchestrator: LaunchOrchestrator,
        solutionEngine: SolutionEngine,
        gameRegistry: GameRegistry,
        integrityVerifier: FileIntegrityVerifier,
        versionChecker: VersionChecker? = nil,
        persistenceStore: PersistenceStore? = nil,
        logWriter: LogWriter,
        wineVersionManager: WineVersionManager? = nil,
        backgroundMediaService: BackgroundMediaService? = nil
    ) {
        self.launchOrchestrator = launchOrchestrator
        self.solutionEngine = solutionEngine
        self.gameRegistry = gameRegistry
        self.integrityVerifier = integrityVerifier
        self.versionChecker = versionChecker
        self.wineVersionManager = wineVersionManager
        self.backgroundMediaService = backgroundMediaService
        self.persistenceStore = persistenceStore ?? PersistenceStore()
        self.logWriter = logWriter

        var progress: AsyncStream<TaskProgress>.Continuation!
        self.progressStream = AsyncStream { progress = $0 }
        self.progressContinuation = progress
        var events: AsyncStream<TaskEvent>.Continuation!
        self.eventStream = AsyncStream { events = $0 }
        self.eventContinuation = events
    }

    /// Creates an independent event subscription. Task events are domain facts
    /// and must be delivered to every ViewModel that has an open projection.
    public func makeEventStream() -> AsyncStream<TaskEvent> {
        let subscriptionID = UUID()
        var continuation: AsyncStream<TaskEvent>.Continuation!
        let stream = AsyncStream<TaskEvent> { continuation = $0 }
        continuation.onTermination = { @Sendable [weak self] _ in
            Task { await self?.removeEventSubscriber(subscriptionID) }
        }
        eventSubscribers[subscriptionID] = continuation
        return stream
    }

    /// Creates an independent progress subscription for one ViewModel.
    public func makeProgressStream() -> AsyncStream<TaskProgress> {
        let subscriptionID = UUID()
        var continuation: AsyncStream<TaskProgress>.Continuation!
        let stream = AsyncStream<TaskProgress> { continuation = $0 }
        continuation.onTermination = { @Sendable [weak self] _ in
            Task { await self?.removeProgressSubscriber(subscriptionID) }
        }
        progressSubscribers[subscriptionID] = continuation
        return stream
    }

    public func initialize() async {
        guard !initialized else { return }
        initialized = true
        do {
            var data = try await persistenceStore.readAppData()
            var interruptedTasks: [ScheduledTask] = []
            var historyChanged = false
            let history = data.taskHistory
            for record in history {
                guard let type = ScheduledTaskType(rawValue: record.type) else { continue }
                var task = ScheduledTask(
                    id: ScheduledTaskID(record.id),
                    intentID: record.intentID ?? UUID(),
                    type: type,
                    gameId: record.gameID,
                    context: record.context,
                    createdAt: record.createdAt
                )
                let wasInterrupted = record.status == ScheduledTaskState.pending.rawValue || record.status == ScheduledTaskState.running.rawValue
                task.state = wasInterrupted ? .failed : (ScheduledTaskState(rawValue: record.status) ?? .failed)
                task.phaseDescription = wasInterrupted ? "应用退出时任务被中断" : record.phase
                task.progress = wasInterrupted ? nil : record.progress
                task.outcome = wasInterrupted ? nil : record.outcome
                task.error = wasInterrupted ? (record.error ?? "应用退出时任务被中断") : record.error
                task.recovery = wasInterrupted ? (record.recovery ?? "请检查状态后手动重试") : record.recovery
                task.startedAt = record.startedAt
                task.endedAt = wasInterrupted ? (record.endedAt ?? Date()) : record.endedAt
                tasks[task.id] = task
                if wasInterrupted {
                    historyChanged = true
                    var repaired = record
                    repaired.status = ScheduledTaskState.failed.rawValue
                    repaired.phase = task.phaseDescription
                    repaired.progress = nil
                    repaired.outcome = nil
                    repaired.error = task.error
                    repaired.recovery = task.recovery
                    repaired.endedAt = task.endedAt
                    if let index = data.taskHistory.firstIndex(where: { $0.id == record.id }) {
                        data.taskHistory[index] = repaired
                    }
                    if type == .wineRuntimeSetup {
                        data.recoveryRecords.append(RecoveryRecord(
                            kind: "wineRuntimeSetup",
                            taskID: record.id,
                            target: WineVersionManager.fixedRuntimeTag,
                            phase: "interrupted",
                            detail: "应用退出时固定 Wine runtime setup 未完成，未自动重试",
                            payload: [
                                "runtimeIdentity": WineVersionManager.fixedRuntimeTag,
                                "prefixIdentity": WineVersionManager.sharedPrefixIdentity,
                                "stagingPath": record.context["stagingPath"] ?? ""
                            ]
                        ))
                    }
                    interruptedTasks.append(task)
                }
            }
            if historyChanged {
                do {
                    try await persistenceStore.writeAppData(data)
                    for task in interruptedTasks { emit(task, persistence: .committed) }
                } catch {
                    await logWriter.error("中断任务结果无法持久化: \(error.localizedDescription)", module: "TaskScheduler")
                    for task in interruptedTasks { emit(task, persistence: .recoveryRequired) }
                }
            }
        } catch {
            await logWriter.error("任务历史恢复失败: \(error.localizedDescription)", module: "TaskScheduler")
        }
    }

    @discardableResult
    public func enqueue(
        type: ScheduledTaskType,
        gameId: String?,
        context: [String: String] = [:],
        intentID: UUID = UUID()
    ) async throws -> ScheduledTaskID {
        return (try await enqueueReceipt(type: type, gameId: gameId, context: context, intentID: intentID)).taskID
    }

    @discardableResult
    public func enqueueReceipt(
        type: ScheduledTaskType,
        gameId: String?,
        context: [String: String] = [:],
        intentID: UUID = UUID()
    ) async throws -> TaskReceipt {
        await initialize()
        guard type == .gameLaunch || type == .solutionApply || type == .solutionRevert || type == .versionCheck || type == .integrityVerification || type == .wineRuntimeSetup || type == .backgroundMediaLoad || type == .logExport else {
            throw SchedulerError.unsupported(type)
        }
        if type == .wineRuntimeSetup || type == .logExport {
            guard gameId == nil else {
                throw SchedulerError.invalidRequest("全局任务不应包含 Game ID")
            }
        } else {
            guard gameId != nil else {
                throw SchedulerError.invalidRequest("任务缺少 Game ID")
            }
        }
        if type == .gameLaunch, let gameId {
            let pendingRecovery = await gameRegistry.pendingRecoveryRecords(gameID: gameId)
            if let recovery = pendingRecovery.first {
                throw SchedulerError.recoveryRequired(
                    "游戏存在未完成恢复事实: \(recovery.detail)"
                )
            }
        }
        if type == .gameLaunch {
            if let existing = tasks.values.first(where: {
                ($0.state == .pending || $0.state == .running)
                    && resourceKeys(for: $0).contains("sharedWinePrefix")
            }) {
                throw SchedulerError.conflict(
                    taskId: ScheduledTaskID(),
                    conflictingTaskId: existing.id,
                    reason: "sharedWinePrefix 正在被占用"
                )
            }
        }
        if type == .wineRuntimeSetup {
            guard wineVersionManager != nil else { throw SchedulerError.invalidRequest("Wine 版本管理器未配置") }
            if let runtimeIdentity = context["runtimeIdentity"],
               runtimeIdentity != WineVersionManager.fixedRuntimeTag {
                throw SchedulerError.invalidRequest("Wine runtime 不是当前固定目标")
            }
            if let existing = tasks.values.first(where: {
                $0.type == .wineRuntimeSetup &&
                ($0.state == .pending || $0.state == .running)
            }) {
                if existing.context["runtimeIdentity"].map({ $0 == WineVersionManager.fixedRuntimeTag }) ?? true {
                    return makeReceipt(existing)
                }
                throw SchedulerError.conflict(
                    taskId: ScheduledTaskID(),
                    conflictingTaskId: existing.id,
                    reason: "wineRuntime/sharedWinePrefix 正在处理固定 setup"
                )
            }
            do {
                let data = try await persistenceStore.readAppData()
                let guards = try await persistenceStore.readRecoveryGuards()
                let blocked = data.recoveryRecords.contains {
                    $0.resolvedAt == nil
                        && ($0.target == WineVersionManager.fixedRuntimeTag
                            || $0.target == WineVersionManager.sharedPrefixIdentity)
                } || guards.contains {
                    $0.resolvedAt == nil
                        && ($0.target == WineVersionManager.fixedRuntimeTag
                            || $0.target == WineVersionManager.sharedPrefixIdentity)
                }
                if blocked {
                    throw SchedulerError.recoveryRequired("固定 Wine runtime/shared prefix 存在未完成恢复事实")
                }
            } catch let error as SchedulerError {
                throw error
            } catch {
                throw SchedulerError.recoveryRequired("无法读取固定 Wine 恢复状态: \(error.localizedDescription)")
            }
        }
        if type == .solutionApply || type == .solutionRevert, context["solutionId"] == nil && context["applicationId"] == nil {
            throw SchedulerError.invalidRequest("方案任务缺少方案 ID")
        }
        if type == .solutionApply,
           let solutionID = context["solutionId"],
           await solutionEngine.getSolution(id: solutionID) == nil {
            throw SchedulerError.invalidRequest("方案当前为 Deferred 或不在发布清单中")
        }

        if let existing = tasks.values.first(where: {
            $0.intentID == intentID && ($0.state == .pending || $0.state == .running)
        }) {
            return makeReceipt(existing)
        }

        let task = ScheduledTask(id: ScheduledTaskID(), intentID: intentID, type: type, gameId: gameId, context: context)
        try await persist(task)
        tasks[task.id] = task
        queue.append(task.id)
        emit(task, persistence: .committed)
        await recordTaskEvent(
            task,
            eventName: "task.accepted",
            phase: "queued",
            result: "accepted",
            messageCode: "task.accepted"
        )
        schedule()
        return makeReceipt(task)
    }

    public func logExportResult(for taskID: ScheduledTaskID) -> String? {
        logExportResults[taskID]
    }

    public func cancel(taskId: ScheduledTaskID) async throws {
        await initialize()
        guard var task = tasks[taskId] else { throw SchedulerError.taskNotFound(taskId) }
        guard task.state == .pending || task.state == .running else { throw SchedulerError.taskNotFound(taskId) }
        guard task.cancellationPolicy != .notCancellable else { throw SchedulerError.notCancellable(taskId) }

        if task.state == .pending {
            queue.removeAll { $0 == taskId }
            task.state = .cancelled
            task.endedAt = Date()
            task.outcome = "cancelledBeforeStart"
            task.phaseDescription = "已取消，未产生副作用"
            try await commit(task)
            await recordTaskEvent(
                task,
                eventName: "task.cancelled",
                phase: "queued",
                result: "cancelled",
                errorCategory: "userCancelled",
                messageCode: "task.cancelled"
            )
            schedule()
            return
        }

        if task.type == .gameLaunch {
            // Let LaunchOrchestrator return its concrete cancellation/recovery
            // result so cleanup failure cannot be reported as cancelled.
            await launchOrchestrator.cancelLaunch()
        } else if task.type == .wineRuntimeSetup {
            if let sessionID = wineSessionIDs[taskId] {
                await wineVersionManager?.cancelDownload(taskID: sessionID)
            }
            // The setup task can still be fetching catalog metadata before its
            // downloader session is registered. Cancel the scheduler execution
            // as well so cancellation covers the complete setup lifecycle.
            executionTasks[taskId]?.cancel()
        } else {
            executionTasks[taskId]?.cancel()
        }
        task.phaseDescription = "正在清理"
        task.revision += 1
        tasks[taskId] = task
        emit(task, persistence: .memoryOnly)
        await recordTaskEvent(
            task,
            eventName: "task.cancel.requested",
            phase: "cancelling",
            result: "inProgress",
            messageCode: "task.cancel.requested"
        )
    }

    /// Commits a previously in-memory terminal result after a persistence
    /// outage. It never replays the side effect; only the durable task fact is
    /// retried. Conflicting resource keys are released after write/read-back
    /// verification succeeds.
    @discardableResult
    public func retryPersistence(taskId: ScheduledTaskID) async throws -> ScheduledTask {
        await initialize()
        guard recoveryHeldTasks.contains(taskId), var task = tasks[taskId] else {
            throw SchedulerError.recoveryRequired("没有可重试的任务持久化恢复事实")
        }
        guard task.state == .failed else {
            throw SchedulerError.recoveryRequired("任务当前不是待恢复的失败状态")
        }

        task.recovery = nil
        task.phaseDescription = "结果恢复已提交"
        task.revision += 1
        do {
            try await commit(task)
        } catch {
            task.recovery = "结果持久化仍然失败: \(error.localizedDescription)"
            tasks[taskId] = task
            emit(task, persistence: .recoveryRequired)
            throw error
        }

        recoveryHeldTasks.remove(taskId)
        unlockResources(for: task)
        schedule()
        return task
    }

    public func taskSnapshot(id: ScheduledTaskID) async throws -> ScheduledTask {
        await initialize()
        guard let task = tasks[id] else { throw SchedulerError.taskNotFound(id) }
        return task
    }

    public func allTaskSnapshots() async -> [ScheduledTask] {
        await initialize()
        return tasks.values.sorted { $0.createdAt < $1.createdAt }
    }

}
