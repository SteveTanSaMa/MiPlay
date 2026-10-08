//
//  ProcessManager.swift
//  MiPlay
//

import Foundation
import Darwin

// Source: Architecture Design -> Service Contract -> ProcessManager
// Source: Architecture Design -> ADR 003 -> Actor isolation

/// Owns Process instances and exposes only Sendable process facts to Domain.
public actor ProcessManager {
    public enum ProcessError: Error, LocalizedError, Sendable {
        case executableNotFound(String)
        case launchFailed(String)
        case permissionDenied(String)
        case exitWithError(exitCode: Int32, signal: Int32?, output: String)
        case timeout(String)
        case processNotRunning
        case terminationUnconfirmed(String)
        case unsupportedOperation(String)

        public var errorDescription: String? {
            switch self {
            case .executableNotFound(let path): return "可执行文件未找到: \(path)"
            case .launchFailed(let detail): return "进程启动失败: \(detail)"
            case .permissionDenied(let detail): return "进程权限不足: \(detail)"
            case .exitWithError(let code, let signal, _):
                if let signal { return "进程异常退出: 退出码 \(code), 信号 \(signal)" }
                return "进程退出: 退出码 \(code)"
            case .timeout(let detail): return "进程超时: \(detail)"
            case .processNotRunning: return "进程未运行"
            case .terminationUnconfirmed(let detail): return "进程退出未确认: \(detail)"
            case .unsupportedOperation(let detail): return "不支持的操作: \(detail)"
            }
        }
    }

    public enum ProcessStatus: Sendable, Equatable {
        case running(pid: Int32)
        case exited(code: Int32)
        case terminated(signal: Int32)
        case notRunning
    }

    public struct ProcessLaunchSpec: Sendable {
        public let executablePath: String
        public let arguments: [String]
        public let environment: [String: String]?
        public let workingDirectory: String?
        public let captureOutput: Bool

        public init(
            executablePath: String,
            arguments: [String] = [],
            environment: [String: String]? = nil,
            workingDirectory: String? = nil,
            captureOutput: Bool = false
        ) {
            self.executablePath = executablePath
            self.arguments = arguments
            self.environment = environment
            self.workingDirectory = workingDirectory
            self.captureOutput = captureOutput
        }
    }

    public struct TerminationResult: Sendable, Equatable {
        public let statusCode: Int32
        public let terminatedBySignal: Bool
        public let output: String

        public init(statusCode: Int32, terminatedBySignal: Bool, output: String) {
            self.statusCode = statusCode
            self.terminatedBySignal = terminatedBySignal
            self.output = output
        }
    }

    internal struct ProcessExitResult: Sendable {
        let statusCode: Int32
        let terminatedBySignal: Bool
        let output: String
    }

    /// Pipe callbacks are not actor isolated. Only this lock protects byte collection.
    internal final class OutputCollector: @unchecked Sendable {
        internal let lock = NSLock()
        internal var stdout = Data()
        internal var stderr = Data()

        func append(_ data: Data, to stream: Stream) {
            guard !data.isEmpty else { return }
            lock.lock()
            if stream == .stdout { stdout.append(data) } else { stderr.append(data) }
            lock.unlock()
        }

        func value() -> String {
            lock.lock()
            let data = stdout + stderr
            lock.unlock()
            return String(decoding: data, as: UTF8.self)
        }

        enum Stream { case stdout, stderr }
    }

    internal final class RunningProcess: @unchecked Sendable {
        let process: Process
        let stdoutPipe: Pipe?
        let stderrPipe: Pipe?
        let output: OutputCollector

        init(process: Process, stdoutPipe: Pipe?, stderrPipe: Pipe?, output: OutputCollector) {
            self.process = process
            self.stdoutPipe = stdoutPipe
            self.stderrPipe = stderrPipe
            self.output = output
        }

        func stopReading() {
            stdoutPipe?.fileHandleForReading.readabilityHandler = nil
            stderrPipe?.fileHandleForReading.readabilityHandler = nil
        }

        /// The termination callback can race the last readability callback. Reading the
        /// remaining bytes after handlers are detached makes the returned fact complete.
        func drainRemainingOutput() {
            stopReading()
            if let stdoutPipe { output.append(stdoutPipe.fileHandleForReading.readDataToEndOfFile(), to: .stdout) }
            if let stderrPipe { output.append(stderrPipe.fileHandleForReading.readDataToEndOfFile(), to: .stderr) }
        }
    }

    internal var activeProcesses: [UUID: RunningProcess] = [:]
    internal var completedProcesses: [UUID: ProcessExitResult] = [:]
    internal var waiters: [UUID: CheckedContinuation<ProcessExitResult, Error>] = [:]
    internal var timeoutTasks: [UUID: Task<Void, Never>] = [:]
    internal var pendingWaitErrors: [UUID: ProcessError] = [:]
    internal var cancellationRequestedProcesses: Set<UUID> = []
    internal var forcedTerminationDeadlines: [UUID: Date] = [:]
    internal var forcedKillSent: Set<UUID> = []
    internal let logWriter: LogWriter?

    public init(logWriter: LogWriter? = nil) {
        self.logWriter = logWriter
    }

    // MARK: - Launch

    /// 子进程的基础环境：继承当前进程环境，但剔除只对开发/调试有意义的
    /// Metal 变量（`MTL_*` / `METAL_*`）。
    ///
    /// Xcode 运行 MiPlay 时会注入 `MTL_DEBUG_LAYER=1`（Metal API Validation）等
    /// 变量。Wine/DXMT 在开启校验的 Metal 下会命中调试层断言并直接终止游戏：
    /// 实测绝区零 `MTLDebugBlitCommandEncoder ... BC7_RGBAUnorm vs
    /// BC7_RGBAUnorm_sRGB` → abort，退出码 72。这些变量属于 MiPlay 自己的
    /// 开发环境，不能透传给游戏或 Wine 进程。
    ///
    /// 过滤只作用于继承来的键；调用方显式传入的覆盖值在过滤之后合并，
    /// 因此我们自己的 `MTL_HUD_*`（性能选项）不受影响。
    public nonisolated static func childEnvironment(overrides: [String: String]? = nil) -> [String: String] {
        filteredChildEnvironment(base: ProcessInfo.processInfo.environment, overrides: overrides)
    }

    /// 纯函数形式的环境过滤（可测试）：先剔除基环境里的开发调试 Metal 变量，
    /// 再合并调用方的覆盖值。
    public nonisolated static func filteredChildEnvironment(
        base: [String: String],
        overrides: [String: String]? = nil
    ) -> [String: String] {
        var environment = base
        for key in developmentOnlyMetalVariables(in: environment) {
            environment.removeValue(forKey: key)
        }
        if let overrides {
            for (key, value) in overrides { environment[key] = value }
        }
        return environment
    }

    /// 当前进程环境里只属于开发调试的 Metal 变量键（用于诊断记录）。
    public nonisolated static func developmentOnlyMetalVariables(in environment: [String: String]) -> [String] {
        environment.keys.filter { $0.hasPrefix("MTL_") || $0.hasPrefix("METAL_") }
    }

    public func launch(spec: ProcessLaunchSpec) throws -> UUID {
        guard FileManager.default.isExecutableFile(atPath: spec.executablePath) else {
            guard FileManager.default.fileExists(atPath: spec.executablePath) else {
                recordLaunchEvent(
                    eventName: "process.start",
                    result: "failed",
                    errorCategory: "processStartFailed",
                    messageCode: "process.executable_missing"
                )
                throw ProcessError.executableNotFound(spec.executablePath)
            }
            recordLaunchEvent(
                eventName: "process.start",
                result: "failed",
                errorCategory: "permissionDenied",
                messageCode: "process.executable_not_executable"
            )
            throw ProcessError.permissionDenied(spec.executablePath)
        }

        let process = Process()
        let executableURL = URL(fileURLWithPath: spec.executablePath)
        if Self.isPOSIXShellScript(at: executableURL) {
            // Sandboxed test and wrapper locations may not allow direct
            // execve of a writable script. Keep the interpreter fixed and
            // pass the script as data; native binaries use the normal path.
            process.executableURL = URL(fileURLWithPath: "/bin/sh")
            process.arguments = [spec.executablePath] + spec.arguments
        } else {
            process.executableURL = executableURL
            process.arguments = spec.arguments
        }

        // Merge requested values into the inherited environment. Assigning only the
        // caller's dictionary would remove PATH and other values Wine needs.
        process.environment = Self.childEnvironment(overrides: spec.environment)
        if let workingDirectory = spec.workingDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: workingDirectory, isDirectory: true)
        }

        var stdoutPipe: Pipe?
        var stderrPipe: Pipe?
        let collector = OutputCollector()
        if spec.captureOutput {
            let stdout = Pipe()
            let stderr = Pipe()
            stdoutPipe = stdout
            stderrPipe = stderr
            process.standardOutput = stdout
            process.standardError = stderr
            attachReader(to: stdout.fileHandleForReading, collector: collector, stream: .stdout)
            attachReader(to: stderr.fileHandleForReading, collector: collector, stream: .stderr)
        } else {
            stdoutPipe = nil
            stderrPipe = nil
        }

        let processID = UUID()
        let record = RunningProcess(process: process, stdoutPipe: stdoutPipe, stderrPipe: stderrPipe, output: collector)
        activeProcesses[processID] = record
        process.terminationHandler = { [weak self, weak record] process in
            let status = process.terminationStatus
            let signalled = process.terminationReason == .uncaughtSignal
            Task { [weak self, weak record] in
                await self?.finish(
                    processID: processID,
                    statusCode: status,
                    terminatedBySignal: signalled,
                    output: record?.output.value() ?? ""
                )
            }
        }

        do {
            try process.run()
        } catch let error as NSError {
            activeProcesses.removeValue(forKey: processID)?.stopReading()
            if error.domain == NSCocoaErrorDomain || error.domain == NSPOSIXErrorDomain,
               error.code == EACCES || error.code == EPERM {
                recordLaunchEvent(
                    operationID: processID,
                    eventName: "process.start",
                    result: "failed",
                    errorCategory: "permissionDenied",
                    messageCode: "process.start_denied"
                )
                throw ProcessError.permissionDenied(spec.executablePath)
            }
            recordLaunchEvent(
                operationID: processID,
                eventName: "process.start",
                result: "failed",
                errorCategory: "processStartFailed",
                messageCode: "process.start_failed"
            )
            throw ProcessError.launchFailed(error.localizedDescription)
        }
        recordLaunchEvent(
            operationID: processID,
            eventName: "process.created",
            result: "started",
            messageCode: "process.created"
        )
        return processID
    }

    /// Compatibility entry point for existing Domain callers.
    public func launch(
        executablePath: String,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        workingDirectory: String? = nil,
        captureOutput: Bool = false
    ) throws -> UUID {
        try launch(spec: ProcessLaunchSpec(
            executablePath: executablePath,
            arguments: arguments,
            environment: environment,
            workingDirectory: workingDirectory,
            captureOutput: captureOutput
        ))
    }

    private static func isPOSIXShellScript(at url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        return (try? handle.read(upToCount: 32))
            .map { String(decoding: $0, as: UTF8.self).hasPrefix("#!/bin/sh") } == true
    }

    public func launchAndWait(
        executablePath: String,
        arguments: [String] = [],
        environment: [String: String]? = nil,
        workingDirectory: String? = nil,
        timeout: TimeInterval? = nil
    ) async throws -> String {
        let processID = try launch(
            executablePath: executablePath,
            arguments: arguments,
            environment: environment,
            workingDirectory: workingDirectory,
            captureOutput: true
        )
        let result = try await waitForProcess(processID: processID, timeout: timeout)
        guard result.statusCode == 0, !result.terminatedBySignal else {
            throw ProcessError.exitWithError(
                exitCode: result.statusCode,
                signal: result.terminatedBySignal ? result.statusCode : nil,
                output: result.output
            )
        }
        return result.output
    }

}
