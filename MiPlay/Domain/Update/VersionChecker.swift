//
//  VersionChecker.swift
//  MiPlay
//

import Foundation

// Source: Architecture Design -> Service Contract -> VersionChecker
// Source: Architecture Design -> ADR 018 -> LocalGameEvidence

/// Compares authorized local evidence with an approved remote version source.
/// It never performs a game update or treats metadata presence as integrity.
public actor VersionChecker {
    /// Official HoyoPlay branch metadata used for version notifications.
    /// The response contains the latest channel branch for all supported
    /// mainland games; it is not a game-file update manifest.
    public static let defaultRemoteManifestURL = URL(
        string: "https://hyp-api.mihoyo.com/hyp/hyp-connect/api/getGameBranches?launcher_id=jGHBHlcOq1&language=zh-cn"
    )!

    private static let remoteGameIDs: [GameType: String] = [
        .genshinImpact: "1Z8W5NHUQb",
        .honkaiStarRail: "64kMb5iAWu",
        .zenlessZoneZero: "x6znKlJ0xK"
    ]

    private struct RemoteVersionEvidence: Sendable {
        let version: String
        let channel: String?
    }

    private let fileSystemRepository: GameFileSystemRepository
    private let networkProvider: NetworkDownloadProvider
    private let logWriter: LogWriter
    private let remoteManifestURL: URL?
    private let injectedLatestVersions: [GameType: String]
    private let injectedLatestChannels: [GameType: String]
    private let integrityManifests: [GameType: FileIntegrityVerifier.Manifest]
    private let gameRegistry: GameRegistry?

    public init(
        fileSystemRepository: GameFileSystemRepository,
        networkProvider: NetworkDownloadProvider,
        logWriter: LogWriter,
        remoteManifestURL: URL? = nil,
        latestVersions: [GameType: String] = [:],
        latestChannels: [GameType: String] = [:],
        integrityManifests: [GameType: FileIntegrityVerifier.Manifest] = [:],
        gameRegistry: GameRegistry? = nil
    ) {
        self.fileSystemRepository = fileSystemRepository
        self.networkProvider = networkProvider
        self.logWriter = logWriter
        self.remoteManifestURL = remoteManifestURL
        self.injectedLatestVersions = latestVersions
        self.injectedLatestChannels = latestChannels
        self.integrityManifests = integrityManifests
        self.gameRegistry = gameRegistry
    }

    public func checkVersion(for game: Game, fileVerification: Bool = false) async throws -> VersionCheckResult {
        guard let location = game.location, location.bookmarkData != nil else {
            throw VersionError.versionFileMissing("游戏目录尚未获得有效授权")
        }
        let access = try fileSystemRepository.acquireSecurityScopedAccess(location)
        defer { access.stop() }
        if access.resolvedLocation.requiresPersistenceUpdate(from: location) {
            guard let gameRegistry else {
                throw VersionError.bookmarkRefreshRequired("缺少 GameRegistry 提交边界")
            }
            do {
                try await gameRegistry.updateResolvedLocation(id: game.id, location: access.resolvedLocation)
            } catch {
                throw VersionError.bookmarkRefreshPersistenceFailed(error.localizedDescription)
            }
        }
        return try await checkVersion(
            for: game.type,
            installPath: access.url.path,
            gameID: game.id,
            locationRevision: access.resolvedLocation.bookmarkVersion,
            fileVerification: fileVerification
        )
    }

    public func checkVersion(for gameType: GameType) async throws -> VersionCheckResult {
        throw VersionError.versionFileMissing("未提供游戏安装目录")
    }

    // The path overload is retained only for tests and legacy migration. The
    // production launch/update path resolves GameLocation first.
    internal func checkVersion(
        for gameType: GameType,
        installPath: String,
        fileVerification: Bool = false
    ) async throws -> VersionCheckResult {
        try await checkVersion(
            for: gameType,
            installPath: installPath,
            gameID: nil,
            locationRevision: nil,
            fileVerification: fileVerification
        )
    }

    private func checkVersion(
        for gameType: GameType,
        installPath: String,
        gameID: String?,
        locationRevision: Int?,
        fileVerification: Bool
    ) async throws -> VersionCheckResult {
        let operationID = UUID()
        await logWriter.record(.init(
            level: .info,
            module: "VersionChecker",
            eventName: "metadata.version_check",
            operationID: operationID,
            gameID: gameID ?? gameType.rawValue,
            phase: "started",
            result: "inProgress",
            messageCode: "metadata.version_check_started"
        ))
        let evidence = try await readLocalEvidence(
            for: gameType,
            installPath: installPath,
            gameID: gameID,
            locationRevision: locationRevision,
            fileVerification: fileVerification
        )
        let remote = try await fetchLatestVersion(for: gameType)
        var conflicts: [String] = []

        if let manifest = integrityManifests[gameType] {
            // A manifest strengthens the version result, but its absence does
            // not make a valid config.ini comparison impossible. Full file
            // integrity remains a separate capability.
            if evidence.pkgVersionMapping != .mapped, !evidence.pkgVersionEntries.isEmpty {
                conflicts.append("pkg_version 条目没有已批准的 Game/渠道/版本映射")
            }
            if !evidence.pkgVersionValidationErrors.isEmpty {
                conflicts.append(contentsOf: evidence.pkgVersionValidationErrors)
            }
            if manifest.gameID != gameType.rawValue {
                conflicts.append("IntegrityManifest 与目标 Game 不匹配")
            }
            if let manifestVersion = manifest.version, manifestVersion != evidence.gameVersion {
                conflicts.append("config.ini.game_version 与 IntegrityManifest 版本冲突")
            }
            if let manifestChannel = manifest.channel {
                if let localChannel = evidence.channel, manifestChannel != localChannel {
                    conflicts.append("config.ini.channel 与 IntegrityManifest 渠道冲突")
                } else if evidence.channel == nil {
                    conflicts.append("config.ini.channel 缺失，无法与 IntegrityManifest 渠道关联")
                }
            }
            if let manifestSubChannel = manifest.subChannel {
                if let localSubChannel = evidence.subChannel {
                    if manifestSubChannel != localSubChannel {
                        conflicts.append("config.ini.sub_channel 与 IntegrityManifest 子渠道冲突")
                    }
                } else {
                    conflicts.append("config.ini.sub_channel 缺失，无法与 IntegrityManifest 子渠道关联")
                }
            }
            if let manifestVersion = manifest.version, manifestVersion != remote.version {
                conflicts.append("IntegrityManifest 版本与官方远程版本冲突")
            }
            if let manifestChannel = manifest.channel,
               let remoteChannel = remote.channel,
               manifestChannel != remoteChannel {
                conflicts.append("IntegrityManifest 渠道与官方远程渠道冲突")
            }
        }

        if let remoteChannel = remote.channel {
            if let localChannel = evidence.channel {
                if remoteChannel != localChannel {
                    conflicts.append("config.ini.channel 与官方远程渠道冲突")
                }
            } else {
                conflicts.append("config.ini.channel 缺失，无法与官方远程渠道关联")
            }
        }

        guard conflicts.isEmpty else {
            await logWriter.record(.init(
                level: .error,
                module: "VersionChecker",
                eventName: "metadata.conflict",
                operationID: operationID,
                gameID: gameID ?? gameType.rawValue,
                phase: "evidence",
                result: "failed",
                errorCategory: "conflict",
                messageCode: "metadata.evidence_conflict",
                fields: [
                    "configPresent": "true",
                    "itemCount": String(evidence.pkgVersionEntries.count)
                ]
            ))
            return VersionCheckResult(
                outcome: .versionEvidenceConflict,
                currentVersion: nil,
                latestVersion: remote.version,
                updateAvailable: false,
                localEvidence: evidence,
                conflictDetails: conflicts
            )
        }

        let updateAvailable = compareVersions(current: evidence.gameVersion, latest: remote.version)
        await logWriter.record(.init(
            level: .info,
            module: "VersionChecker",
            eventName: "metadata.version_check",
            operationID: operationID,
            gameID: gameID ?? gameType.rawValue,
            phase: "completed",
            result: "completed",
            messageCode: updateAvailable ? "metadata.update_available" : "metadata.current",
            fields: ["itemCount": String(evidence.pkgVersionEntries.count)]
        ))
        return VersionCheckResult(
            outcome: updateAvailable ? .updateAvailable : .current,
            currentVersion: evidence.gameVersion,
            latestVersion: remote.version,
            updateAvailable: updateAvailable,
            localEvidence: evidence
        )
    }

    private func readLocalEvidence(
        for gameType: GameType,
        installPath: String,
        gameID: String?,
        locationRevision: Int?,
        fileVerification: Bool
    ) async throws -> LocalEvidence {
        let url = URL(fileURLWithPath: installPath, isDirectory: true)
            .appendingPathComponent(gameType.versionFileRelativePath)
        guard fileSystemRepository.validatePath(url.path) else {
            throw VersionError.versionFileMissing(url.lastPathComponent)
        }

        let data: Data
        do {
            data = try await fileSystemRepository.readFile(at: url.path)
        } catch let error as GameFileSystemRepository.FileError {
            switch error {
            case .fileNotFound, .directoryNotFound:
                throw VersionError.versionFileMissing(url.path)
            default:
                throw VersionError.fileReadFailed(error.localizedDescription)
            }
        } catch {
            throw VersionError.fileReadFailed(error.localizedDescription)
        }

        guard let text = String(data: data, encoding: .utf8) else {
            throw VersionError.versionParseFailed("config.ini 不是有效 UTF-8")
        }

        var general: [String: String] = [:]
        var configFields: [ConfigIniField] = []
        var section = ""
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty || line.hasPrefix(";") || line.hasPrefix("#") { continue }
            if line.hasPrefix("[") && line.hasSuffix("]") {
                section = String(line.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                continue
            }
            guard !section.isEmpty, let separator = line.firstIndex(of: "=") else { continue }
            let key = String(line[..<separator]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: separator)...])
                .trimmingCharacters(in: .whitespaces)
            configFields.append(ConfigIniField(section: section, key: key, value: value))
            if section == "General", ["game_version", "channel", "sub_channel", "cps", "sdk_version"].contains(key) {
                general[key] = value.trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            }
        }

        guard let current = general["game_version"], isVersion(current) else {
            throw VersionError.versionParseFailed("未在 [General] 中找到有效 game_version")
        }

        let entries = try await parsePkgVersion(
            at: URL(fileURLWithPath: installPath, isDirectory: true)
        )
        // 逐文件 MD5 校验在两种情况下执行：显式请求（用户在设置里点"校验文件
        // 完整性"）或配置了校验清单。常规版本检查只比较声明版本，避免每次
        // 启动都全量扫盘（原神 2743 个条目 ≈ 4.5 分钟 I/O）。
        let performsFileVerification = fileVerification || integrityManifests[gameType] != nil
        let pkgValidationErrors = performsFileVerification
            ? try await validatePkgVersionEntries(
                at: URL(fileURLWithPath: installPath, isDirectory: true),
                entries: entries
            )
            : []
        let mapping: PkgVersionMappingStatus
        if entries.isEmpty {
            mapping = .notPresent
        } else if let manifest = integrityManifests[gameType], !manifest.files.isEmpty,
                  pkgValidationErrors.isEmpty,
                  entries.allSatisfy({ entry in
                      guard manifest.files[entry.remoteName] != nil else { return false }
                      if let expectedSize = manifest.fileSizes[entry.remoteName] {
                          return expectedSize == entry.fileSize
                      }
                      return true
                  }) {
            mapping = .mapped
        } else {
            mapping = .unmapped
        }
        await logWriter.record(.init(
            level: pkgValidationErrors.isEmpty ? .info : .warning,
            module: "VersionChecker",
            eventName: "metadata.local_evidence",
            gameID: gameID ?? gameType.rawValue,
            phase: "parsed",
            result: pkgValidationErrors.isEmpty ? "completed" : "failed",
            errorCategory: pkgValidationErrors.isEmpty ? "none" : "integrityFailed",
            messageCode: pkgValidationErrors.isEmpty ? "metadata.local_evidence_parsed" : "metadata.pkg_evidence_invalid",
            fields: [
                "configPresent": "true",
                "itemCount": String(entries.count),
                "md5Present": entries.isEmpty ? "false" : "true",
                "sizePresent": entries.isEmpty ? "false" : "true",
                "fileVerification": performsFileVerification ? "full" : "declaredOnly"
            ]
        ))
        return LocalEvidence(
            gameVersion: current,
            channel: general["channel"],
            subChannel: general["sub_channel"],
            cps: general["cps"],
            sdkVersion: general["sdk_version"],
            configFields: configFields,
            pkgVersionEntries: entries,
            pkgVersionMapping: mapping,
            pkgVersionValidationErrors: pkgValidationErrors,
            fileVerificationPerformed: performsFileVerification,
            gameID: gameID,
            locationRevision: locationRevision,
            sourceSummary: entries.isEmpty ? ["config.ini"] : ["config.ini", "pkg_version"]
        )
    }

    private func parsePkgVersion(at installURL: URL) async throws -> [PkgVersionEntry] {
        let url = installURL.appendingPathComponent("pkg_version")
        guard fileSystemRepository.validatePath(url.path) else { return [] }

        let data: Data
        do {
            data = try await fileSystemRepository.readFile(at: url.path)
        } catch {
            throw VersionError.fileReadFailed("pkg_version: \(error.localizedDescription)")
        }

        let lines = String(decoding: data, as: UTF8.self)
            .split(whereSeparator: \.isNewline)
        guard !lines.isEmpty else {
            throw VersionError.versionParseFailed("pkg_version 为空")
        }

        var entries: [PkgVersionEntry] = []
        for line in lines {
            do {
                let entry = try JSONDecoder().decode(PkgVersionEntry.self, from: Data(line.utf8))
                guard isSafeRelativePath(entry.remoteName),
                      entry.fileSize >= 0,
                      entry.md5.count == 32,
                      entry.md5.allSatisfy(\.isHexDigit) else {
                    throw VersionError.versionParseFailed("pkg_version 条目字段无效")
                }
                entries.append(entry)
            } catch let error as VersionError {
                throw error
            } catch {
                throw VersionError.versionParseFailed("pkg_version JSON Lines 无效: \(error.localizedDescription)")
            }
        }
        return entries
    }

    /// Validates the declared pkg_version facts while the caller's bookmark
    /// lease is still active. This does not replace manifest verification.
    private func validatePkgVersionEntries(
        at installURL: URL,
        entries: [PkgVersionEntry]
    ) async throws -> [String] {
        var errors: [String] = []
        for entry in entries {
            try Task.checkCancellation()
            let fileURL = installURL.appendingPathComponent(entry.remoteName).standardizedFileURL
            guard fileURL.path.hasPrefix(installURL.standardizedFileURL.path + "/") else {
                errors.append("pkg_version 路径越界: \(entry.remoteName)")
                continue
            }
            do {
                let actualSize = try await fileSystemRepository.fileSize(at: fileURL.path)
                guard actualSize == UInt64(entry.fileSize) else {
                    errors.append("pkg_version 大小不匹配: \(entry.remoteName)")
                    continue
                }
                let actualMD5 = try await fileSystemRepository.calculateMD5(of: fileURL.path)
                guard actualMD5.caseInsensitiveCompare(entry.md5) == .orderedSame else {
                    errors.append("pkg_version MD5 不匹配: \(entry.remoteName)")
                    continue
                }
            } catch {
                errors.append("pkg_version 文件无法验证: \(entry.remoteName): \(error.localizedDescription)")
            }
        }
        return errors
    }

    private func fetchLatestVersion(for gameType: GameType) async throws -> RemoteVersionEvidence {
        if let injected = injectedLatestVersions[gameType] {
            guard isVersion(injected) else { throw VersionError.versionParseFailed(injected) }
            return RemoteVersionEvidence(version: injected, channel: injectedLatestChannels[gameType])
        }
        guard let remoteManifestURL else {
            throw VersionError.apiUnavailable("未配置官方版本 manifest")
        }
        do {
            let data = try await networkProvider.requestData(from: remoteManifestURL)
            if let branchesResponse = try? JSONDecoder().decode(HoyoPlayBranchesResponse.self, from: data),
               let gameID = Self.remoteGameIDs[gameType],
               let branch = branchesResponse.data.gameBranches.first(where: { $0.game.id == gameID }) {
                guard isVersion(branch.main.tag) else {
                    throw VersionError.versionParseFailed(branch.main.tag)
                }
                return RemoteVersionEvidence(
                    version: branch.main.tag,
                    channel: "1"
                )
            }

            if let direct = try? JSONDecoder().decode([String: String].self, from: data),
               let value = direct[gameType.rawValue] {
                guard isVersion(value) else { throw VersionError.versionParseFailed(value) }
                return RemoteVersionEvidence(version: value, channel: nil)
            }

            struct Envelope: Decodable {
                let versions: [String: String]
                let channels: [String: String]?
            }
            let envelope = try JSONDecoder().decode(Envelope.self, from: data)
            guard let value = envelope.versions[gameType.rawValue], isVersion(value) else {
                throw VersionError.apiUnavailable("manifest 中没有 \(gameType.rawValue)")
            }
            return RemoteVersionEvidence(
                version: value,
                channel: envelope.channels?[gameType.rawValue]
            )
        } catch let error as VersionError {
            throw error
        } catch {
            await logWriter.error("获取官方版本失败: \(error.localizedDescription)", module: "VersionChecker")
            await logWriter.record(.init(
                level: .error,
                module: "VersionChecker",
                eventName: "metadata.remote_manifest",
                gameID: gameType.rawValue,
                phase: "request",
                result: "failed",
                errorCategory: "networkUnavailable",
                messageCode: "metadata.remote_manifest_failed"
            ))
            throw VersionError.networkError(error.localizedDescription)
        }
    }

    private func isSafeRelativePath(_ path: String) -> Bool {
        guard !path.isEmpty, !path.hasPrefix("/") else { return false }
        let components = path.split(separator: "/")
        return !components.isEmpty && !components.contains("..") && !path.contains("\\")
    }

    private func isVersion(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let components = trimmed.split(separator: ".")
        return !components.isEmpty &&
            components.allSatisfy { $0.allSatisfy { $0.isNumber || $0 == "-" || $0.isLetter } }
    }

    private func compareVersions(current: String, latest: String) -> Bool {
        let currentParts = current.split(separator: ".").map { Int($0.filter { $0.isNumber }) ?? 0 }
        let latestParts = latest.split(separator: ".").map { Int($0.filter { $0.isNumber }) ?? 0 }
        for index in 0..<max(currentParts.count, latestParts.count) {
            let currentValue = index < currentParts.count ? currentParts[index] : 0
            let latestValue = index < latestParts.count ? latestParts[index] : 0
            if currentValue != latestValue { return latestValue > currentValue }
        }
        return false
    }
}

nonisolated private struct HoyoPlayBranchesResponse: Decodable, Sendable {
    let data: HoyoPlayBranchesData
}

nonisolated private struct HoyoPlayBranchesData: Decodable, Sendable {
    let gameBranches: [HoyoPlayBranch]

    enum CodingKeys: String, CodingKey {
        case gameBranches = "game_branches"
    }
}

nonisolated private struct HoyoPlayBranch: Decodable, Sendable {
    let game: HoyoPlayGame
    let main: HoyoPlayMainBranch
}

nonisolated private struct HoyoPlayGame: Decodable, Sendable {
    let id: String
}

nonisolated private struct HoyoPlayMainBranch: Decodable, Sendable {
    let tag: String
}
