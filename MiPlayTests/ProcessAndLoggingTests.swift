// Source: Implementation maintenance split -> process lifecycle and structured logging
import XCTest
import Darwin
@testable import MiPlay

@MainActor extension MiPlayCoreTests {
    func testApplicationLaunchReceiptRequiresCurrentTokenAndHelperProcessGroup() throws {
        let token = UUID()
        let text = "v1:\(token.uuidString):4321:4321\n"
        let receipt = try XCTUnwrap(ApplicationLauncher.LaunchReceipt(contents: text, expectedToken: token))
        XCTAssertEqual(receipt.pid, 4321)
        XCTAssertTrue(receipt.matches(observedProcessGroup: 4321, hasTerminalStatus: false))
        XCTAssertFalse(receipt.matches(observedProcessGroup: 4320, hasTerminalStatus: true))
        XCTAssertFalse(receipt.matches(observedProcessGroup: nil, hasTerminalStatus: false))
        XCTAssertTrue(receipt.matches(observedProcessGroup: nil, hasTerminalStatus: true))
        XCTAssertNil(ApplicationLauncher.LaunchReceipt(contents: text, expectedToken: UUID()))
        for invalid in [
            "", "v2:\(token):4321:4321", "v1:\(token):0:0", "v1:\(token):1:1",
            "v1:\(token):-1:-1", "v1:\(token):4322:4321", "v1:\(token):+4321:+4321",
            "v1:\(token):999999999999:999999999999", "v1:\(token):4321:4321:extra",
            "v1:\(token):4321:4321\nv1:\(token):4322:4322"
        ] {
            XCTAssertNil(ApplicationLauncher.LaunchReceipt(contents: invalid, expectedToken: token), invalid)
        }
    }

