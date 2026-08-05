//
//  SolutionEngine.swift
//  MiPlay
//

import Foundation

// Source: Architecture Design -> Service Contract -> SolutionEngine
// Source: Architecture Design -> ADR 010 -> backup, apply, verify, rollback

/// Executes only solutions in the current release manifest. System-level changes
/// require a signed helper/XPC capability; without it the solution is unavailable.
public actor SolutionEngine {
    public enum SolutionError: Error, LocalizedError, Sendable {
        case solutionNotApplicable(gameId: String, solutionId: String)
        case solutionUnavailable(String)
        case backupFailed(String)
        case executionFailed(String)
        case rollbackFailed(String)
        case solutionNotFound(String)
        case invalidState(String)

        public var errorDescription: String? {
            switch self {
            case .solutionNotApplicable(let gameID, let solutionID): return "方案 \(solutionID) 不适用于游戏 \(gameID)"
            case .solutionUnavailable(let detail): return "兼容方案当前不可用: \(detail)"
            case .backupFailed(let detail): return "文件备份失败: \(detail)"
            case .executionFailed(let detail): return "方案执行失败: \(detail)"
            case .rollbackFailed(let detail): return "方案回滚失败: \(detail)"
            case .solutionNotFound(let id): return "方案未找到: \(id)"
            case .invalidState(let detail): return "状态异常: \(detail)"
            }
        }
    }

    public enum SolutionPhase: Sendable, Equatable {
        case checkingCapability
        case backingUp
        case applying
        case verifying
        case restoring
        case completed
        case failed(String)
    }

    private let fileSystemRepository: GameFileSystemRepository
    private let logWriter: LogWriter

    // These dependencies remain in the constructor for the existing composition
    // root. They are intentionally not used as a privilege escalation path.
    private let processManager: ProcessManager
    private let systemDetector: SystemEnvironmentDetector

    public init(
        fileSystemRepository: GameFileSystemRepository,
        processManager: ProcessManager,
        systemDetector: SystemEnvironmentDetector,
        logWriter: LogWriter
    ) {
        self.fileSystemRepository = fileSystemRepository
        self.processManager = processManager
        self.systemDetector = systemDetector
        self.logWriter = logWriter
    }

    public func getSolutions(for game: Game) -> [CompatibilitySolution] {
        BuiltInSolutions.solutions(for: game.type)
    }

    public func getSolution(id: String) -> CompatibilitySolution? {
        BuiltInSolutions.publishedSolutions().first { $0.id == id }
    }

    /// Current published solutions are system modifications. Since no signed helper
    /// is present in this target, fail before any side effect and never return Applied.
    public func applySolution(solutionId: String, for game: Game) async throws -> SolutionApplication {
        let operationID = UUID()
        await logWriter.record(.init(
            level: .info,
            module: "SolutionEngine",
            eventName: "solution.apply",
            operationID: operationID,
            gameID: game.id,
            phase: "capabilityCheck",
            result: "inProgress",
            messageCode: "solution.apply_started"
        ))
        guard let solution = getSolution(id: solutionId) else {
            await logWriter.record(.init(
                level: .error,
                module: "SolutionEngine",
                eventName: "solution.apply",
                operationID: operationID,
                gameID: game.id,
                phase: "capabilityCheck",
                result: "failed",
                errorCategory: "resourceNotFound",
                messageCode: "solution.not_found"
            ))
            throw SolutionError.solutionNotFound(solutionId)
        }
        guard solution.applicableGames.contains(game.type) else {
            throw SolutionError.solutionNotApplicable(gameId: game.id, solutionId: solutionId)
        }
        await logWriter.warning(
            "方案不可应用：缺少签名 SystemModificationGateway helper (\(solution.id))",
            module: "SolutionEngine"
        )
        await logWriter.record(.init(
            level: .warning,
            module: "SolutionEngine",
            eventName: "solution.apply",
            operationID: operationID,
            gameID: game.id,
            phase: "capabilityCheck",
            result: "unavailable",
            errorCategory: "resourceNotFound",
            messageCode: "solution.deferred_helper_unavailable"
        ))
        throw SolutionError.solutionUnavailable("需要已签名并获用户批准的系统修改 helper；当前版本未注册")
    }

    public func rollbackSolution(application: SolutionApplication, game: Game) async throws {
        guard application.state == .applied || application.state == .applying || application.state == .failed else {
            throw SolutionError.invalidState("方案状态不允许回滚: \(application.state.rawValue)")
        }
        await logWriter.record(.init(
            level: .error,
            module: "SolutionEngine",
            eventName: "solution.rollback",
            operationID: UUID(),
            gameID: game.id,
            phase: "capabilityCheck",
            result: "unavailable",
            errorCategory: "recoveryRequired",
            messageCode: "solution.rollback_helper_unavailable"
        ))
        throw SolutionError.rollbackFailed("系统修改 helper 未注册，无法确认恢复状态")
    }
}
