//
//  VersionCheckerModels.swift
//  MiPlay
//

import Foundation

// Source: Architecture Design -> Service Contract -> VersionChecker
// Source: Architecture Design -> ADR 018 -> LocalGameEvidence

extension VersionChecker {
    public enum VersionError: Error, LocalizedError, Sendable {
        case apiUnavailable(String)
        case versionFileMissing(String)
        case versionParseFailed(String)
        case fileReadFailed(String)
        case networkError(String)
        case bookmarkRefreshRequired(String)
        case bookmarkRefreshPersistenceFailed(String)

        public var errorDescription: String? {
            switch self {
            case .apiUnavailable(let detail): return "版本 API 不可用: \(detail)"
            case .versionFileMissing(let detail): return "版本文件缺失: \(detail)"
            case .versionParseFailed(let detail): return "版本号解析失败: \(detail)"
            case .fileReadFailed(let detail): return "版本文件读取失败: \(detail)"
            case .networkError(let detail): return "网络错误: \(detail)"
            case .bookmarkRefreshRequired(let detail): return "授权凭据需要刷新并保存: \(detail)"
            case .bookmarkRefreshPersistenceFailed(let detail): return "授权凭据刷新保存失败: \(detail)"
            }
        }
    }

    public enum Outcome: String, Codable, Sendable, Equatable {
        case current
        case updateAvailable
        case versionEvidenceConflict
        case unknown
    }

    public enum EvidenceParseStatus: String, Codable, Sendable, Equatable {
        case configOnly
        case configAndPkg
    }

    public enum PkgVersionMappingStatus: String, Codable, Sendable, Equatable {
        case notPresent
        case mapped
        case unmapped
    }

    /// Raw config.ini evidence. The field name is retained verbatim after
    /// whitespace normalization; no channel/cps meaning is inferred.
    public struct ConfigIniField: Codable, Sendable, Equatable {
        public let section: String
        public let key: String
        public let value: String

        public init(section: String, key: String, value: String) {
            self.section = section
            self.key = key
            self.value = value
        }
    }

    /// One JSON Lines entry from pkg_version. These fields are retained as
    /// evidence; they do not become a version or integrity result by themselves.
    public struct PkgVersionEntry: Codable, Sendable, Equatable {
        public let remoteName: String
        public let fileSize: Int64
        public let md5: String

        public init(remoteName: String, fileSize: Int64, md5: String) {
            self.remoteName = remoteName
            self.fileSize = fileSize
            self.md5 = md5
        }
    }

    public struct LocalEvidence: Codable, Sendable, Equatable {
        public let gameID: String?
        public let locationRevision: Int?
        public let readAt: Date
        public let parseStatus: EvidenceParseStatus
        public let sourceSummary: [String]
        public let gameVersion: String
        public let channel: String?
        public let subChannel: String?
        public let cps: String?
        public let sdkVersion: String?
        public let configFields: [ConfigIniField]
        public let pkgVersionEntries: [PkgVersionEntry]
        public let pkgVersionMapping: PkgVersionMappingStatus
        public let pkgVersionValidationErrors: [String]

        public var pkgVersionEntryCount: Int { pkgVersionEntries.count }

        public static let empty = LocalEvidence(
            gameVersion: "",
            channel: nil,
            subChannel: nil,
            cps: nil,
            sdkVersion: nil,
            configFields: [],
            pkgVersionEntries: []
        )

        public init(
            gameVersion: String,
            channel: String?,
            subChannel: String?,
            cps: String?,
            sdkVersion: String?,
            configFields: [ConfigIniField] = [],
            pkgVersionEntries: [PkgVersionEntry] = [],
            pkgVersionMapping: PkgVersionMappingStatus? = nil,
            pkgVersionValidationErrors: [String] = [],
            gameID: String? = nil,
            locationRevision: Int? = nil,
            readAt: Date = Date(),
            parseStatus: EvidenceParseStatus? = nil,
            sourceSummary: [String]? = nil
        ) {
            self.gameID = gameID
            self.locationRevision = locationRevision
            self.readAt = readAt
            self.gameVersion = gameVersion
            self.channel = channel
            self.subChannel = subChannel
            self.cps = cps
            self.sdkVersion = sdkVersion
            self.configFields = configFields
            self.pkgVersionEntries = pkgVersionEntries
            self.pkgVersionMapping = pkgVersionMapping ?? (pkgVersionEntries.isEmpty ? .notPresent : .unmapped)
            self.pkgVersionValidationErrors = pkgVersionValidationErrors
            self.parseStatus = parseStatus ?? (pkgVersionEntries.isEmpty ? .configOnly : .configAndPkg)
            self.sourceSummary = sourceSummary ?? (pkgVersionEntries.isEmpty ? ["config.ini"] : ["config.ini", "pkg_version"])
        }
    }

    public struct VersionCheckResult: Sendable, Equatable {
        public let outcome: Outcome
        public let currentVersion: String?
        public let latestVersion: String?
        public let updateAvailable: Bool
        public let localEvidence: LocalEvidence
        public let conflictDetails: [String]

        public static let unknown = VersionCheckResult(
            outcome: .unknown,
            currentVersion: nil,
            latestVersion: nil,
            updateAvailable: false,
            localEvidence: .empty
        )

        public init(
            outcome: Outcome? = nil,
            currentVersion: String?,
            latestVersion: String?,
            updateAvailable: Bool,
            localEvidence: LocalEvidence = .empty,
            conflictDetails: [String] = []
        ) {
            self.outcome = outcome ?? (updateAvailable ? .updateAvailable : .current)
            self.currentVersion = currentVersion
            self.latestVersion = latestVersion
            self.updateAvailable = updateAvailable
            self.localEvidence = localEvidence
            self.conflictDetails = conflictDetails
        }
    }
}
