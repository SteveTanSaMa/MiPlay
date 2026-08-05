// Source: Implementation maintenance split -> process lifecycle and structured logging
import XCTest
@testable import MiPlay

@MainActor extension MiPlayCoreTests {
    func testProcessManagerCollectsOutputAndExitStatus() async throws {
        let manager = ProcessManager()
        let processID = try await manager.launch(
            executablePath: "/bin/sh",
            arguments: ["-c", "printf stdout; printf stderr >&2"],
            captureOutput: true
        )

        let result = try await manager.waitForTermination(processID: processID, timeout: 5)

        XCTAssertEqual(result.statusCode, 0)
        XCTAssertFalse(result.terminatedBySignal)
        XCTAssertTrue(result.output.contains("stdout"))
        XCTAssertTrue(result.output.contains("stderr"))
    }

    func testProcessManagerDrainsLargeConcurrentOutput() async throws {
        let manager = ProcessManager()
        let processID = try await manager.launch(
            executablePath: "/bin/sh",
            arguments: ["-c", "yes A | head -c 131072; yes B | head -c 131072 >&2"],
            captureOutput: true
        )

        let result = try await manager.waitForTermination(processID: processID, timeout: 5)

        XCTAssertEqual(result.statusCode, 0)
        XCTAssertEqual(result.output.filter { $0 == "A" }.count, 65536)
        XCTAssertEqual(result.output.filter { $0 == "B" }.count, 65536)
    }

    func testProcessManagerReportsNonZeroExit() async throws {
        let manager = ProcessManager()
        let processID = try await manager.launch(
            executablePath: "/bin/sh",
            arguments: ["-c", "printf failure >&2; exit 7"],
            captureOutput: true
        )

        let result = try await manager.waitForTermination(processID: processID, timeout: 5)

        XCTAssertEqual(result.statusCode, 7)
        XCTAssertFalse(result.terminatedBySignal)
        XCTAssertTrue(result.output.contains("failure"))
    }

    func testProcessManagerTimeoutTerminatesAndResumesOnce() async throws {
        let manager = ProcessManager()

        do {
            _ = try await manager.launchAndWait(
                executablePath: "/bin/sh",
                arguments: ["-c", "sleep 30"],
                timeout: 0.1
            )
            XCTFail("Expected timeout")
        } catch let error as ProcessManager.ProcessError {
            guard case .timeout = error else {
                return XCTFail("Unexpected process error: \(error)")
            }
        }
    }

    func testProcessManagerCancellationDoesNotDoubleResume() async throws {
        let manager = ProcessManager()
        let processID = try await manager.launch(
            executablePath: "/bin/sh",
            arguments: ["-c", "sleep 30"]
        )
        let waiter = Task {
            try await manager.waitForCompletion(processID: processID, timeout: 30)
        }

        try await Task.sleep(for: .milliseconds(100))
        waiter.cancel()

        do {
            _ = try await waiter.value
            XCTFail("Expected cancellation")
        } catch is CancellationError {
            // Expected. The cancellation handler also requests child cleanup.
        }
        _ = try? await manager.terminateAndWait(processID: processID, force: true, timeout: 5)
    }

    func testProcessManagerRejectsSecondCancelledWaiter() async throws {
        let manager = ProcessManager()
        let processID = try await manager.launch(
            executablePath: "/bin/sh",
            arguments: ["-c", "sleep 30"]
        )
        let firstWaiter = Task {
            try await manager.waitForTermination(processID: processID, timeout: 30)
        }

        try await Task.sleep(for: .milliseconds(100))
        let secondWaiter = Task {
            try await manager.waitForTermination(processID: processID, timeout: 30)
        }
        secondWaiter.cancel()

        do {
            _ = try await secondWaiter.value
            XCTFail("Expected duplicate wait to be rejected")
        } catch let error as ProcessManager.ProcessError {
            guard case .unsupportedOperation = error else {
                return XCTFail("Unexpected duplicate wait error: \(error)")
            }
        }

        firstWaiter.cancel()
        _ = try? await firstWaiter.value
        _ = try? await manager.terminateAndWait(processID: processID, force: true, timeout: 5)
    }

    func testStructuredLogFlushExportAndSanitization() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileSystem = GameFileSystemRepository(appSupportDirectory: root)
        let logger = LogWriter(fileSystemRepository: fileSystem)
        let secret = "token-secret-(UUID().uuidString)"

        await logger.record(.init(
            level: .error,
            module: "ProcessManager",
            eventName: "process.failure",
            operationID: UUID(),
            taskID: "task-1",
            gameID: "genshinImpact",
            phase: "termination",
            result: "failed",
            errorCategory: "processExitedAbnormally",
            messageCode: "process.failure",
            fields: [
                "reasonCode": "https://example.com/download?token=\(secret) /Users/private/\(secret)",
                "path": "/Users/private/\(secret)",
                "token": secret
            ]
        ))

