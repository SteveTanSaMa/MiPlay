// WineVersionManagerInstalled.swift
// MiPlay

import Foundation

// Source: Architecture Design -> ADR 037/042 -> one non-deletable runtime
extension WineVersionManager {
    /// Compatibility projection for existing callers. The returned collection
    /// contains zero or one fixed runtime and never exposes alternatives.
    public func getInstalledVersions() async -> [WineVersionInfo] {
        guard let record = runtimeRecord,
              record.identity == Self.fixedRuntimeTag,
              FileManager.default.isExecutableFile(atPath: record.binaryPath) else {
            return []
        }
        let source = BuiltInWineVersions.source(for: Self.fixedRuntimeTag)
        return [WineVersionInfo(
            id: Self.fixedRuntimeTag,
            tagName: Self.fixedRuntimeTag,
            name: source?.displayName ?? Self.fixedRuntimeTag,
            downloadURL: URL(string: "about:blank")!,
            fileSize: 0,
            publishedAt: Date(),
            sourceID: record.sourceID,
            policyRevision: "2026-08-28",
            assetName: record.assetName,
            isDownloaded: true,
            isSelected: true
        )]
    }

    /// Commits the single managed runtime record after binary validation.
    public func markVersionInstalled(tagName: String) async throws {
        guard tagName == Self.fixedRuntimeTag else {
            throw VersionManagerError.versionNotFound(tagName)
        }
        let versionsDir = await wineVersionsDirectory()
        let finalURL = versionsDir.appendingPathComponent(Self.fixedRuntimeTag, isDirectory: true)
        let canonicalRoot = versionsDir.resolvingSymlinksInPath().standardizedFileURL
        let canonicalVersion = finalURL.resolvingSymlinksInPath().standardizedFileURL
        let binary = canonicalVersion.appendingPathComponent("bin/wine")
        guard canonicalVersion.path.hasPrefix(canonicalRoot.path + "/"),
              FileManager.default.fileExists(atPath: binary.path) else {
            throw VersionManagerError.extractionFailed("固定 Wine binary 不存在: \(binary.path)")
        }

        // tar archives can carry a mode that macOS does not preserve as
        // executable after a sandboxed move. Normalize the entry at the
        // managed boundary before accepting the runtime.
        do {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: binary.path
            )
        } catch {
            throw VersionManagerError.extractionFailed(
                "固定 Wine binary 权限设置失败: \(binary.path): \(error.localizedDescription)"
            )
        }
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            let permissions = (try? FileManager.default.attributesOfItem(atPath: binary.path)[.posixPermissions]) as? NSNumber
            let mode = permissions.map { String(format: "%03o", $0.intValue & 0o777) } ?? "未知"
            throw VersionManagerError.extractionFailed(
                "固定 Wine binary 不可执行: \(binary.path)，权限 \(mode)"
            )
        }

        let record = ManagedWineRuntimeRecord(
            identity: Self.fixedRuntimeTag,
            sourceID: BuiltInWineVersions.officialSource.sourceID,
            assetName: cachedAvailableVersion(tagName: Self.fixedRuntimeTag)?.assetName
                ?? "wine-crossover-11.0-1-osx64-signed.tar.xz",
            rootPath: canonicalVersion.path,
            binaryPath: binary.path,
            architecture: "arm64",
            revision: UUID().uuidString,
            state: "installed",
            verifiedAt: Date()
        )
        try await persistenceStore.updateAppData { appData in
            appData.managedWineRuntime = record
        }
        let committed = try await persistenceStore.readAppData()
        guard let verified = committed.managedWineRuntime,
              verified.identity == record.identity,
              verified.sourceID == record.sourceID,
              verified.assetName == record.assetName,
              verified.rootPath == record.rootPath,
              verified.binaryPath == record.binaryPath,
              verified.architecture == record.architecture,
              verified.revision == record.revision,
              verified.state == record.state else {
            throw VersionManagerError.persistenceFailed("固定 Wine 安装记录写回后重读不一致")
        }
        runtimeRecord = record
        selectedVersionTag = Self.fixedRuntimeTag
        installedVersionTags = [Self.fixedRuntimeTag]
        await logWriter.record(.init(
            level: .info,
            module: "WineVersionManager",
            eventName: "wine.install.commit",
            wineTag: Self.fixedRuntimeTag,
            phase: "installedRecord",
            result: "completed",
            messageCode: "wine.install_record_committed",
            fields: ["persistence": "verified", "runtimeIdentity": Self.fixedRuntimeTag]
        ))
    }

    /// The current runtime/shared prefix is a protected pair and has no user
    /// deletion path in the fixed-runtime product.
    public func deleteVersion(tagName: String) async throws {
        guard tagName == Self.fixedRuntimeTag else {
            throw VersionManagerError.versionNotFound(tagName)
        }
        throw VersionManagerError.recoveryRequired("当前固定 Wine runtime 与共享 prefix 不提供删除操作")
    }
}
