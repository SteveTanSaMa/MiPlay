//
//  LogWriterModels.swift
//  MiPlay
//

import Foundation

// Source: Architecture Design -> Service Contract -> LogWriter
// Source: Architecture Design -> ADR 030 -> structured redacted diagnostics

extension LogWriter {
    /// A safe, structured event. Values are sanitized again by LogWriter
    /// before they reach OSLog, memory, files, or export.
    public struct LogEvent: Codable, Sendable, Identifiable, Equatable {
        public let eventID: UUID
        public let timestamp: Date
        public let sequence: UInt64
        public let level: LogLevel
        public let module: String
        public let eventName: String
        public let operationID: UUID
        public let parentOperationID: UUID?
        public let taskID: String?
        public let gameID: String?
        public let wineTag: String?
        public let phase: String
        public let result: String
        public let errorCategory: String
        public let messageCode: String
        public let fields: [String: String]
        public let sanitizationApplied: Bool

        public var id: UUID { eventID }

        public init(
            eventID: UUID = UUID(),
            timestamp: Date = Date(),
            sequence: UInt64 = 0,
            level: LogLevel,
            module: String,
            eventName: String,
            operationID: UUID = UUID(),
            parentOperationID: UUID? = nil,
            taskID: String? = nil,
            gameID: String? = nil,
            wineTag: String? = nil,
            phase: String,
            result: String,
            errorCategory: String = "none",
            messageCode: String,
            fields: [String: String] = [:],
            sanitizationApplied: Bool = false
        ) {
            self.eventID = eventID
            self.timestamp = timestamp
            self.sequence = sequence
            self.level = level
            self.module = module
            self.eventName = eventName
            self.operationID = operationID
            self.parentOperationID = parentOperationID
            self.taskID = taskID
            self.gameID = gameID
            self.wineTag = wineTag
            self.phase = phase
            self.result = result
            self.errorCategory = errorCategory
            self.messageCode = messageCode
            self.fields = fields
            self.sanitizationApplied = sanitizationApplied
        }
    }

    /// Compatibility value returned by the explicit flush barrier.
    public struct FlushReceipt: Sendable, Equatable {
        public let flushedThroughSequence: UInt64
        public let eventCount: Int

        internal init(flushedThroughSequence: UInt64, eventCount: Int) {
            self.flushedThroughSequence = flushedThroughSequence
            self.eventCount = eventCount
        }
    }

    public enum LogWriterError: Error, LocalizedError, Sendable {
        case flushFailed
        case exportFailed
        case cancelled

        public var errorDescription: String? {
            switch self {
            case .flushFailed: return "日志尚未保存，请稍后重试"
            case .exportFailed: return "日志导出失败，请稍后重试"
            case .cancelled: return "日志导出已取消"
            }
        }
    }
}