        let pending = await logger.pendingEventsForTesting()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.sequence, 1)
        XCTAssertEqual(pending.first?.fields["path"], nil)
        XCTAssertEqual(pending.first?.fields["token"], nil)
        XCTAssertNotEqual(pending.first?.fields["reasonCode"], "https://example.com/download?token=\(secret) /Users/private/\(secret)")
        XCTAssertTrue(pending.first?.sanitizationApplied == true)

        let receipt = try await logger.flush(reason: "explicit")
        XCTAssertEqual(receipt.eventCount, 1)
        let exported = try await logger.exportLogs()
        XCTAssertTrue(exported.contains("process.failure"))
        XCTAssertFalse(exported.contains(secret))
        XCTAssertFalse(exported.contains("/Users/private"))
        XCTAssertEqual(exported.split(whereSeparator: \.isNewline).count, 1)
    }

    func testLegacyLogEntryDoesNotPersistFreeText() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileSystem = GameFileSystemRepository(appSupportDirectory: root)
        let logger = LogWriter(fileSystemRepository: fileSystem)
        let privateError = "private localized error " + UUID().uuidString

        await logger.error(
            privateError,
            module: "ProcessManager",
            details: "user supplied detail " + privateError
        )

        let pending = await logger.pendingEventsForTesting()
        XCTAssertEqual(pending.count, 1)
        XCTAssertEqual(pending.first?.fields["reasonCode"], "legacy.message")
        XCTAssertTrue(pending.first?.sanitizationApplied == false)

        _ = try await logger.flush()
        let exported = try await logger.exportLogs()
        XCTAssertFalse(exported.contains(privateError))
        XCTAssertFalse(exported.contains("user supplied detail"))
    }

    func testLogFlushFailureRetainsBatchForRetry() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileSystem = GameFileSystemRepository(appSupportDirectory: root)
        let logger = LogWriter(fileSystemRepository: fileSystem)
        let logDirectory = await fileSystem.logDirectory()
        try Data("not a directory".utf8).write(to: logDirectory)

        await logger.record(.init(
            level: .info,
            module: "LogWriter",
            eventName: "test.flush",
            phase: "test",
            result: "completed",
            messageCode: "test.flush"
        ))

        do {
            _ = try await logger.flush()
            XCTFail("Expected flush to fail when the log directory is a file")
        } catch {
            XCTAssertTrue(error is LogWriter.LogWriterError)
        }
        let pendingAfterFailure = await logger.pendingEventsForTesting()
        XCTAssertEqual(pendingAfterFailure.count, 1)

        try FileManager.default.removeItem(at: logDirectory)
        _ = try await logger.flush()
        let pendingAfterRetry = await logger.pendingEventsForTesting()
        XCTAssertTrue(pendingAfterRetry.isEmpty)
    }

    func testStructuredLogSequenceIsActorSerializedAndRotationIsExported() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let fileSystem = GameFileSystemRepository(appSupportDirectory: root)
        let logger = LogWriter(
            fileSystemRepository: fileSystem,
            maxLogFileSize: 1_024,
            maxEventsBeforeFlush: 1_000
        )

        await withTaskGroup(of: Void.self) { group in
            for index in 0..<20 {
                group.addTask {
                    await logger.record(.init(
                        level: .info,
                        module: "General",
                        eventName: "test.event",
                        phase: "test",
                        result: "completed",
                        messageCode: "test.event",
                        fields: ["reasonCode": "event-\(index)-\(String(repeating: "x", count: 120))"]
                    ))
                }
            }
        }

        let pending = await logger.pendingEventsForTesting()
        XCTAssertEqual(pending.count, 20)
        XCTAssertEqual(pending.map(\.sequence), Array(1...20))
        _ = try await logger.flush()

        for index in 20..<40 {
            await logger.record(.init(
                level: .info,
                module: "General",
                eventName: "test.event",
                phase: "test",
                result: "completed",
                messageCode: "test.event",
                fields: ["reasonCode": "event-\(index)-\(String(repeating: "y", count: 120))"]
            ))
        }
        _ = try await logger.flush()

        let logDirectory = await fileSystem.logDirectory()
        XCTAssertTrue(FileManager.default.fileExists(atPath: logDirectory.appendingPathComponent("miplay.log.1").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: logDirectory.appendingPathComponent("miplay.log.4").path))
        let exported = try await logger.exportLogs()
        XCTAssertEqual(exported.split(whereSeparator: \.isNewline).count, 40)
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let sequences = try exported.split(whereSeparator: \.isNewline).map { line -> UInt64 in
            let event = try decoder.decode(LogWriter.LogEvent.self, from: Data(line.utf8))
            return event.sequence
        }
        XCTAssertEqual(sequences, Array(1...40))
    }

    func testLogExportUsesSchedulerTerminalFact() async throws {
        let fixture = try await makeScheduler()
        let receipt = try await fixture.scheduler.enqueueReceipt(type: .logExport, gameId: nil)
        let task = try await waitForTask(receipt.taskID, scheduler: fixture.scheduler)
        XCTAssertEqual(task.state, .completed)
        XCTAssertTrue(task.outcome == "exported" || task.outcome == "empty")
        let logExportResult = await fixture.scheduler.logExportResult(for: receipt.taskID)
        XCTAssertNotNil(logExportResult)
    }

}
