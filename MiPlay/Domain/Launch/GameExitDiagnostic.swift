import Foundation
import Darwin

/// 根据本次退出事实生成诊断；信号只能说明终止机制，不能证明发起方。
enum GameExitDiagnostic {
    nonisolated static func summary(
        statusCode: Int32,
        terminatedBySignal: Bool,
        output: String
    ) -> String {
        if statusCode < 0 || (terminatedBySignal && statusCode == 0) {
            return "游戏进程已结束，但未取得有效退出状态，无法区分闪退与外部强制退出"
        }
        if terminatedBySignal {
            switch statusCode {
            case SIGKILL:
                return "游戏进程被强制终止（SIGKILL）；可能是手动强制退出或系统终止，无法确认发起方"
            case SIGTERM, SIGINT:
                return "游戏进程收到终止信号（\(signalName(statusCode))）；无法确认是否由用户发起"
            case SIGABRT, SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGFPE:
                return "游戏进程因崩溃类信号结束（\(signalName(statusCode))）；具体原因请查看本次启动日志"
            default:
                return "游戏进程因信号 \(statusCode) 结束；退出原因尚未确认"
            }
        }
        if statusCode == 0 { return "" }
        let prefix = "游戏进程异常退出（退出码 \(statusCode)）"
        if hasDriverLoadFailure(output) {
            return "\(prefix)；本次日志显示反作弊驱动加载失败，可能存在 Wine 兼容问题"
        }
        return "\(prefix)；具体原因请查看本次启动日志"
    }

    /// 必须在同一条日志中同时有驱动名、加载上下文和失败证据。
    /// 仅出现文件名、历史错误或一般 Wine err 行都不足以确认反作弊原因。
    nonisolated private static func hasDriverLoadFailure(_ output: String) -> Bool {
        output.lowercased().split(separator: "\n").contains { line in
            let driver = line.contains("wdfldr.sys") || line.contains("hoyokprotect.sys")
            let loading = line.contains("import_dll") || line.contains("library") || line.contains("load")
            let failure = line.contains("not found") || line.contains("failed")
                || line.contains("cannot") || line.contains("could not")
            return driver && loading && failure
        }
    }

    nonisolated private static func signalName(_ signal: Int32) -> String {
        switch signal {
        case SIGTERM: return "SIGTERM"
        case SIGINT: return "SIGINT"
        case SIGABRT: return "SIGABRT"
        case SIGSEGV: return "SIGSEGV"
        case SIGBUS: return "SIGBUS"
        case SIGILL: return "SIGILL"
        case SIGTRAP: return "SIGTRAP"
        case SIGFPE: return "SIGFPE"
        default: return String(signal)
        }
    }
}