    func testApplicationLaunchReceiptRejectsLinksAndAcceptanceFailureNeverPublishes() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let receipt = root.appendingPathComponent("launch.pid")
        XCTAssertNil(try ApplicationLauncher.readLaunchReceipt(at: receipt))
        let token = UUID()
        let text = "v1:\(token):4321:4321\n"
        try Data(text.utf8).write(to: receipt)
        XCTAssertEqual(try ApplicationLauncher.readLaunchReceipt(at: receipt), text)
        let link = root.appendingPathComponent("linked.pid")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: receipt)
        XCTAssertThrowsError(try ApplicationLauncher.readLaunchReceipt(at: link))
        XCTAssertThrowsError(try ApplicationLauncher.readLaunchReceipt(at: root))
        try Data(repeating: 65, count: 257).write(to: receipt)
        XCTAssertThrowsError(try ApplicationLauncher.readLaunchReceipt(at: receipt))

        let acceptance = root.appendingPathComponent("launch.pid.accepted")
        let temporary = URL(fileURLWithPath: acceptance.path + ".tmp")
        try Data("occupied".utf8).write(to: temporary)
        XCTAssertThrowsError(try ApplicationLauncher.publishLaunchAcceptance(token: token, at: acceptance))
        XCTAssertFalse(FileManager.default.fileExists(atPath: acceptance.path))
        XCTAssertEqual(try String(contentsOf: temporary, encoding: .utf8), "occupied")
        try FileManager.default.removeItem(at: temporary)
        try ApplicationLauncher.publishLaunchAcceptance(token: token, at: acceptance)
        XCTAssertEqual(try String(contentsOf: acceptance, encoding: .utf8), token.uuidString + "\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.path))
    }

    func testGameLauncherHandshakeWaitsForAcceptanceAndTracksFastExit() async throws {
        let launcherURL = try XCTUnwrap(Bundle.main.url(forResource: "GameLauncher", withExtension: nil))
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let token = UUID()
        let receiptURL = root.appendingPathComponent("launch.pid")
        let status = root.appendingPathComponent("launch.status")
        let log = root.appendingPathComponent("launch.log")
        let marker = root.appendingPathComponent("child-started")
        let manager = ProcessManager()
        let processID = try await manager.launch(
            executablePath: launcherURL.path,
            arguments: ["/bin/sh", "-c", "test -z \"$MIPLAY_LAUNCH_TOKEN\" && test -z \"$MIPLAY_LAUNCH_PID_FILE\" && printf started > \"$MIPLAY_TEST_MARKER\""],
            environment: ["MIPLAY_LAUNCH_PID_FILE": receiptURL.path, "MIPLAY_LAUNCH_TOKEN": token.uuidString,
                          "MIPLAY_LAUNCH_STATUS": status.path, "MIPLAY_LAUNCH_LOG": log.path,
                          "MIPLAY_TEST_MARKER": marker.path], captureOutput: true
        )
        let deadline = ContinuousClock.now + .seconds(3)
        while !FileManager.default.fileExists(atPath: receiptURL.path), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        let receipt = try XCTUnwrap(ApplicationLauncher.LaunchReceipt(
            contents: try XCTUnwrap(ApplicationLauncher.readLaunchReceipt(at: receiptURL)), expectedToken: token
        ))
        guard case .running(let ownedPID) = await manager.status(processID: processID) else {
            return XCTFail("Helper exited before receiving launch acceptance")
        }
        XCTAssertEqual(receipt.pid, ownedPID)
        XCTAssertEqual(getpgid(receipt.pid), ownedPID)
        XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: status.path))
        let acceptance = URL(fileURLWithPath: receiptURL.path + ".accepted")
        try ApplicationLauncher.publishLaunchAcceptance(token: token, at: acceptance)
        let result = try await manager.waitForTermination(processID: processID, timeout: 5)
        XCTAssertEqual(result.statusCode, 0, result.output)
        XCTAssertEqual(try String(contentsOf: marker, encoding: .utf8), "started")
        XCTAssertEqual(ApplicationLauncher().exitResult(logURL: log, statusURL: status).statusCode, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: receiptURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: acceptance.path))
    }

    func testGameLauncherWithoutValidAcceptanceNeverStartsChildOrOverwritesNewSessionStatus() async throws {
        let launcherURL = try XCTUnwrap(Bundle.main.url(forResource: "GameLauncher", withExtension: nil))
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let manager = ProcessManager()
        for sendWrongAcceptance in [true, false] {
            let token = UUID()
            let receipt = root.appendingPathComponent("\(token).pid")
            let acceptance = URL(fileURLWithPath: receipt.path + ".accepted")
            let marker = root.appendingPathComponent("child-started")
            let status = root.appendingPathComponent("launch.status")
            try Data("new-session-status".utf8).write(to: status)
            if sendWrongAcceptance {
                try Data((UUID().uuidString + "\n").utf8).write(to: acceptance)
            }
            let processID = try await manager.launch(
                executablePath: launcherURL.path,
                arguments: ["/bin/sh", "-c", "printf started > \"$MIPLAY_TEST_MARKER\""],
                environment: ["MIPLAY_LAUNCH_PID_FILE": receipt.path, "MIPLAY_LAUNCH_TOKEN": token.uuidString,
                              "MIPLAY_LAUNCH_STATUS": status.path, "MIPLAY_TEST_MARKER": marker.path], captureOutput: true
            )
            let result = try await manager.waitForTermination(processID: processID, timeout: 15)
            XCTAssertEqual(result.statusCode, 78, result.output)
            XCTAssertFalse(FileManager.default.fileExists(atPath: marker.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: receipt.path))
            XCTAssertFalse(FileManager.default.fileExists(atPath: acceptance.path))
            XCTAssertEqual(try String(contentsOf: status, encoding: .utf8), "new-session-status")
        }
    }

    func testApplicationLaunchOfMissingBundleDoesNotPublishAcceptance() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            _ = try await ApplicationLauncher().launch(
                bundleURL: root.appendingPathComponent("missing.app"), arguments: [], environment: [:],
                logURL: root.appendingPathComponent("launch.log"), statusURL: root.appendingPathComponent("launch.status")
            )
            XCTFail("A missing application must not launch")
        } catch {
            let files = try FileManager.default.contentsOfDirectory(atPath: root.path)
            XCTAssertFalse(files.contains { $0.hasSuffix(".accepted") || $0.hasSuffix(".pid") })
        }
    }

    func testApplicationMissingOrInvalidExitStatusRemainsUnknown() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = root.appendingPathComponent("launch.log")
        let status = root.appendingPathComponent("launch.status")
        try Data("Library WDFLDR.SYS not found".utf8).write(to: log)
        let launcher = ApplicationLauncher()
        let missing = launcher.exitResult(logURL: log, statusURL: status)
        XCTAssertEqual(missing.statusCode, -1)
        XCTAssertFalse(missing.terminatedBySignal)
        for value in ["", "signal:0", "signal:999", "exit:-1", "exit:999", "garbage"] {
            try Data(value.utf8).write(to: status)
            let exit = launcher.exitResult(logURL: log, statusURL: status)
            XCTAssertEqual(exit.statusCode, -1, value)
            XCTAssertFalse(exit.terminatedBySignal, value)
            XCTAssertFalse(GameExitDiagnostic.summary(
                statusCode: exit.statusCode, terminatedBySignal: exit.terminatedBySignal, output: exit.output
            ).contains("反作弊"))
        }
    }

    func testApplicationSessionResetPreventsPreviousExitAndLogFromBeingReused() throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = root.appendingPathComponent("launch.log")
        let status = root.appendingPathComponent("launch.status")
        try Data("Library WDFLDR.SYS not found".utf8).write(to: log)
        try Data("exit:5".utf8).write(to: status)
        try ApplicationLauncher.prepareSessionFiles(logURL: log, statusURL: status)
        let killedWrapper = ApplicationLauncher().exitResult(logURL: log, statusURL: status)
        XCTAssertEqual(killedWrapper.statusCode, -1)
        XCTAssertFalse(killedWrapper.terminatedBySignal)
        XCTAssertEqual(killedWrapper.output, "")
        try Data("this session only".utf8).write(to: log)
        try Data("signal:9\n".utf8).write(to: status)
        let killedChild = ApplicationLauncher().exitResult(logURL: log, statusURL: status)
        XCTAssertEqual(killedChild.statusCode, SIGKILL)
        XCTAssertTrue(killedChild.terminatedBySignal)
        XCTAssertEqual(killedChild.output, "this session only")
    }

    func testDriverNamesAndOrdinaryExitNumbersDoNotProveAnticheatFailure() {
        for output in ["loaded HoYoKProtect.sys", "WDFLDR.SYS", "err:graphics: failed initialization", "HoYoKProtect.sys\nunrelated operation failed"] {
            let summary = GameExitDiagnostic.summary(statusCode: 5, terminatedBySignal: false, output: output)
            XCTAssertFalse(summary.contains("反作弊"), output)
        }
        // exit(137) 是退出码事实，不能仅按 128+9 反推 SIGKILL。
        let summary = GameExitDiagnostic.summary(statusCode: 137, terminatedBySignal: false, output: "")
        XCTAssertTrue(summary.contains("退出码 137"))
        XCTAssertFalse(summary.contains("SIGKILL"))
        let term = GameExitDiagnostic.summary(statusCode: SIGTERM, terminatedBySignal: true, output: "Library WDFLDR.SYS not found")
        XCTAssertTrue(term.contains("SIGTERM"))
        XCTAssertFalse(term.contains("反作弊"))
    }

    func testGameLauncherWritesKilledChildStatusForCurrentSession() async throws {
        let launcherURL = try XCTUnwrap(Bundle.main.url(forResource: "GameLauncher", withExtension: nil))
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let log = root.appendingPathComponent("launch.log")
        let status = root.appendingPathComponent("launch.status")
        try Data("Library WDFLDR.SYS not found".utf8).write(to: log)
        try Data("exit:5".utf8).write(to: status)
        try ApplicationLauncher.prepareSessionFiles(logURL: log, statusURL: status)
        let manager = ProcessManager()
        let processID = try await manager.launch(
            executablePath: launcherURL.path,
            arguments: ["/bin/sh", "-c", "printf 'current session\\n'; kill -9 $$"],
            environment: ["MIPLAY_LAUNCH_LOG": log.path, "MIPLAY_LAUNCH_STATUS": status.path],
            captureOutput: true
        )
        _ = try await manager.waitForTermination(processID: processID, timeout: 5)
        let exit = ApplicationLauncher().exitResult(logURL: log, statusURL: status)
        XCTAssertEqual(exit.statusCode, SIGKILL)
        XCTAssertTrue(exit.terminatedBySignal)
        XCTAssertTrue(exit.output.contains("current session"))
        XCTAssertFalse(exit.output.contains("WDFLDR"))
    }

    func testActualKilledChildIsNotDiagnosedAsAnticheatFailure() async throws {
        let manager = ProcessManager()
        let processID = try await manager.launch(
            executablePath: "/bin/sh",
            arguments: ["-c", "printf 'Library WDFLDR.SYS not found\\n'; kill -9 $$"],
            captureOutput: true
        )
        let exit = try await manager.waitForTermination(processID: processID, timeout: 5)
        XCTAssertTrue(exit.terminatedBySignal)
        XCTAssertEqual(exit.statusCode, SIGKILL)
        let diagnosis = LaunchOrchestrator.LaunchError.processExited(
            exitCode: exit.statusCode, signal: exit.statusCode, output: exit.output
        ).localizedDescription
        XCTAssertTrue(diagnosis.contains("被强制终止"))
        XCTAssertTrue(diagnosis.contains("无法确认发起方"))
        XCTAssertFalse(diagnosis.contains("反作弊"))
    }

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
