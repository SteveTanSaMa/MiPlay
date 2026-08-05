//
//  LaunchOrchestrator.swift
//  MiPlay
//
//  Created by Steve Tan on 2026/7/7.
//

import Foundation

// Source: Architecture Design -> Service Contract -> LaunchOrchestrator
// Source: Architecture Design -> ADR 007 -> running requires process health confirmation

/// Coordinates preflight, Wine prefix preparation, process health confirmation and
/// the committed Game state transition. Process and file objects never escape here.
public actor LaunchOrchestrator {
    public enum LaunchError: Error, LocalizedError, Sendable {
        case validationFailed([PreLaunchValidator.ValidationError])
        case wineEnvironmentError(String)
        case processLaunchFailed(String)
        case processTimeout(String)
        case processExited(exitCode: Int32)
        case gameAlreadyRunning(String)
        case permissionDenied(String)
        case persistenceFailed(String)
        case recoveryRequired(String)
        case cancelled

        public var errorDescription: String? {
            switch self {
            case .validationFailed(let errors): return "启动校验失败: \(errors.map { $0.localizedDescription }.joined(separator: "; "))"
            case .wineEnvironmentError(let detail): return "Wine 环境错误: \(detail)"
            case .processLaunchFailed(let detail): return "进程启动失败: \(detail)"
            case .processTimeout(let detail): return "进程确认超时: \(detail)"
            case .processExited(let code): return "游戏进程异常退出: 退出码 \(code)"
            case .gameAlreadyRunning(let name): return "\(name) 已在运行"
            case .permissionDenied(let detail): return "游戏目录权限未确认: \(detail)"
            case .persistenceFailed(let detail): return "启动结果保存失败: \(detail)"
            case .recoveryRequired(let detail): return "启动清理未确认: \(detail)"
            case .cancelled: return "启动已取消，清理已确认"
            }
        }
    }

    public enum LaunchPhase: Sendable, Equatable {
        case validating
        case preparingWine
        case launching
        case confirming
        case completed
        case failed(String)
    }

    public enum LaunchResult: Sendable {
        case success(processId: UUID)
        case failure(LaunchError)
    }

    private let preLaunchValidator: PreLaunchValidator
    private let wineRuntimeProvider: WineRuntimeProvider
    private let wineVersionManager: WineVersionManager
    private let processManager: ProcessManager
    private let performanceOptionManager: PerformanceOptionManager
    private let gameRegistry: GameRegistry
    private let fileSystemRepository: GameFileSystemRepository
    private let logWriter: LogWriter

    private var currentLaunchProcessID: UUID?
    private var currentGameID: String?
    private var cancellationRequested = false
    private var activeSecurityScopes: [UUID: SecurityScopedAccess] = [:]

    public init(
        preLaunchValidator: PreLaunchValidator,
        wineRuntimeProvider: WineRuntimeProvider,
        wineVersionManager: WineVersionManager,
        processManager: ProcessManager,
        performanceOptionManager: PerformanceOptionManager,
        gameRegistry: GameRegistry,
        fileSystemRepository: GameFileSystemRepository? = nil,
        logWriter: LogWriter
    ) {
        self.preLaunchValidator = preLaunchValidator
        self.wineRuntimeProvider = wineRuntimeProvider
        self.wineVersionManager = wineVersionManager
        self.processManager = processManager
        self.performanceOptionManager = performanceOptionManager
        self.gameRegistry = gameRegistry
        self.fileSystemRepository = fileSystemRepository ?? GameFileSystemRepository()
        self.logWriter = logWriter
    }

    public func launch(game: Game) async -> LaunchResult {
        guard currentLaunchProcessID == nil, currentGameID == nil else {
            return .failure(.gameAlreadyRunning(game.type.displayName))
        }
        currentGameID = game.id
        cancellationRequested = false
        let operationID = UUID()
        defer {
            if currentLaunchProcessID == nil {
                currentGameID = nil
            }
        }

        await logWriter.info("开始启动游戏: \(game.type.displayName)", module: "LaunchOrchestrator")
        await logWriter.record(.init(
            level: .info,
            module: "LaunchOrchestrator",
            eventName: "launch.start",
            operationID: operationID,
            gameID: game.id,
            phase: "validation",
            result: "inProgress",
            messageCode: "launch.started"
        ))

        let validation = await preLaunchValidator.validate(game: game)
        guard validation.isPassed else {
            await logWriter.error("启动校验未通过", module: "LaunchOrchestrator")
            await logWriter.record(.init(
                level: .error,
                module: "LaunchOrchestrator",
                eventName: "launch.preflight",
                operationID: operationID,
                gameID: game.id,
                phase: "validation",
                result: "failed",
                errorCategory: "permissionDenied",
                messageCode: "launch.preflight_failed"
            ))
            return .failure(.validationFailed(validation.errors))
        }
        if cancellationRequested { return .failure(.cancelled) }

        guard let location = game.location, location.bookmarkData != nil else {
            return .failure(.permissionDenied("没有有效 security-scoped bookmark"))
        }

        do {
            try await gameRegistry.transitionGame(id: game.id, to: .launching)
        } catch {
            return .failure(.persistenceFailed(error.localizedDescription))
        }

        do {
            let scopedAccess = try fileSystemRepository.acquireSecurityScopedAccess(location)
            var processID: UUID?
            do {
                // Persist the refreshed bookmark before starting the child. The
                // scope remains held until the process exits or cleanup confirms
                // termination.
                if scopedAccess.resolvedLocation.requiresPersistenceUpdate(from: location) {
                    try await gameRegistry.updateResolvedLocation(
                        id: game.id,
                        location: scopedAccess.resolvedLocation
                    )
                }

                let resolvedURL = scopedAccess.url
                try Task.checkCancellation()
                guard !isCancellationRequested() else { throw LaunchError.cancelled }

                await logWriter.info("准备 Wine 环境: \(game.type.displayName)", module: "LaunchOrchestrator")
                guard let runtime = await wineVersionManager.validatedRuntime() else {
                    throw LaunchError.wineEnvironmentError("没有已验证的 Wine runtime")
                }
                let wineBinary = try await wineRuntimeProvider.load(runtime: runtime).path
                let prefix = try await wineRuntimeProvider.preparePrefix(for: game.id, runtime: runtime).path

                guard let executableURL = game.type.executableRelativePaths
                    .map({ resolvedURL.appendingPathComponent($0) })
                    .first(where: { FileManager.default.isExecutableFile(atPath: $0.path) || FileManager.default.fileExists(atPath: $0.path) }) else {
                    throw LaunchError.processLaunchFailed("未找到游戏可执行文件")
                }

                let options = await performanceOptionManager.getOptionsForLaunch(gameId: game.id)
                let arguments = [executableURL.path] + options.flatMap { $0.launchArguments ?? [] }
                var environment = [
                    "WINEPREFIX": prefix,
                    "WINEDLLOVERRIDES": "winemenubuilder.exe=d"
                ]
                for option in options {
                    if let values = option.environmentVariables {
                        for (key, value) in values { environment[key] = value }
                    }
                }

                await logWriter.info("执行 Wine binary 启动游戏进程", module: "LaunchOrchestrator")
                let launchedProcessID = try await processManager.launch(
                    executablePath: wineBinary,
                    arguments: arguments,
                    environment: environment,
                    workingDirectory: resolvedURL.path,
                    captureOutput: true
                )
                await logWriter.record(.init(
                    level: .info,
                    module: "LaunchOrchestrator",
                    eventName: "launch.process",
                    operationID: operationID,
                    gameID: game.id,
                    phase: "processCreated",
                    result: "started",
                    messageCode: "launch.process_created"
                ))
                processID = launchedProcessID
                setCurrentProcess(launchedProcessID)
                activeSecurityScopes[launchedProcessID] = scopedAccess
                do {
                    try await processManager.waitUntilRunning(processID: launchedProcessID, timeout: 10)
                } catch {
                    do {
                        _ = try await processManager.terminateAndWait(processID: launchedProcessID, force: true, timeout: 5)
                        activeSecurityScopes.removeValue(forKey: launchedProcessID)?.stop()
                    } catch {
                        // Keep the scope retained while termination is unconfirmed.
                        throw LaunchError.recoveryRequired(error.localizedDescription)
                    }
                    throw error
                }
            } catch {
                if let processID, activeSecurityScopes[processID] == nil { scopedAccess.stop() }
                throw error
            }

            guard let processID else {
                throw LaunchError.processLaunchFailed("启动进程标识缺失")
            }

            if cancellationRequested {
                try await cleanup(processID: processID, gameID: game.id)
                return .failure(.cancelled)
            }

            do {
                try await gameRegistry.recordLaunchConfirmed(id: game.id, date: Date())
            } catch {
                do { try await cleanup(processID: processID, gameID: game.id) }
                catch let cleanupError { return .failure(.recoveryRequired(cleanupError.localizedDescription)) }
                return .failure(.persistenceFailed(error.localizedDescription))
            }

            await logWriter.info("已确认游戏进程正在运行: \(game.type.displayName)", module: "LaunchOrchestrator")
            await logWriter.record(.init(
                level: .info,
                module: "LaunchOrchestrator",
                eventName: "launch.process",
                operationID: operationID,
                gameID: game.id,
                phase: "healthConfirmed",
                result: "completed",
                messageCode: "launch.running_confirmed"
            ))
            Task { [weak self] in await self?.monitorProcess(processID: processID, game: game) }
            return .success(processId: processID)
        } catch is CancellationError {
            return await cancelAfterFailure(gameID: game.id)
        } catch let error as LaunchError {
            return await failLaunch(gameID: game.id, error: error)
        } catch let error as ProcessManager.ProcessError {
            switch error {
            case .timeout(let detail): return await failLaunch(gameID: game.id, error: .processTimeout(detail))
            case .exitWithError(let code, _, _): return await failLaunch(gameID: game.id, error: .processExited(exitCode: code))
            case .permissionDenied(let detail): return await failLaunch(gameID: game.id, error: .permissionDenied(detail))
            default: return await failLaunch(gameID: game.id, error: .processLaunchFailed(error.localizedDescription))
            }
        } catch let error as GameFileSystemRepository.FileError {
            return await failLaunch(gameID: game.id, error: .permissionDenied(error.localizedDescription))
        } catch {
            return await failLaunch(gameID: game.id, error: .processLaunchFailed(error.localizedDescription))
        }
    }

    public func cancelLaunch() async {
        cancellationRequested = true
        guard let processID = currentLaunchProcessID else { return }
        do {
            try await cleanup(processID: processID, gameID: currentGameID)
            await logWriter.record(.init(
                level: .warning,
                module: "LaunchOrchestrator",
                eventName: "launch.cancel",
                gameID: currentGameID,
                phase: "cleanup",
                result: "cancelled",
                errorCategory: "userCancelled",
                messageCode: "launch.cancelled",
                fields: ["cleanupVerified": "true"]
            ))
        } catch {
            await logWriter.error("启动取消清理未确认: \(error.localizedDescription)", module: "LaunchOrchestrator")
            await logWriter.record(.init(
                level: .error,
                module: "LaunchOrchestrator",
                eventName: "launch.cancel",
                phase: "cleanup",
                result: "recoveryRequired",
                errorCategory: "cancellationUnconfirmed",
                messageCode: "launch.cancel_cleanup_failed",
                fields: ["cleanupVerified": "false"]
            ))
        }
    }

    private func isCancellationRequested() -> Bool { cancellationRequested }

    private func setCurrentProcess(_ processID: UUID) { currentLaunchProcessID = processID }

    // MARK: - Lifecycle helpers

    private func cleanup(processID: UUID, gameID: String?) async throws {
        do {
            _ = try await processManager.terminateAndWait(processID: processID, force: true, timeout: 8)
        } catch ProcessManager.ProcessError.processNotRunning {
            // The termination handler already finalized the process; this is clean.
        } catch {
            throw LaunchError.recoveryRequired(error.localizedDescription)
        }
        if let gameID {
            guard let currentGame = await gameRegistry.getGame(by: gameID) else {
                throw LaunchError.persistenceFailed("游戏不存在，无法提交清理状态")
            }
            if currentGame.state == .launching || currentGame.state == .running {
                do { try await gameRegistry.transitionGame(id: gameID, to: .installed) }
                catch { throw LaunchError.persistenceFailed(error.localizedDescription) }
            }
        }
        // The process exit and business-state commit are complete. Only now
        // release the scope and the per-game launch guard.
        activeSecurityScopes.removeValue(forKey: processID)?.stop()
        currentLaunchProcessID = nil
        currentGameID = nil
    }

    private func cancelAfterFailure(gameID: String) async -> LaunchResult {
        do {
            if let processID = currentLaunchProcessID { try await cleanup(processID: processID, gameID: gameID) }
            currentGameID = nil
            return .failure(.cancelled)
        } catch { return .failure(.recoveryRequired(error.localizedDescription)) }
    }

    private func failLaunch(gameID: String, error: LaunchError) async -> LaunchResult {
        // An unconfirmed cleanup must keep the launching state as a guard
        // against a second side effect. The process/scope facts remain owned
        // by this orchestrator until a later recovery operation can confirm
        // termination.
        if case .recoveryRequired = error {
            await logWriter.error("启动恢复未确认: \(error.localizedDescription)", module: "LaunchOrchestrator")
            return .failure(error)
        }

        currentLaunchProcessID = nil
        currentGameID = nil
        do {
            if (await gameRegistry.getGame(by: gameID))?.state == .launching {
                try await gameRegistry.transitionGame(id: gameID, to: .launchFailed)
            }
        } catch {
            await logWriter.error("启动失败事实无法保存: \(error.localizedDescription)", module: "LaunchOrchestrator")
            return .failure(.recoveryRequired(error.localizedDescription))
        }
        await logWriter.error("启动失败: \(error.localizedDescription)", module: "LaunchOrchestrator")
        await logWriter.record(.init(
            level: .error,
            module: "LaunchOrchestrator",
            eventName: "launch.terminal",
            gameID: gameID,
            phase: "terminal",
            result: "failed",
            errorCategory: "processStartFailed",
            messageCode: "launch.failed"
        ))
        return .failure(error)
    }

    private func monitorProcess(processID: UUID, game: Game) async {
        do {
            let result = try await processManager.waitForTermination(processID: processID)
            do {
                try await gameRegistry.commitProcessExit(
                    gameID: game.id,
                    processID: processID,
                    statusCode: result.statusCode,
                    terminatedBySignal: result.terminatedBySignal
                )
                // The business exit fact is committed. Release the scope and
                // lifecycle guard before any diagnostic await so observers
                // never see Installed with an outstanding bookmark lease.
                activeSecurityScopes.removeValue(forKey: processID)?.stop()
                if currentLaunchProcessID == processID { currentLaunchProcessID = nil }
                if currentGameID == game.id { currentGameID = nil }
                await logWriter.record(.init(
                    level: result.statusCode == 0 && !result.terminatedBySignal ? .info : .warning,
                    module: "LaunchOrchestrator",
                    eventName: "launch.exit",
                    operationID: processID,
                    gameID: game.id,
                    phase: "exitCommitted",
                    result: result.statusCode == 0 && !result.terminatedBySignal ? "completed" : "failed",
                    errorCategory: result.statusCode == 0 && !result.terminatedBySignal ? "none" : "processExitedAbnormally",
                    messageCode: result.statusCode == 0 && !result.terminatedBySignal ? "launch.exit_committed" : "launch.exit_abnormal",
                    fields: ["exitCode": String(result.statusCode), "signal": result.terminatedBySignal ? "1" : "0"]
                ))
            } catch {
                let detail = "进程已退出，但游戏状态提交失败: \(error.localizedDescription)"
                do {
                    _ = try await gameRegistry.recordProcessExitRecovery(
                        gameID: game.id,
                        processID: processID,
                        statusCode: result.statusCode,
                        terminatedBySignal: result.terminatedBySignal,
                        detail: detail
                    )
                } catch {
                    await logWriter.error("进程退出恢复事实无法保存: \(error.localizedDescription)", module: "LaunchOrchestrator")
                }
                // Keep the lifecycle guard and scoped bookmark until an
                // explicit recovery command commits the target state.
                await logWriter.error(detail, module: "LaunchOrchestrator")
                await logWriter.record(.init(
                    level: .error,
                    module: "LaunchOrchestrator",
                    eventName: "launch.exit",
                    operationID: processID,
                    gameID: game.id,
                    phase: "exitCommit",
                    result: "recoveryRequired",
                    errorCategory: "writeFailed",
                    messageCode: "launch.exit_commit_failed",
                    fields: ["exitCode": String(result.statusCode)]
                ))
                return
            }
            if result.statusCode == 0, !result.terminatedBySignal {
                await logWriter.info("游戏进程正常退出: \(game.type.displayName)", module: "LaunchOrchestrator")
            } else {
                await logWriter.error("游戏进程异常退出: \(game.type.displayName)", module: "LaunchOrchestrator")
            }
        } catch {
            await logWriter.error("游戏退出事实无法确认: \(error.localizedDescription)", module: "LaunchOrchestrator")
        }
    }

    /// Retries an exit-state commit only; it never relaunches the game.
    public func retryProcessExitRecovery(recordID: String) async throws {
        try await gameRegistry.retryProcessExitRecovery(recordID: recordID)
        if let processID = currentLaunchProcessID {
            activeSecurityScopes.removeValue(forKey: processID)?.stop()
        }
        currentLaunchProcessID = nil
        currentGameID = nil
    }
}
