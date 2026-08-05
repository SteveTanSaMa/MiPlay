import Foundation

/// Manages subprocess execution with async/await.
/// Replaces Neutralino's `os.execCommand` and `os.spawnProcess`.
enum ProcessService {

    // MARK: - Errors

    enum ProcessError: LocalizedError {
        case nonZeroExit(code: Int32, stdout: String, stderr: String, command: String)

        var errorDescription: String? {
            switch self {
            case .nonZeroExit(let code, let stdout, let stderr, let command):
                return "Command exited with code \(code): \(command)\nStdout: \(stdout.prefix(500))\nStderr: \(stderr.prefix(500))"
            }
        }
    }

    // MARK: - Result

    struct ExecResult {
        let stdout: String
        let stderr: String
        let exitCode: Int32
    }

    // MARK: - Synchronous Execution

    /// Execute a command and wait for it to finish.
    /// - Parameters:
    ///   - command: Command segments to build into a shell command.
    ///   - environment: Optional additional environment variables.
    ///   - sudo: Whether to run with administrator privileges (via osascript).
    /// - Returns: The execution result.
    @discardableResult
    static func exec(
        _ segments: [CommandSegment],
        environment: [String: String]? = nil,
        sudo: Bool = false
    ) async throws -> ExecResult {
        let cmd = CommandBuilder.build(segments)
        let finalCmd = sudo ? buildSudoCommand(cmd) : cmd

        LogService.processLog("exec: \(finalCmd)")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", finalCmd]

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        if let env = environment {
            var envCopy = ProcessInfo.processInfo.environment
            for (key, value) in env {
                envCopy[key] = value
            }
            process.environment = envCopy
        }

        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { proc in
                let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
                let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
                let stdout = String(data: stdoutData, encoding: .utf8) ?? ""
                let stderr = String(data: stderrData, encoding: .utf8) ?? ""
                let exitCode = proc.terminationStatus

                if exitCode == 0 {
                    continuation.resume(returning: ExecResult(stdout: stdout, stderr: stderr, exitCode: exitCode))
                } else {
                    continuation.resume(throwing: ProcessError.nonZeroExit(
                        code: exitCode, stdout: stdout, stderr: stderr, command: finalCmd
                    ))
                }
            }
            do { try process.run() } catch { continuation.resume(throwing: error) }
        }
    }

    // MARK: - Async Spawn (streaming output)

    /// Start a process and stream its stdout line by line.
    /// - Returns: An async stream of stdout lines, and a task handle.
    static func spawn(
        _ segments: [CommandSegment],
        environment: [String: String]? = nil
    ) -> (stream: AsyncThrowingStream<String, Error>, process: Process) {
        let cmd = CommandBuilder.build(segments)
        LogService.processLog("spawn: \(cmd)")

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", cmd]

        let stdoutPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = Pipe()

        if let env = environment {
            var envCopy = ProcessInfo.processInfo.environment
            for (key, value) in env {
                envCopy[key] = value
            }
            process.environment = envCopy
        }

        let stream = AsyncThrowingStream<String, Error> { continuation in
            stdoutPipe.fileHandleForReading.readabilityHandler = { handle in
                let data = handle.availableData
                if data.isEmpty { return }
                if let line = String(data: data, encoding: .utf8) {
                    for part in line.components(separatedBy: "\n").filter({ !$0.isEmpty }) {
                        continuation.yield(part)
                    }
                }
            }

            process.terminationHandler = { proc in
                stdoutPipe.fileHandleForReading.readabilityHandler = nil
                if proc.terminationStatus == 0 {
                    continuation.finish()
                } else {
                    continuation.finish(throwing: ProcessError.nonZeroExit(
                        code: proc.terminationStatus,
                        stdout: "",
                        stderr: "",
                        command: cmd
                    ))
                }
            }
        }

        try? process.run()
        return (stream, process)
    }

    // MARK: - Sudo

    /// Wrap a command in osascript for sudo execution.
    static func buildSudoCommand(_ command: String) -> String {
        let escaped = command
            .replacingOccurrences(of: "\\", with: "\\\\\\\\")
            .replacingOccurrences(of: "\"", with: "\\\\\\\"")
        return CommandBuilder.build([
            .argument("osascript"),
            .argument("-e"),
            .raw("do shell script \"\(escaped)\" with administrator privileges")
        ])
    }
}
