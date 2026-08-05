//
//  FileIntegrityVerifier.swift
//  MiPlay
//
//  Created by Steve Tan on 2026/7/7.
//

import Foundation

// Source: Architecture Design -> Service Contract -> FileIntegrityVerifier
// Source: Architecture Design -> Domain Model -> IntegrityCheckResult

/// Verifies every entry in a versioned, non-empty manifest. No manifest means that
/// integrity is unsupported; file existence alone is not a positive result.
public actor FileIntegrityVerifier {
    public enum VerificationError: Error, LocalizedError, Sendable {
        case pathNotAccessible(String)
        case readFailed(String)
        case manifestMissing(String)
        case bookmarkRefreshRequired(String)
        case bookmarkRefreshPersistenceFailed(String)

        public var errorDescription: String? {
            switch self {
            case .pathNotAccessible(let path): return "路径不可达: \(path)"
            case .readFailed(let detail): return "文件读取失败: \(detail)"
            case .manifestMissing(let detail): return "校验清单缺失: \(detail)"
            case .bookmarkRefreshRequired(let detail): return "授权凭据需要刷新并保存: \(detail)"
            case .bookmarkRefreshPersistenceFailed(let detail): return "授权凭据刷新保存失败: \(detail)"
            }
        }
    }

    public enum VerificationStatus: String, Sendable, Equatable {
        case passed = "IntegrityPassed"
        case failed = "IntegrityFailed"
        case unsupported = "IntegrityUnsupported"
        case cancelled = "Cancelled"
    }

    public struct Manifest: Codable, Sendable, Equatable {
        public let gameID: String
        public let version: String?
        public let channel: String?
        public let subChannel: String?
        public let files: [String: String]
        public let fileSizes: [String: Int64]

        public init(
            gameID: String,
            version: String? = nil,
            channel: String? = nil,
            subChannel: String? = nil,
            files: [String: String],
            fileSizes: [String: Int64] = [:]
        ) {
            self.gameID = gameID
            self.version = version
            self.channel = channel
            self.subChannel = subChannel
            self.files = files
            self.fileSizes = fileSizes
        }
    }

    public struct VerificationResult: Sendable, Equatable {
        public let status: VerificationStatus
        public let passed: Bool
        public let totalFiles: Int
        public let verifiedFiles: Int
        public let missingFiles: [String]
        public let corruptedFiles: [String]
        public let extraFiles: [String]
        public let errors: [String]

        public init(
            status: VerificationStatus,
            totalFiles: Int,
            verifiedFiles: Int,
            missingFiles: [String] = [],
            corruptedFiles: [String] = [],
            extraFiles: [String] = [],
            errors: [String] = []
        ) {
            self.status = status
            self.passed = status == .passed
            self.totalFiles = totalFiles
            self.verifiedFiles = verifiedFiles
            self.missingFiles = missingFiles
            self.corruptedFiles = corruptedFiles
            self.extraFiles = extraFiles
            self.errors = errors
        }

        public static let empty = VerificationResult(status: .unsupported, totalFiles: 0, verifiedFiles: 0)
    }

    private let fileSystemRepository: GameFileSystemRepository
    private let gameRegistry: GameRegistry?
    private let injectedManifests: [GameType: Manifest]
    private let logWriter: LogWriter?

    public init(
        fileSystemRepository: GameFileSystemRepository,
        manifests: [GameType: Manifest] = [:],
        gameRegistry: GameRegistry? = nil,
        logWriter: LogWriter? = nil
    ) {
        self.fileSystemRepository = fileSystemRepository
        self.injectedManifests = manifests
        self.gameRegistry = gameRegistry
        self.logWriter = logWriter
    }

    public func verify(gameType: GameType) async throws -> VerificationResult {
        throw VerificationError.pathNotAccessible("未设置安装路径")
    }

    public func verify(game: Game) async throws -> VerificationResult {
        guard let location = game.location, location.bookmarkData != nil else {
            throw VerificationError.pathNotAccessible("游戏目录尚未获得有效授权")
        }
        let access = try fileSystemRepository.acquireSecurityScopedAccess(location)
        defer { access.stop() }
        if access.resolvedLocation.requiresPersistenceUpdate(from: location) {
            guard let gameRegistry else {
                throw VerificationError.bookmarkRefreshRequired("缺少 GameRegistry 提交边界")
            }
            do {
                try await gameRegistry.updateResolvedLocation(id: game.id, location: access.resolvedLocation)
            } catch {
                throw VerificationError.bookmarkRefreshPersistenceFailed(error.localizedDescription)
            }
        }
        return try await verify(
                gameType: game.type,
                installPath: access.url.path,
                expectedVersion: game.version
        )
    }

    /// Testable and scoped callers use this method while they hold the bookmark scope.
    /// Internal scoped test seam. Production callers must use `verify(game:)`,
    /// which owns bookmark resolution, stale refresh and the access lease.
    internal func verify(
        gameType: GameType,
        installPath: String?,
        expectedVersion: String? = nil
    ) async throws -> VerificationResult {
        await logWriter?.record(.init(
            level: .info,
            module: "FileIntegrityVerifier",
            eventName: "integrity.start",
            gameID: gameType.rawValue,
            phase: "verify",
            result: "inProgress",
            messageCode: "integrity.start"
        ))
        guard let path = installPath, fileSystemRepository.validatePath(path) else {
            await logWriter?.record(.init(
                level: .error,
                module: "FileIntegrityVerifier",
                eventName: "integrity.result",
                gameID: gameType.rawValue,
                phase: "verify",
                result: "failed",
                errorCategory: "permissionDenied",
                messageCode: "integrity.path_unavailable"
            ))
            throw VerificationError.pathNotAccessible(installPath ?? "未设置安装路径")
        }
        guard let manifest = try loadManifest(for: gameType) else {
            await logWriter?.record(.init(
                level: .warning,
                module: "FileIntegrityVerifier",
                eventName: "integrity.manifest",
                gameID: gameType.rawValue,
                phase: "manifest",
                result: "unavailable",
                errorCategory: "integrityUnsupported",
                messageCode: "integrity.manifest_missing"
            ))
            return VerificationResult(
                status: .unsupported,
                totalFiles: 0,
                verifiedFiles: 0,
                errors: ["当前版本没有可用的完整性校验清单"]
            )
        }
        guard manifest.gameID == gameType.rawValue, !manifest.files.isEmpty else {
            await logWriter?.record(.init(
                level: .error,
                module: "FileIntegrityVerifier",
                eventName: "integrity.manifest",
                gameID: gameType.rawValue,
                phase: "manifest",
                result: "failed",
                errorCategory: "conflict",
                messageCode: "integrity.manifest_mismatch",
                fields: ["fileCount": String(manifest.files.count)]
            ))
            return VerificationResult(
                status: .unsupported,
                totalFiles: manifest.files.count,
                verifiedFiles: 0,
                errors: ["校验清单与游戏或版本不匹配"]
            )
        }
        guard manifest.version == nil || manifest.version == expectedVersion else {
            await logWriter?.record(.init(
                level: .error,
                module: "FileIntegrityVerifier",
                eventName: "integrity.manifest",
                gameID: gameType.rawValue,
                phase: "manifest",
                result: "failed",
                errorCategory: "conflict",
                messageCode: "integrity.manifest_version_conflict"
            ))
            return VerificationResult(
                status: .unsupported,
                totalFiles: manifest.files.count,
                verifiedFiles: 0,
                errors: ["校验清单版本与当前游戏版本不匹配或无法确认"]
            )
        }
        let result = try await verifyFiles(at: path, manifest: manifest)
        await logWriter?.record(.init(
            level: result.status == .passed ? .info : .warning,
            module: "FileIntegrityVerifier",
            eventName: "integrity.result",
            gameID: gameType.rawValue,
            phase: "verify",
            result: result.status == .passed ? "completed" : "failed",
            errorCategory: result.status == .passed ? "none" : "integrityFailed",
            messageCode: result.status == .passed ? "integrity.passed" : "integrity.failed",
            fields: [
                "fileCount": String(result.totalFiles),
                "changed": String(result.corruptedFiles.count)
            ]
        ))
        return result
    }

    // MARK: - Manifest and verification

    private func loadManifest(for gameType: GameType) throws -> Manifest? {
        if let injected = injectedManifests[gameType], !injected.files.isEmpty { return injected }

        let resourceName = gameType.rawValue
        guard let url = Bundle.main.url(
            forResource: resourceName,
            withExtension: "json",
            subdirectory: "IntegrityManifests"
        ) ?? Bundle.main.url(forResource: resourceName, withExtension: "json") else {
            return nil
        }
        do {
            return try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: url))
        } catch {
            throw VerificationError.manifestMissing("清单无法读取: \(error.localizedDescription)")
        }
    }

    private func verifyFiles(at path: String, manifest: Manifest) async throws -> VerificationResult {
        var missing: [String] = []
        var corrupted: [String] = []
        var verified = 0

        for (relativePath, expectedHash) in manifest.files.sorted(by: { $0.key < $1.key }) {
            try Task.checkCancellation()
            let fileURL = URL(fileURLWithPath: path, isDirectory: true)
                .appendingPathComponent(relativePath)
                .standardizedFileURL
            guard fileURL.path.hasPrefix(URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL.path + "/"),
                  fileSystemRepository.validatePath(fileURL.path) else {
                missing.append(relativePath)
                continue
            }
            do {
                if let expectedSize = manifest.fileSizes[relativePath],
                   try await fileSystemRepository.fileSize(at: fileURL.path) != UInt64(expectedSize) {
                    corrupted.append(relativePath)
                    continue
                }
                let actual = try await fileSystemRepository.calculateSHA256(of: fileURL.path)
                if actual.caseInsensitiveCompare(expectedHash) == .orderedSame { verified += 1 }
                else { corrupted.append(relativePath) }
            } catch {
                throw VerificationError.readFailed("\(relativePath): \(error.localizedDescription)")
            }
        }

        return VerificationResult(
            status: missing.isEmpty && corrupted.isEmpty ? .passed : .failed,
            totalFiles: manifest.files.count,
            verifiedFiles: verified,
            missingFiles: missing,
            corruptedFiles: corrupted
        )
    }
}
