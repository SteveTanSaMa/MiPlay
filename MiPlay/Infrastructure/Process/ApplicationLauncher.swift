//
//  ApplicationLauncher.swift
//  MiPlay
//

import AppKit
import Darwin
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
        /// No acceptance was published, so GameLauncher has not started Wine.
        case handshakeFailed(String)

        public var errorDescription: String? {
            switch self {
            case .notLaunched: return "LaunchServices 未能启动游戏应用"
            case .handshakeFailed(let reason): return "游戏启动器确认失败（尚未启动 Wine）: \(reason)"
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

    /// LaunchServices may report the Wine child's PID after application
    /// registration. Only the token-bound receipt identifies the helper that
    /// waits for wineserver and publishes the final status.
    nonisolated struct LaunchReceipt: Sendable, Equatable {
        let token: UUID
        let pid: pid_t
        let processGroupID: pid_t

        init?(contents: String, expectedToken: UUID) {
            let fields = contents.trimmingCharacters(in: .newlines).split(separator: ":", omittingEmptySubsequences: false)
            guard fields.count == 4, fields[0] == "v1",
                  let token = UUID(uuidString: String(fields[1])), token == expectedToken,
                  fields[2].allSatisfy({ $0.isASCII && $0.isNumber }),
                  fields[3].allSatisfy({ $0.isASCII && $0.isNumber }),
                  let pid = pid_t(fields[2]), pid > 1,
                  let group = pid_t(fields[3]), group == pid else { return nil }
            self.token = token
            self.pid = pid
            self.processGroupID = group
        }

        func matches(observedProcessGroup: pid_t?, hasTerminalStatus: Bool) -> Bool {
            if let observedProcessGroup { return observedProcessGroup == processGroupID }
            // An already-finished helper is only identifiable as a completed
            // session when it also left a valid terminal fact.
            return hasTerminalStatus
        }
    }

    @MainActor private final class OpenRequest {
        var error: (any Error)?
    }

    nonisolated static let runtimeVariableAllowlistKey = "MIPLAY_ALLOWED_RUNTIME_VARIABLES"

    /// NSWorkspace overlays its configuration onto inherited environment
    /// values. Record which controlled keys the prepared launch actually
    /// contains, so GameLauncher can unset the additional inherited keys.
    /// The relay is always present, including an empty list for LSFG/HUD off.
    nonisolated static func launchServicesEnvironment(_ prepared: [String: String]) throws -> [String: String] {
        let keys = prepared.keys.filter { key in
            key.hasPrefix("MTL_") || key.hasPrefix("METAL_") || key.hasPrefix("DYLD_") ||
            key.hasPrefix("LSFGM_") || key.hasPrefix("MIPLAY_LSFG_") || key == "DISABLE_LSFGM"
        }.sorted()
        for key in keys {
            let bytes = Array(key.utf8)
            guard !bytes.isEmpty, bytes.count <= 255,
                  bytes.allSatisfy({ (65...90).contains($0) || (97...122).contains($0) ||
                      (48...57).contains($0) || $0 == 95 }) else {
                throw ApplicationLaunchError.handshakeFailed("运行环境变量名无效")
            }
        }
        let allowlist = keys.joined(separator: ",")
        guard allowlist.utf8.count <= 16_384 else {
            throw ApplicationLaunchError.handshakeFailed("运行环境变量清单过长")
        }
        var environment = prepared
        environment[runtimeVariableAllowlistKey] = allowlist
        return environment
    }

    /// Opens the bundle and returns its verified supervising helper PID.
    @MainActor
    public func launch(
        bundleURL: URL,
        arguments: [String],
        environment: [String: String],
        logURL: URL,
        statusURL: URL
    ) async throws -> pid_t {
        try Task.checkCancellation()
        try Self.prepareSessionFiles(logURL: logURL, statusURL: statusURL)
        let token = UUID()
        let receiptURL = statusURL.deletingLastPathComponent()
            .appendingPathComponent(".miplay-launch-\(token.uuidString).pid")
        let acceptanceURL = URL(fileURLWithPath: receiptURL.path + ".accepted")
        var launchEnvironment = try Self.launchServicesEnvironment(environment)
        launchEnvironment["MIPLAY_LAUNCH_PID_FILE"] = receiptURL.path
        launchEnvironment["MIPLAY_LAUNCH_TOKEN"] = token.uuidString
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.arguments = arguments
        configuration.environment = launchEnvironment
        configuration.createsNewApplicationInstance = true
        configuration.activates = false
        let request = OpenRequest()
        let deadline = ContinuousClock.now + .seconds(10)
        // Do not await application registration: Wine may be responsible for
        // it, and the helper deliberately waits for our acceptance before fork.
        NSWorkspace.shared.openApplication(
            at: bundleURL,
            configuration: configuration,
            completionHandler: { application, error in
                let failure = error ?? (application == nil ? ApplicationLaunchError.notLaunched : nil)
                Task { @MainActor in request.error = failure }
            }
        )
        while ContinuousClock.now < deadline {
            try Task.checkCancellation()
            if let text = try Self.readLaunchReceipt(at: receiptURL) {
                guard let receipt = LaunchReceipt(contents: text, expectedToken: token) else {
                    throw ApplicationLaunchError.handshakeFailed("启动回执无效或不属于本次会话")
                }
                let group = getpgid(receipt.pid)
                let processExited = group == -1 && errno == ESRCH
                let terminal = Self.readExitStatus(at: statusURL) != nil
                guard receipt.matches(observedProcessGroup: processExited ? nil : group, hasTerminalStatus: terminal) else {
                    throw ApplicationLaunchError.handshakeFailed("启动器进程组与回执不一致")
                }
                if !processExited {
                    // Once this atomic write succeeds, ownership is handed to
                    // the caller. Never throw or honor cancellation after it.
                    // GameLauncher consumes and removes both handshake files.
                    try Self.publishLaunchAcceptance(token: token, at: acceptanceURL)
                }
                return receipt.pid
            }
            if let error = request.error { throw error }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw ApplicationLaunchError.handshakeFailed("等待启动器回执超时")
    }

    /// Receipts are tiny regular files atomically published by the helper.
    /// Never follow a stale link or read a pipe while waiting for a launch.
    nonisolated static func readLaunchReceipt(at url: URL) throws -> String? {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else {
            if errno == ENOENT { return nil }
            throw ApplicationLaunchError.handshakeFailed("无法读取启动回执")
        }
        defer { close(fd) }
        var metadata = stat()
        guard fstat(fd, &metadata) == 0,
              metadata.st_mode & S_IFMT == S_IFREG,
              metadata.st_uid == getuid(), metadata.st_size > 0, metadata.st_size <= 256 else {
            throw ApplicationLaunchError.handshakeFailed("启动回执不是有效的普通文件")
        }
        var buffer = [UInt8](repeating: 0, count: 256)
        let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        guard count == Int(metadata.st_size), let text = String(bytes: buffer.prefix(count), encoding: .utf8) else {
            throw ApplicationLaunchError.handshakeFailed("启动回执内容不完整")
        }
        return text
    }

    /// Rename is the final fallible operation: a thrown error always means
    /// acceptance was never published and the helper must not start Wine.
    nonisolated static func publishLaunchAcceptance(token: UUID, at url: URL) throws {
        let temporary = URL(fileURLWithPath: url.path + ".tmp")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw ApplicationLaunchError.handshakeFailed("无法创建启动确认") }
        var bytes = Array((token.uuidString + "\n").utf8)
        var offset = 0
        while offset < bytes.count {
            let count = bytes.withUnsafeMutableBytes { write(fd, $0.baseAddress!.advanced(by: offset), $0.count - offset) }
            if count < 0 && errno == EINTR { continue }
            if count <= 0 { break }
            offset += count
        }
        let closed = close(fd)
        guard offset == bytes.count, closed == 0 else {
            unlink(temporary.path)
            throw ApplicationLaunchError.handshakeFailed("无法写入启动确认")
        }
        guard rename(temporary.path, url.path) == 0 else {
            unlink(temporary.path)
            throw ApplicationLaunchError.handshakeFailed("无法发布启动确认")
        }
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
        guard let status = Self.readExitStatus(at: statusURL) else {
            return ExitResult(statusCode: -1, terminatedBySignal: false, output: output)
        }
        return ExitResult(statusCode: status.code, terminatedBySignal: status.signaled, output: output)
    }

    nonisolated private static func readExitStatus(at url: URL) -> (code: Int32, signaled: Bool)? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("exit:"), let value = Int32(trimmed.dropFirst("exit:".count)), (0...255).contains(value) {
            return (value, false)
        }
        if trimmed.hasPrefix("signal:"), let value = Int32(trimmed.dropFirst("signal:".count)), value > 0, value < NSIG {
            return (value, true)
        }
        return nil
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
