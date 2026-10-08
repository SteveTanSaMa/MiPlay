//
//  ApplicationLauncher.swift
//  MiPlay
//

import AppKit
import Foundation

// Source: 用户反馈 — 启动器与游戏在“强制退出”界面重名，无法区分
// 经 LaunchServices 启动具名游戏 bundle，使游戏进程链以游戏自己的名字注册。

/// Launches a named `.app` bundle through LaunchServices and observes it by
/// process identifier. Unlike ProcessManager's direct child processes, a
/// LaunchServices app is parented by launchd: its output and exit status come
/// from the files written by the GameLauncher entry in the launched bundle.
public final class ApplicationLauncher: Sendable {
    public enum ApplicationLaunchError: Error, LocalizedError, Sendable {
        case notLaunched

        public var errorDescription: String? {
            switch self {
            case .notLaunched: return "LaunchServices 未能启动游戏应用"
            }
        }
    }

    /// One exit fact for a LaunchServices-launched game.
    public struct ExitResult: Sendable {
        /// -1 表示未取得有效状态；不伪造 signal:0 或成功退出。
        public let statusCode: Int32
        public let terminatedBySignal: Bool
        public let output: String
    }

    nonisolated public init() {}

    /// Opens the bundle as its own application and returns the app pid.
    @MainActor
    public func launch(
        bundleURL: URL,
        arguments: [String],
        environment: [String: String],
        logURL: URL,
        statusURL: URL
    ) async throws -> pid_t {
        try Self.prepareSessionFiles(logURL: logURL, statusURL: statusURL)
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = arguments
        configuration.environment = environment
        configuration.createsNewApplicationInstance = true
        configuration.activates = false
        let application = try await NSWorkspace.shared.openApplication(
            at: bundleURL,
            configuration: configuration
        )
        let pid = application.processIdentifier
        guard pid > 0 else {
            throw ApplicationLaunchError.notLaunched
        }
        return pid
    }

    public nonisolated func isRunning(pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        if kill(pid, 0) == 0 { return true }
        return errno == EPERM
    }

    /// Polls the app process until it exits, then reads the exit fact and
    /// output written by the GameLauncher entry.
    public func waitForExit(
        pid: pid_t,
        logURL: URL,
        statusURL: URL,
        pollInterval: Duration = .milliseconds(500)
    ) async -> ExitResult {
        while isRunning(pid: pid) {
            if Task.isCancelled { break }
            try? await Task.sleep(for: pollInterval)
        }
        return exitResult(logURL: logURL, statusURL: statusURL)
    }

    /// Reads the exit fact without waiting. A missing or unreadable status
    /// file is an unknown exit (-1), not a fabricated signal or clean exit.
    public nonisolated func exitResult(logURL: URL, statusURL: URL) -> ExitResult {
        let output = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
        guard let text = try? String(contentsOf: statusURL, encoding: .utf8) else {
            return ExitResult(statusCode: -1, terminatedBySignal: false, output: output)
        }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("exit:"), let value = Int32(trimmed.dropFirst("exit:".count)), (0...255).contains(value) {
            return ExitResult(statusCode: value, terminatedBySignal: false, output: output)
        }
        if trimmed.hasPrefix("signal:"), let value = Int32(trimmed.dropFirst("signal:".count)), value > 0, value < NSIG {
            return ExitResult(statusCode: value, terminatedBySignal: true, output: output)
        }
        return ExitResult(statusCode: -1, terminatedBySignal: false, output: output)
    }

    /// Reset before LaunchServices starts the wrapper, including when the
    /// wrapper itself is killed before it can write a terminal status.
    nonisolated static func prepareSessionFiles(logURL: URL, statusURL: URL) throws {
        if FileManager.default.fileExists(atPath: statusURL.path) {
            try FileManager.default.removeItem(at: statusURL)
        }
        try Data().write(to: logURL, options: .atomic)
    }

    /// Terminates the game's process group. The GameLauncher entry is a
    /// process group leader, so both it and the Wine child are covered.
    public func terminate(
        pid: pid_t,
        force: Bool,
        timeout: Duration = .seconds(8)
    ) async throws {
        guard isRunning(pid: pid) else { return }
        let signal = force ? SIGKILL : SIGTERM
        if kill(-pid, signal) != 0 {
            _ = kill(pid, signal)
        }
        let deadline = ContinuousClock.now + timeout
        while isRunning(pid: pid) {
            if ContinuousClock.now >= deadline {
                _ = kill(-pid, SIGKILL)
                _ = kill(pid, SIGKILL)
                try? await Task.sleep(for: .milliseconds(200))
                return
            }
            try? await Task.sleep(for: .milliseconds(200))
        }
    }
}
