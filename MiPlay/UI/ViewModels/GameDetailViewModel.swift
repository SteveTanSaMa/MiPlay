//
//  GameDetailViewModel.swift
//  MiPlay
//
//  Created by Steve Tan on 2026/7/7.
//

import SwiftUI

// Source: Architecture Design → ViewModel Layer → GameDetailViewModel
// Source: UI Design → View Responsibility → CompatibilitySolutionView, PerformanceOptionView

/// 游戏详情视图模型。管理详情窗口的兼容方案、性能选项、日志导出等状态。
@MainActor
@Observable
public final class GameDetailViewModel {
    // MARK: - Published State
    /// 目标游戏
    private(set) var game: Game?
    /// 可用兼容方案
    private(set) var availableSolutions: [CompatibilitySolution] = []
    /// 方案应用历史
    private(set) var solutionHistory: [SolutionApplication] = []
    /// 性能选项
    private(set) var performanceOptions: [PerformanceOption] = []
    /// 方案应用进度
    private(set) var solutionProgress: SolutionProgress?
    private(set) var activeTaskId: ScheduledTaskID?
    /// 错误信息
    private(set) var errorMessage: String?
    /// 日志内容
    private(set) var logContent: String?
    private(set) var logExportTask: ScheduledTask?

    /// 方案应用进度
    public struct SolutionProgress: Sendable {
        public let phase: String
        public let progress: Double?
    }

    // MARK: - Dependencies

    private let gameRegistry: GameRegistry
    private let solutionEngine: SolutionEngine
    private let performanceOptionManager: PerformanceOptionManager
    private let taskScheduler: TaskScheduler
    private var taskObservation: Task<Void, Never>?
    private var progressObservation: Task<Void, Never>?
    private var lastTaskEventSequence: UInt64 = 0

    public init(
        gameRegistry: GameRegistry,
        solutionEngine: SolutionEngine,
        performanceOptionManager: PerformanceOptionManager,
        taskScheduler: TaskScheduler
    ) {
        self.gameRegistry = gameRegistry
        self.solutionEngine = solutionEngine
        self.performanceOptionManager = performanceOptionManager
        self.taskScheduler = taskScheduler
    }

    // MARK: - Load

    /// 加载游戏详情
    public func loadGame(id: String) async {
        game = await gameRegistry.getGame(by: id)
        guard let game = game else { return }

        availableSolutions = await solutionEngine.getSolutions(for: game)
        solutionHistory = game.solutionApplications
        performanceOptions = performanceOptionManager.getOptions(for: game.id)
        await startTaskObservation()
    }

    // MARK: - Solutions

    /// 应用兼容方案
    public func applySolution(solutionId: String) async {
        guard let game = game else { return }

        solutionProgress = SolutionProgress(phase: "已提交，等待执行", progress: nil)

        do {
            activeTaskId = try await taskScheduler.enqueue(
                type: .solutionApply,
                gameId: game.id,
                context: ["solutionId": solutionId]
            )
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 回滚兼容方案
    public func rollbackSolution(applicationId: String) async {
        guard let game = game else { return }
        guard solutionHistory.contains(where: { $0.id == applicationId }) else { return }

        solutionProgress = SolutionProgress(phase: "已提交，等待恢复", progress: nil)

        do {
            activeTaskId = try await taskScheduler.enqueue(
                type: .solutionRevert,
                gameId: game.id,
                context: ["applicationId": applicationId]
            )
        } catch {
            solutionProgress = nil
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Performance Options

    /// 切换性能选项
    public func toggleOption(optionId: String, enabled: Bool) async {
        guard let game = game else { return }

        do {
            try await performanceOptionManager.setOption(
                gameId: game.id,
                optionId: optionId,
                enabled: enabled
            )
            await loadGame(id: game.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    /// 设置选项值
    public func setOptionValue(optionId: String, value: String) async {
        guard let game = game else { return }

        do {
            try await performanceOptionManager.setOptionValue(
                gameId: game.id,
                optionId: optionId,
                value: value
            )
            await loadGame(id: game.id)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    // MARK: - Logs

    /// 导出日志
    public func exportLogs() async {
        var exportTaskID: ScheduledTaskID?
        do {
            guard let gameID = game?.id else { return }
            let receipt = try await taskScheduler.enqueueReceipt(type: .logExport, gameId: gameID)
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
        guard let task = try? await taskScheduler.taskSnapshot(id: progress.taskId),
              (task.type == .solutionApply || task.type == .solutionRevert),
              task.gameId == game?.id else { return }
        guard task.state == .pending || task.state == .running else {
            await project(task)
            return
        }
        if activeTaskId == nil || activeTaskId == task.id {
            activeTaskId = task.id
            solutionProgress = SolutionProgress(phase: progress.phase, progress: progress.progress)
        }
    }

    private func consume(_ event: TaskEvent) async {
        guard event.snapshot.gameId == game?.id else { return }
        guard event.snapshot.type == .solutionApply || event.snapshot.type == .solutionRevert else { return }
        if lastTaskEventSequence != 0, event.sequence > lastTaskEventSequence + 1 {
            if let snapshot = try? await taskScheduler.taskSnapshot(id: event.snapshot.id) {
                await project(snapshot)
            }
        }
        lastTaskEventSequence = max(lastTaskEventSequence, event.sequence)
        await project(event.snapshot)
    }

    private func project(_ snapshot: ScheduledTask) async {
        guard snapshot.gameId == game?.id else { return }
        guard snapshot.type == .solutionApply || snapshot.type == .solutionRevert else { return }
        if activeTaskId == nil || activeTaskId == snapshot.id {
            activeTaskId = snapshot.id
            solutionProgress = SolutionProgress(
                phase: snapshot.phaseDescription,
                progress: snapshot.progress
            )
        }
        switch snapshot.state {
        case .completed:
            guard snapshot.outcome != nil else {
                errorMessage = "任务已结束，但结果无法确认"
                solutionProgress = nil
                return
            }
            solutionProgress = nil
            await loadGame(id: snapshot.gameId ?? "")
        case .failed:
            errorMessage = snapshot.error ?? "兼容方案未完成"
            solutionProgress = nil
        case .cancelled:
            guard snapshot.outcome == "cleanupVerified" else {
                errorMessage = snapshot.error ?? "取消清理未确认"
                solutionProgress = nil
                return
            }
            solutionProgress = nil
        case .pending, .running:
            break
        }
    }
}
