// ProcessManagerCompletion.swift
// MiPlay

import Foundation

// Source: Architecture Design -> ProcessManager -> completion and output collection
extension ProcessManager {
    // MARK: - Process discovery

    public func findProcessByName(_ name: String) async throws -> [Int32] {
        do {
            let output = try await launchAndWait(executablePath: "/usr/bin/pgrep", arguments: ["-f", name], timeout: 5)
            return output.split(whereSeparator: \.isNewline).compactMap { Int32($0) }
        } catch ProcessError.exitWithError(let code, _, _) where code == 1 {
            return []
        }
    }

    public func isProcessRunning(name: String) async throws -> Bool {
        try await !findProcessByName(name).isEmpty
    }

    // MARK: - Completion state

    internal func finish(processID: UUID, statusCode: Int32, terminatedBySignal: Bool, output: String) {
        guard let record = activeProcesses[processID] else { return }
        record.drainRemainingOutput()
        complete(
            processID: processID,
            result: ProcessExitResult(
                statusCode: statusCode,
                terminatedBySignal: terminatedBySignal,
                output: record.output.value().isEmpty ? output : record.output.value()
            )
        )
    }

    internal func complete(processID: UUID, result: ProcessExitResult) {
        guard let record = activeProcesses.removeValue(forKey: processID) else { return }
        record.stopReading()
        timeoutTasks.removeValue(forKey: processID)?.cancel()
        forcedTerminationDeadlines.removeValue(forKey: processID)
        forcedKillSent.remove(processID)
        let wasCancellationRequested = cancellationRequestedProcesses.remove(processID) != nil
        let waitError = pendingWaitErrors.removeValue(forKey: processID)
        let logResult: String
        let logError: String
        let logMessage: String
        if wasCancellationRequested {
            logResult = "cancelled"
            logError = "userCancelled"
            logMessage = "process.termination_cancelled"
        } else if let waitError {
            logResult = "failed"
            let metadata = processErrorMetadata(waitError)
            logError = metadata.category
            logMessage = metadata.messageCode
        } else if result.terminatedBySignal || result.statusCode != 0 {
            logResult = "failed"
            logError = "processExitedAbnormally"
            logMessage = "process.termination_abnormal"
        } else {
            logResult = "completed"
            logError = "none"
            logMessage = "process.termination_observed"
        }
        if let logWriter {
            Task { await logWriter.record(.init(
                level: logResult == "completed" ? .info : .warning,
                module: "ProcessManager",
                eventName: "process.termination",
                operationID: processID,
                phase: "terminationObserved",
                result: logResult,
                errorCategory: logError,
                messageCode: logMessage,
                fields: [
                    "exitCode": String(result.statusCode),
                    "signal": result.terminatedBySignal ? String(result.statusCode) : "0"
                ]
            )) }
        }
        if let waiter = waiters.removeValue(forKey: processID) {
            if wasCancellationRequested { waiter.resume(throwing: CancellationError()) }
            else if let waitError { waiter.resume(throwing: waitError) }
            else { waiter.resume(returning: result) }
        } else {
            completedProcesses[processID] = result
        }
    }

