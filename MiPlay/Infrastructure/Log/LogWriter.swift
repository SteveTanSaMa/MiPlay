//
//  LogWriter.swift
//  MiPlay
//

import Foundation
import OSLog

// Source: Architecture Design -> Service Contract -> LogWriter
// Source: Architecture Design -> ADR 030 -> structured redacted diagnostics

/// The only diagnostic storage boundary. Logging is deliberately independent
/// from Domain state: a flush/export failure never changes a business result.
public actor LogWriter {
    public enum LogLevel: String, CaseIterable, Codable, Sendable {
        case debug = "DEBUG"
        case info = "INFO"
        case warning = "WARNING"
        case error = "ERROR"

        fileprivate var osLogType: OSLogType {
            switch self {
            case .debug: return .debug
            case .info: return .info
            case .warning: return .default
            case .error: return .error
            }
        }
    }

    private let osLog: OSLog
    private let fileSystemRepository: GameFileSystemRepository
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var logEvents: [LogEvent] = []
    private var nextSequence: UInt64 = 0
    private var lastMaintenanceFailure: String?

    private let maxEventsBeforeFlush: Int
    private let maxLogFileSize: UInt64
    private let backupCount = 3

    private static let allowedModules: Set<String> = [
        "General", "App", "BackgroundMediaService", "FileIntegrityVerifier",
        "GameFileSystemRepository", "GameRegistry", "LaunchOrchestrator",
        "LibraryViewModel", "LogWriter", "MediaTranscoder", "NetworkDownloadProvider",
        "PerformanceOptionManager", "PersistenceStore", "PreLaunchValidator", "ProcessManager", "SettingsViewModel",
        "SolutionEngine", "TaskScheduler", "VersionChecker", "WineRuntimeProvider",
        "WineVersionDownloader", "WineVersionManager"
    ]

    private static let allowedResults: Set<String> = [
        "accepted", "started", "inProgress", "completed", "failed", "cancelled",
        "rejected", "unavailable", "recoveryRequired", "unknown"
    ]

    private static let allowedErrorCategories: Set<String> = [
        "none", "permissionDenied", "bookmarkStale", "networkUnavailable", "apiForbidden",
        "apiNotFound", "apiRateLimited", "apiServerError", "apiNetworkError", "assetForbidden",
        "assetRateLimited", "assetServerError", "assetResourceNotFound", "rateLimited", "resourceNotFound", "catalogInvalid", "integrityFailed",
        "integrityUnsupported", "processStartFailed", "processTimedOut", "processExitedAbnormally",
        "terminationUnconfirmed", "userCancelled", "cancellationUnconfirmed", "conflict",
        "persistenceCorrupted", "migrationFailed", "writeFailed", "logFlushFailed", "logExportFailed",
        "recoveryRequired", "unknown"
    ]

    private static let allowedFieldKeys: Set<String> = [
        "statusCode", "retryAfter", "itemCount", "bytesReceived", "totalBytes", "exitCode",
        "signal", "timeoutSeconds", "attempt", "revision", "fileCount", "changed", "cleanupVerified",
        "reasonCode", "sourceID", "policyRevision", "assetSize", "md5Present", "sizePresent",
        "configPresent", "manifestRevision", "installedCount", "durationMs", "scope", "stale",
        "responseKind", "persistence", "recordID", "flushedThroughSequence", "eventCount"
    ]

    private static let sensitiveFieldKeys: Set<String> = [
        "path", "url", "bookmark", "bookmarkData", "token", "password", "authorization", "cookie",
        "headers", "command", "arguments", "environment", "prefixPath", "installPath", "runtimePath",
        "archivePath", "destinationPath", "stdout", "stderr", "localizedDescription", "userInput"
    ]

    public init(fileSystemRepository: GameFileSystemRepository) {
        self.init(
            fileSystemRepository: fileSystemRepository,
            maxLogFileSize: 5 * 1024 * 1024,
            maxEventsBeforeFlush: 50
        )
    }

    // Source: Architecture Logging Contract -> XCTest capture seam.
    // Production uses the public initializer; tests can exercise rotation and
    // automatic flush without manufacturing multi-megabyte user data.
    internal init(
        fileSystemRepository: GameFileSystemRepository,
        maxLogFileSize: UInt64,
        maxEventsBeforeFlush: Int
    ) {
        self.fileSystemRepository = fileSystemRepository
        self.osLog = OSLog(subsystem: "SteveTan.MiPlay", category: "MiPlay")
        self.encoder = JSONEncoder()
        self.encoder.dateEncodingStrategy = .iso8601
        self.decoder = JSONDecoder()
        self.decoder.dateDecodingStrategy = .iso8601
        self.maxLogFileSize = maxLogFileSize
        self.maxEventsBeforeFlush = max(1, maxEventsBeforeFlush)
    }

    // MARK: - Structured events

    public func record(_ event: LogEvent) {
        let sanitized = sanitize(event)
        nextSequence += 1
        let accepted = LogEvent(
            eventID: sanitized.eventID,
            timestamp: sanitized.timestamp,
            sequence: nextSequence,
            level: sanitized.level,
            module: sanitized.module,
            eventName: sanitized.eventName,
            operationID: sanitized.operationID,
            parentOperationID: sanitized.parentOperationID,
            taskID: sanitized.taskID,
            gameID: sanitized.gameID,
            wineTag: sanitized.wineTag,
            phase: sanitized.phase,
            result: sanitized.result,
            errorCategory: sanitized.errorCategory,
            messageCode: sanitized.messageCode,
            fields: sanitized.fields,
            sanitizationApplied: sanitized.sanitizationApplied
        )
        emitToOSLog(accepted)
        logEvents.append(accepted)
        if logEvents.count >= maxEventsBeforeFlush {
            Task { [weak self] in await self?.autoFlush() }
        }
    }

    /// Compatibility entry point for existing callers. New call sites should
    /// use `record(_:)` so operation and domain context remain explicit.
    public func debug(_ message: String, module: String = "General", details: String? = nil) {
        recordLegacy(.debug, message: message, module: module, details: details)
    }

    public func info(_ message: String, module: String = "General", details: String? = nil) {
        recordLegacy(.info, message: message, module: module, details: details)
    }

    public func warning(_ message: String, module: String = "General", details: String? = nil) {
        recordLegacy(.warning, message: message, module: module, details: details)
    }

    public func error(_ message: String, module: String = "General", details: String? = nil) {
        recordLegacy(.error, message: message, module: module, details: details)
    }

    private func recordLegacy(_ level: LogLevel, message _: String, module: String, details _: String?) {
        // Legacy callers may still pass localized errors, paths, or URLs. Do
        // not attempt to infer privacy from arbitrary prose; the structured
        // call sites carry the useful stable message code instead.
        record(LogEvent(
            level: level,
            module: module,
            eventName: "legacy.message",
            phase: "legacy",
            result: level == .error ? "failed" : "unknown",
            errorCategory: level == .error ? "unknown" : "none",
            messageCode: "legacy.message",
            fields: ["reasonCode": "legacy.message"]
        ))
    }

    private func emitToOSLog(_ event: LogEvent) {
        os_log(
            "%{public}@ %{public}@ op=%{public}@ task=%{public}@ game=%{public}@ phase=%{public}@ result=%{public}@ error=%{public}@",
            log: osLog,
            type: event.level.osLogType,
            event.eventName,
            event.messageCode,
            event.operationID.uuidString,
            event.taskID ?? "absent",
            event.gameID ?? "absent",
            event.phase,
            event.result,
            event.errorCategory
        )
    }

    // MARK: - Flush

    @discardableResult
    public func flush(reason: String = "explicit") async throws -> FlushReceipt {
        let safeReason = ["explicit", "automatic", "export"].contains(reason) ? reason : "explicit"
        os_log(
            "log.flush.start reason=%{public}@ pending=%{public}d",
            log: osLog,
            type: .debug,
            safeReason,
            logEvents.count
        )
        try Task.checkCancellation()
        guard !logEvents.isEmpty else {
            os_log(
                "log.flush.success reason=%{public}@ count=0",
                log: osLog,
                type: .debug,
                safeReason
            )
            return FlushReceipt(flushedThroughSequence: nextSequence, eventCount: 0)
        }

        let logDir = await fileSystemRepository.logDirectory()
        let batch = logEvents
        let logURL = logDir.appendingPathComponent("miplay.log")
        do {
            try FileManager.default.createDirectory(at: logDir, withIntermediateDirectories: true)
            let data = try encode(batch)
            try rotateIfNeeded(at: logURL, incomingBytes: UInt64(data.count), directory: logDir)
            try appendAtomically(data, to: logURL)
            let persisted = try Data(contentsOf: logURL)
            guard let last = batch.last,
                  persisted.range(of: Data(last.eventID.uuidString.utf8)) != nil else {
                throw LogWriterError.flushFailed
            }
            logEvents.removeFirst(batch.count)
            lastMaintenanceFailure = nil
            os_log(
                "log.flush.success reason=%{public}@ count=%{public}d through=%{public}llu",
                log: osLog,
                type: .debug,
                safeReason,
                batch.count,
                batch.last?.sequence ?? nextSequence
            )
            return FlushReceipt(flushedThroughSequence: batch.last?.sequence ?? nextSequence, eventCount: batch.count)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            lastMaintenanceFailure = "flush"
            emitMaintenanceFailure(.flushFailed)
            throw LogWriterError.flushFailed
        }
    }

    private func autoFlush() async {
        do {
            _ = try await flush(reason: "automatic")
        } catch is CancellationError {
            // The batch remains in actor memory. Automatic cancellation is
            // diagnostic only and must not alter a Domain outcome.
        } catch {
            // `flush` already emits the minimal non-recursive OSLog fact.
        }
    }

    private func emitMaintenanceFailure(_ error: LogWriterError) {
        os_log(
            "log maintenance failed category=%{public}@",
            log: osLog,
            type: .error,
            error == .flushFailed ? "logFlushFailed" : "logExportFailed"
        )
    }

    private func encode(_ events: [LogEvent]) throws -> Data {
        var data = Data()
        for event in events {
            data.append(try encoder.encode(event))
            data.append(0x0A)
        }
        return data
    }

    private func appendAtomically(_ data: Data, to url: URL) throws {
        var existing = Data()
        if FileManager.default.fileExists(atPath: url.path) {
            existing = try Data(contentsOf: url)
        }
        existing.append(data)
        try existing.write(to: url, options: [.atomic])
    }

    private func rotateIfNeeded(at url: URL, incomingBytes: UInt64, directory: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let currentSize = try FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64 ?? 0
        guard currentSize + incomingBytes > maxLogFileSize else { return }

        let oldest = directory.appendingPathComponent("miplay.log.\(backupCount)")
        if FileManager.default.fileExists(atPath: oldest.path) {
            try FileManager.default.removeItem(at: oldest)
        }
        for index in stride(from: backupCount - 1, through: 1, by: -1) {
            let source = directory.appendingPathComponent("miplay.log.\(index)")
            let destination = directory.appendingPathComponent("miplay.log.\(index + 1)")
            if FileManager.default.fileExists(atPath: destination.path) {
                try FileManager.default.removeItem(at: destination)
            }
            if FileManager.default.fileExists(atPath: source.path) {
                try FileManager.default.moveItem(at: source, to: destination)
            }
        }
        let backup = directory.appendingPathComponent("miplay.log.1")
        try FileManager.default.moveItem(at: url, to: backup)
    }

    // MARK: - Export

    /// Flushes first, then returns only structured, redacted log data. It does
    /// not expose the App Support path or return an unfiltered fallback.
    public func exportLogs() async throws -> String {
        os_log("log.export.start", log: osLog, type: .debug)
        do {
            _ = try await flush(reason: "export")
            try Task.checkCancellation()
            let logDir = await fileSystemRepository.logDirectory()
            var events: [LogEvent] = []
            for index in stride(from: backupCount, through: 1, by: -1) {
                let url = logDir.appendingPathComponent("miplay.log.\(index)")
                events.append(contentsOf: try readEvents(at: url))
            }
            events.append(contentsOf: try readEvents(at: logDir.appendingPathComponent("miplay.log")))
            let safeEvents = events.sorted { lhs, rhs in
                lhs.sequence == rhs.sequence ? lhs.timestamp < rhs.timestamp : lhs.sequence < rhs.sequence
            }.map { sanitize($0) }
            var result = Data()
            for event in safeEvents {
                result.append(try encoder.encode(event))
                result.append(0x0A)
            }
            guard let content = String(data: result, encoding: .utf8) else {
                throw LogWriterError.exportFailed
            }
            os_log(
                "log.export.success eventCount=%{public}d",
                log: osLog,
                type: .debug,
                safeEvents.count
            )
            return content
        } catch is CancellationError {
            throw CancellationError()
        } catch is LogWriterError {
            emitMaintenanceFailure(.exportFailed)
            throw LogWriterError.exportFailed
        } catch {
            emitMaintenanceFailure(.exportFailed)
            throw LogWriterError.exportFailed
        }
    }

    private func readEvents(at url: URL) throws -> [LogEvent] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        guard !data.isEmpty else { return [] }
        var events: [LogEvent] = []
        for line in String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline) {
            guard let lineData = String(line).data(using: .utf8),
                  let event = try? decoder.decode(LogEvent.self, from: lineData) else {
                throw LogWriterError.exportFailed
            }
            events.append(event)
        }
        return events
    }

    public func clearLogs() async throws {
        let logDir = await fileSystemRepository.logDirectory()
        for name in (0...backupCount).map({ $0 == 0 ? "miplay.log" : "miplay.log.\($0)" }) {
            let url = logDir.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path) {
                try FileManager.default.removeItem(at: url)
            }
        }
        logEvents.removeAll()
    }

    internal func pendingEventsForTesting() -> [LogEvent] { logEvents }

    // MARK: - Sanitization

    private func sanitize(_ event: LogEvent) -> LogEvent {
        var changed = event.sanitizationApplied
        let module = Self.allowedModules.contains(event.module) ? event.module : "General"
        changed = changed || module != event.module
        let eventName = sanitizeIdentifier(event.eventName, fallback: "unknown.event", changed: &changed)
        let phase = sanitizeIdentifier(event.phase, fallback: "unknown", changed: &changed)
        let result = Self.allowedResults.contains(event.result) ? event.result : "unknown"
        changed = changed || result != event.result
        let errorCategory = Self.allowedErrorCategories.contains(event.errorCategory)
            ? event.errorCategory
            : "unknown"
        changed = changed || errorCategory != event.errorCategory
        let normalizedError = (event.level == .warning || event.level == .error) && errorCategory == "none"
            ? "unknown"
            : errorCategory
        changed = changed || normalizedError != errorCategory
        let fields = sanitizeFields(event.fields, changed: &changed)
        let taskID = sanitizeIdentifierOptional(event.taskID, changed: &changed)
        let gameID = sanitizeIdentifierOptional(event.gameID, changed: &changed)
        let wineTag = sanitizeWineTag(event.wineTag, changed: &changed)
        let messageCode = sanitizeIdentifier(event.messageCode, fallback: "unknown.message", changed: &changed)
        return LogEvent(
            eventID: event.eventID,
            timestamp: event.timestamp,
            sequence: event.sequence,
            level: event.level,
            module: module,
            eventName: eventName,
            operationID: event.operationID,
            parentOperationID: event.parentOperationID,
            taskID: taskID,
            gameID: gameID,
            wineTag: wineTag,
            phase: phase,
            result: result,
            errorCategory: normalizedError,
            messageCode: messageCode,
            fields: fields,
            sanitizationApplied: changed
        )
    }

    private func sanitizeFields(_ input: [String: String], changed: inout Bool) -> [String: String] {
        var output: [String: String] = [:]
        for (key, value) in input {
            guard Self.allowedFieldKeys.contains(key) else {
                changed = true
                continue
            }
            output[key] = sanitizeText(value, changed: &changed)
        }
        for key in input.keys where Self.sensitiveFieldKeys.contains(key) {
            changed = true
        }
        return output
    }

    private func sanitizeText(_ value: String, changed: inout Bool) -> String {
        var result = value
        let replacements: [(String, String)] = [
            ("https?://[^\\s\\\"'<>]+", "<redacted-url>"),
            ("(?i)(authorization|bearer|token|password|cookie|WINEPREFIX|WINEDLLOVERRIDES)\\s*[:=]\\s*[^\\s,;]+", "<redacted-value>"),
            ("(?<![A-Za-z0-9])/(?:[^\\s\\\"'|,;]+/)*[^\\s\\\"'|,;]+", "<redacted-path>")
        ]
        for (pattern, replacement) in replacements {
            guard let expression = try? NSRegularExpression(pattern: pattern) else { continue }
            let range = NSRange(result.startIndex..<result.endIndex, in: result)
            let replaced = expression.stringByReplacingMatches(in: result, range: range, withTemplate: replacement)
            if replaced != result { changed = true; result = replaced }
        }
        return result
    }

    private func sanitizeIdentifier(_ value: String, fallback: String, changed: inout Bool) -> String {
        guard !value.isEmpty,
              value.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "._-".unicodeScalars.contains($0) }) else {
            changed = true
            return fallback
        }
        return value
    }

    private func sanitizeIdentifierOptional(_ value: String?, changed: inout Bool) -> String? {
        guard let value else { return nil }
        return sanitizeIdentifier(value, fallback: "redacted", changed: &changed)
    }

    private func sanitizeWineTag(_ value: String?, changed: inout Bool) -> String? {
        guard let value else { return nil }
        guard Self.allowedWineTags.contains(value) else {
            changed = true
            return "redacted"
        }
        return value
    }

    private static let allowedWineTags: Set<String> = [
        "wine-crossover-11.0-1-signed",
        "wine-crossover-11.0-1",
        "wine-11.0-signed",
        "wine-11.8-signed",
        "wine-devel-9.0",
        "wine-crossover-21.2.0"
    ]
}
