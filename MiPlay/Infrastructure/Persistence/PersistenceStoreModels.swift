//
//  PersistenceStoreModels.swift
//  MiPlay
//

import Foundation

// Source: Architecture Design -> Service Contract -> PersistenceStore
// Source: Architecture Design -> ADR 009 -> schema, backup, atomic verification

extension PersistenceStore {
    public enum RecoveryState: Sendable, Equatable {
        case initialData
        case readable
        case migrationRequired
        case migratedAndVerified
        case restoreAvailable(diagnosticPath: String)
        case recoveryFailed(diagnosticPath: String?)
    }

    public struct AppDataLoadResult: Sendable {
        public let data: AppData?
        public let state: RecoveryState

        public init(data: AppData?, state: RecoveryState) {
            self.data = data
            self.state = state
        }
    }

    public enum StoreError: Error, LocalizedError, Sendable {
        case fileNotFound(String)
        case encodingFailed(String)
        case decodingFailed(String)
        case writeFailed(String)
        case readFailed(String)
        case dataCorrupted(String)
        case migrationFailed(String)
        case recoveryRequired(String)
        case unsupportedSchema(Int)

        public var errorDescription: String? {
            switch self {
            case .fileNotFound(let path): return "文件未找到: \(path)"
            case .encodingFailed(let detail): return "数据编码失败: \(detail)"
            case .decodingFailed(let detail): return "数据解码失败: \(detail)"
            case .writeFailed(let detail): return "文件写入失败: \(detail)"
            case .readFailed(let detail): return "文件读取失败: \(detail)"
            case .dataCorrupted(let detail): return "数据损坏: \(detail)"
            case .migrationFailed(let detail): return "数据迁移失败: \(detail)"
            case .recoveryRequired(let detail): return "需要恢复应用数据: \(detail)"
            case .unsupportedSchema(let version): return "不支持的应用数据版本: \(version)"
            }
        }
    }
}