    internal func requestTimeout(processID: UUID, timeout: TimeInterval) {
        guard let record = activeProcesses[processID], waiters[processID] != nil else { return }
        pendingWaitErrors[processID] = .timeout("进程执行超时 (\(timeout)秒)")
        if let logWriter {
            Task { await logWriter.record(.init(
                level: .error,
                module: "ProcessManager",
                eventName: "process.timeout",
                operationID: processID,
                phase: "timeout",
                result: "failed",
                errorCategory: "processTimedOut",
                messageCode: "process.timeout",
                fields: ["timeoutSeconds": String(timeout)]
            )) }
        }
        if record.process.isRunning { record.process.terminate() }
        forcedTerminationDeadlines[processID] = Date().addingTimeInterval(2)
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            await self?.forceFinishIfNeeded(processID: processID)
        }
    }

    internal func forceFinishIfNeeded(processID: UUID) {
        guard let record = activeProcesses[processID] else { return }
        guard record.process.isRunning else {
            record.drainRemainingOutput()
            complete(
                processID: processID,
                result: ProcessExitResult(
                    statusCode: record.process.terminationStatus,
                    terminatedBySignal: record.process.terminationReason == .uncaughtSignal,
                    output: record.output.value()
                )
            )
            return
        }

        let deadline = forcedTerminationDeadlines[processID] ?? Date()
        if !forcedKillSent.contains(processID) {
            guard Date() >= deadline else {
                scheduleForcedTerminationPoll(processID: processID)
                return
            }
            kill(record.process.processIdentifier, SIGKILL)
            forcedKillSent.insert(processID)
            forcedTerminationDeadlines[processID] = Date().addingTimeInterval(2)
            scheduleForcedTerminationPoll(processID: processID)
            return
        }

        guard Date() >= deadline else {
            scheduleForcedTerminationPoll(processID: processID)
            return
        }

        failWaiter(
            processID: processID,
            error: .terminationUnconfirmed("SIGKILL 后仍无法确认进程已退出")
        )
    }

    internal func scheduleForcedTerminationPoll(processID: UUID) {
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 50_000_000)
            await self?.forceFinishIfNeeded(processID: processID)
        }
    }

    internal func failWaiter(processID: UUID, error: ProcessError) {
        timeoutTasks.removeValue(forKey: processID)?.cancel()
        pendingWaitErrors.removeValue(forKey: processID)
        cancellationRequestedProcesses.remove(processID)
        guard let waiter = waiters.removeValue(forKey: processID) else { return }
        waiter.resume(throwing: error)
    }

    internal func processErrorMetadata(_ error: ProcessError) -> (category: String, messageCode: String) {
        switch error {
        case .timeout: return ("processTimedOut", "process.timeout")
        case .terminationUnconfirmed: return ("terminationUnconfirmed", "process.termination_unconfirmed")
        case .permissionDenied: return ("permissionDenied", "process.permission_denied")
        case .executableNotFound, .launchFailed: return ("processStartFailed", "process.start_failed")
        case .exitWithError: return ("processExitedAbnormally", "process.termination_abnormal")
        case .processNotRunning, .unsupportedOperation: return ("unknown", "process.wait_failed")
        }
    }

    internal func recordLaunchEvent(
        operationID: UUID = UUID(),
        eventName: String,
        result: String,
        errorCategory: String = "none",
        messageCode: String
    ) {
        guard let logWriter else { return }
        Task { await logWriter.record(.init(
            level: result == "failed" ? .error : .info,
            module: "ProcessManager",
            eventName: eventName,
            operationID: operationID,
            phase: result == "failed" ? "start" : "created",
            result: result,
            errorCategory: errorCategory,
            messageCode: messageCode
        )) }
    }

    internal func cancelWait(processID: UUID) {
        guard activeProcesses[processID] != nil || completedProcesses[processID] != nil else { return }
        if completedProcesses.removeValue(forKey: processID) != nil {
            if let waiter = waiters.removeValue(forKey: processID) {
                waiter.resume(throwing: CancellationError())
            }
            return
        }

        // Cancellation is not complete until the termination handler has
        // confirmed process exit and pipe EOF. Keeping the continuation here
        // makes that fact a single completion path instead of returning after
        // merely sending SIGTERM.
        cancellationRequestedProcesses.insert(processID)
        timeoutTasks.removeValue(forKey: processID)?.cancel()
        requestCancellation(processID: processID)
    }

    internal func requestCancellation(processID: UUID) {
        guard let record = activeProcesses[processID] else { return }
        if record.process.isRunning { record.process.terminate() }
        forcedTerminationDeadlines[processID] = Date().addingTimeInterval(2)
        scheduleForcedTerminationPoll(processID: processID)
    }

    internal func attachReader(to handle: FileHandle, collector: OutputCollector, stream: OutputCollector.Stream) {
        handle.readabilityHandler = { handle in
            let data = handle.availableData
            if data.isEmpty { handle.readabilityHandler = nil }
            else { collector.append(data, to: stream) }
        }
    }
}
