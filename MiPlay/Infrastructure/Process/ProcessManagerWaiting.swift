// ProcessManagerWaiting.swift
// MiPlay

import Foundation

// Source: Architecture Design -> ProcessManager -> waiting and termination control
extension ProcessManager {
    // MARK: - Waiting

    internal func waitForProcess(processID: UUID, timeout: TimeInterval?) async throws -> ProcessExitResult {
        guard activeProcesses[processID] != nil || completedProcesses[processID] != nil else {
            throw ProcessError.processNotRunning
        }

        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                if let completed = completedProcesses.removeValue(forKey: processID) {
                    continuation.resume(returning: completed)
                    return
                }
                guard activeProcesses[processID] != nil else {
                    continuation.resume(throwing: ProcessError.processNotRunning)
                    return
                }
                guard waiters[processID] == nil else {
                    continuation.resume(throwing: ProcessError.unsupportedOperation("同一进程只能等待一次"))
                    return
                }
                if Task.isCancelled {
                    cancellationRequestedProcesses.insert(processID)
                    waiters[processID] = continuation
                    requestCancellation(processID: processID)
                    return
                }
                waiters[processID] = continuation
                if let timeout, timeout > 0 {
                    timeoutTasks[processID] = Task { [weak self] in
                        do {
                            try await Task.sleep(nanoseconds: UInt64(timeout * 1_000_000_000))
                            await self?.requestTimeout(processID: processID, timeout: timeout)
                        } catch {
                            // The task is cancelled after normal process completion.
                        }
                    }
                }
            }
        }, onCancel: { [weak self] in
            Task { [weak self] in await self?.cancelWait(processID: processID) }
        })
    }

    public func waitForCompletion(processID: UUID, timeout: TimeInterval? = nil) async throws -> String {
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

    public func waitForTermination(processID: UUID, timeout: TimeInterval? = nil) async throws -> TerminationResult {
        let result = try await waitForProcess(processID: processID, timeout: timeout)
        return TerminationResult(statusCode: result.statusCode, terminatedBySignal: result.terminatedBySignal, output: result.output)
    }

    /// Confirms that the child is still alive. Process creation alone is not a health fact.
    public func waitUntilRunning(processID: UUID, timeout: TimeInterval = 10) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let record = activeProcesses[processID] {
                if record.process.isRunning { return }
                throw ProcessError.exitWithError(
                    exitCode: record.process.terminationStatus,
                    signal: record.process.terminationReason == .uncaughtSignal ? record.process.terminationStatus : nil,
                    output: record.output.value()
                )
            }
            if let completed = completedProcesses[processID] {
                throw ProcessError.exitWithError(
                    exitCode: completed.statusCode,
                    signal: completed.terminatedBySignal ? completed.statusCode : nil,
                    output: completed.output
                )
            }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        throw ProcessError.timeout("进程健康确认超时")
    }

    // MARK: - Monitoring

    public func isRunning(processID: UUID) -> Bool { activeProcesses[processID]?.process.isRunning == true }

    public func status(processID: UUID) -> ProcessStatus {
        guard let record = activeProcesses[processID] else { return .notRunning }
        if record.process.isRunning { return .running(pid: record.process.processIdentifier) }
        if record.process.terminationReason == .uncaughtSignal {
            return .terminated(signal: record.process.terminationStatus)
        }
        return .exited(code: record.process.terminationStatus)
    }

    // MARK: - Termination

    public func terminate(processID: UUID, force: Bool = false) throws {
        guard let record = activeProcesses[processID] else {
            if completedProcesses[processID] != nil { return }
            throw ProcessError.processNotRunning
        }
        guard record.process.isRunning else { return }
        record.process.terminate()
        if force {
            forcedTerminationDeadlines[processID] = Date().addingTimeInterval(2)
            Task { [weak self, weak record] in
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard let record, record.process.isRunning else { return }
                await self?.forceFinishIfNeeded(processID: processID)
            }
        }
    }

    public func terminateAndWait(processID: UUID, force: Bool = true, timeout: TimeInterval = 10) async throws -> TerminationResult {
        try terminate(processID: processID, force: force)
        return try await waitForTermination(processID: processID, timeout: timeout)
    }

    public func terminateAll(force: Bool = false) {
        for (id, record) in activeProcesses where record.process.isRunning {
            record.process.terminate()
            if force {
                forcedTerminationDeadlines[id] = Date().addingTimeInterval(2)
                forceFinishIfNeeded(processID: id)
            }
        }
    }

}
