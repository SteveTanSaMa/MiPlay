//
//  GameStateMachine.swift
//  MiPlay
//
//  Created by Steve Tan on 2026/7/7.
//

import Foundation

// Source: Architecture Design → Service Contract → GameStateMachine
// Source: UX Design → 状态转换流 → Per-Game 状态转换
// Source: Architecture Design → ADR 007 → 主动检测为主、事件驱动为辅

/// 游戏状态机。定义和执行业务状态转换规则。
public struct GameStateMachine: Sendable {
    public enum TransitionError: Error, LocalizedError {
        case illegalTransition(from: GameBusinessState, to: GameBusinessState)
        case invalidGame(String)

        public var errorDescription: String? {
            switch self {
            case .illegalTransition(let from, let to):
                return "非法状态转换: \(from.rawValue) → \(to.rawValue)"
            case .invalidGame(let id):
                return "无效的游戏: \(id)"
            }
        }
    }

    nonisolated public init() {}

    /// 验证状态转换是否合法
    nonisolated public func canTransition(from: GameBusinessState, to: GameBusinessState) -> Bool {
        switch (from, to) {
        // NotInstalled → Installed
        case (.notInstalled, .installed):
            return true

        // Installed → *
        case (.installed, .updateAvailable): return true
        case (.installed, .gameUpdating): return true
        case (.installed, .launching): return true
        case (.installed, .launchFailed): return true
        case (.installed, .notInstalled): return true

        // UpdateAvailable → *
        case (.updateAvailable, .gameUpdating): return true
        case (.updateAvailable, .installed): return true  // 用户忽略更新
        case (.updateAvailable, .notInstalled): return true

        // GameUpdating → *
        case (.gameUpdating, .installed): return true
        case (.gameUpdating, .updateAvailable): return true
        // Rolling back a first installation can leave no executable.
        case (.gameUpdating, .notInstalled): return true

        // Launching → *
        case (.launching, .running): return true
        case (.launching, .launchFailed): return true
        case (.launching, .installed): return true // 用户取消启动

        // Running → *
        case (.running, .installed): return true  // 正常退出
        case (.running, .updateAvailable): return true // 运行期间已验证新版本
        case (.running, .launchFailed): return true // 异常崩溃

        // LaunchFailed → *
        case (.launchFailed, .installed): return true
        case (.launchFailed, .updateAvailable): return true
        case (.launchFailed, .gameUpdating): return true
        case (.launchFailed, .notInstalled): return true
        case (.launchFailed, .launching): return true // 修复后重试

        default:
            return false
        }
    }

    /// 执行状态转换（验证 + 返回新状态）
    nonisolated public func transition(
        from currentState: GameBusinessState,
        to targetState: GameBusinessState
    ) throws -> GameBusinessState {
        guard canTransition(from: currentState, to: targetState) else {
            throw TransitionError.illegalTransition(from: currentState, to: targetState)
        }
        return targetState
    }

    /// 获取当前状态下的主要操作建议
    nonisolated public func suggestedAction(for state: GameBusinessState) -> String {
        switch state {
        case .notInstalled:
            return "安装"
        case .installed:
            return "启动"
        case .updateAvailable:
            return "更新"
        case .gameUpdating:
            return "更新中…"
        case .launching:
            return "启动中…"
        case .running:
            return "正在运行"
        case .launchFailed:
            return "启动"
        }
    }

    /// 获取状态描述文字
    nonisolated public func description(for state: GameBusinessState) -> String {
        switch state {
        case .notInstalled:
            return "尚未安装"
        case .installed:
            return "已就绪"
        case .updateAvailable:
            return "新版本可用"
        case .gameUpdating:
            return "正在更新…"
        case .launching:
            return "正在启动…"
        case .running:
            return "正在运行"
        case .launchFailed:
            return "启动失败"
        }
    }
}
