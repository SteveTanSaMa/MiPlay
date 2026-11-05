// WineVersionManagerDownload.swift
// MiPlay

import Foundation

// Source: Architecture Design -> WineVersionManager -> download and recovery orchestration
extension WineVersionManager {
    // MARK: - 版本下载编排

    /// 下载并安装指定版本的 Wine（编排完整流程）
    /// - Parameter version: 要下载的版本信息
    /// - Returns: 进度流
    internal func downloadAndInstall(
        version: WineVersionInfo,
        taskID: UUID = UUID()
    ) -> AsyncStream<WineVersionDownloader.DownloadPhase> {
        return AsyncStream { continuation in
            let operation = Task { [weak self] in
                guard let self else { return }
                var stagingPath: String?
                var installedPath: String?
                var runtimeCommitted = false
                var prefixCommitted = false
                do {
                    await self.logWriter.record(.init(
                        level: .info,
                        module: "WineVersionManager",
                        eventName: "wine.install",
                        operationID: taskID,
                        taskID: taskID.uuidString,
                        wineTag: version.tagName,
                        phase: "started",
                        result: "inProgress",
                        messageCode: "wine.install_started",
                        fields: ["sourceID": version.sourceID, "policyRevision": version.policyRevision]
                    ))
                    await self.registerDownload(taskID: taskID, tagName: version.tagName)
                    try await self.validateCatalogEntry(version)
                    let versionsDir = await self.wineVersionsDirectory()
                    let finalURL = versionsDir.appendingPathComponent(version.tagName, isDirectory: true)
                    let wineBinary = finalURL.appendingPathComponent("bin/wine")
                    if FileManager.default.fileExists(atPath: wineBinary.path) {
                        try await self.markVersionInstalled(tagName: version.tagName)
                        runtimeCommitted = true
                        try await self.prepareAndCommitSharedPrefix(
                            runtime: ManagedWineRuntime(tagName: Self.fixedRuntimeTag, rootURL: finalURL)
                        )
                        prefixCommitted = true
                        continuation.yield(.installed(versionPath: finalURL.path))
                        continuation.yield(.completed(versionPath: finalURL.path))
                        continuation.finish()
                        return
                    }

                    let stagingRoot = versionsDir.appendingPathComponent(".staging", isDirectory: true)
                    let stageURL = stagingRoot
                        .appendingPathComponent("\(taskID.uuidString)-\(version.tagName)", isDirectory: true)
                    try FileManager.default.createDirectory(at: stageURL, withIntermediateDirectories: true)
                    let staging = try WineVersionDownloader.ManagedStaging(
                        rootURL: stagingRoot,
                        directoryURL: stageURL
                    )
                    stagingPath = staging.directoryURL.path

                    let approvedAsset = WineVersionDownloader.ApprovedAsset(
                        sourceID: version.sourceID,
                        tagName: version.tagName,
                        url: version.downloadURL,
                        assetName: version.assetName.isEmpty ? version.downloadURL.lastPathComponent : version.assetName,
                        fileSize: version.fileSize,
                        expectedSHA256: version.expectedSHA256
                    )
                    let downloadStream = await self.wineVersionDownloader.downloadAndExtract(
                        asset: approvedAsset,
                        staging: staging,
                        sessionID: taskID
                    )

                    var receivedCompletion = false
                    for await phase in downloadStream {
                        if Task.isCancelled { throw CancellationError() }
                        switch phase {
                        case .completed:
                            receivedCompletion = true
                            continuation.yield(.extracting(progress: 1))
                        case .failed(let detail):
                            throw VersionManagerError.downloadFailed(detail)
                        case .failedWithFailure(let failure):
                            // Preserve the asset transport fact through the
                            // manager stream. The scheduler/UI can project a
                            // 403, 404, 429 or 5xx without string matching.
                            continuation.yield(.failedWithFailure(failure))
                            continuation.finish()
                            return
                        case .cancelled:
                            throw CancellationError()
                        case .recoveryRequired(let detail):
                            throw VersionManagerError.recoveryRequired(detail)
                        default:
                            continuation.yield(phase)
                        }
                    }

                    // A cancelled stream can end without yielding a terminal phase.
                    // Never interpret the cleaned staging directory as an extraction failure.
                    try Task.checkCancellation()
                    guard receivedCompletion else {
                        throw VersionManagerError.downloadFailed("Wine 下载未产生完成事实")
                    }

                    let stagedWineBinary = wineBinaryFor(staging.directoryURL)
                    guard FileManager.default.fileExists(atPath: stagedWineBinary.path) else {
                        throw VersionManagerError.extractionFailed("解压后未找到 wine binary: \(stagedWineBinary.path)")
                    }
                    do {
                        try FileManager.default.setAttributes(
                            [.posixPermissions: 0o755],
                            ofItemAtPath: stagedWineBinary.path
                        )
                    } catch {
                        throw VersionManagerError.extractionFailed(
                            "解压后无法设置 wine binary 权限: \(stagedWineBinary.path): \(error.localizedDescription)"
                        )
                    }
                    guard FileManager.default.isExecutableFile(atPath: stagedWineBinary.path) else {
                        throw VersionManagerError.extractionFailed(
                            "解压后 wine binary 不可执行: \(stagedWineBinary.path)"
                        )
                    }

                    continuation.yield(.installing)
                    if FileManager.default.fileExists(atPath: finalURL.path) {
                        throw VersionManagerError.downloadFailed("目标 Wine 版本目录已存在，未覆盖已有文件")
                    }
                    try FileManager.default.moveItem(at: staging.directoryURL, to: finalURL)
                    stagingPath = nil
                    installedPath = finalURL.path

                    let installedWineBinary = wineBinaryFor(finalURL)
                    try FileManager.default.setAttributes(
                        [.posixPermissions: 0o755],
                        ofItemAtPath: installedWineBinary.path
                    )

                    do {
                        try await self.markVersionInstalled(tagName: version.tagName)
                        runtimeCommitted = true
                        continuation.yield(.installed(versionPath: finalURL.path))
                        try await self.prepareAndCommitSharedPrefix(
                            runtime: ManagedWineRuntime(tagName: Self.fixedRuntimeTag, rootURL: finalURL)
                        )
                        prefixCommitted = true
                    } catch let persistenceError {
                        if runtimeCommitted {
                            let detail = "Wine runtime/prefix pair 提交失败: \(persistenceError.localizedDescription)"
                            let record = RecoveryRecord(
                                kind: "wineRuntimeSetup",
                                taskID: taskID.uuidString,
                                target: Self.fixedRuntimeTag,
                                phase: "runtimePairCommit",
                                detail: detail,
                                payload: [
                                    "runtimePath": finalURL.path,
                                    "prefixIdentity": Self.sharedPrefixIdentity
                                ]
                            )
                            let recoveryWriteError = await self.recordRecovery(record)
                            continuation.yield(.recoveryRequired(recoveryWriteError.map { "\(detail); 恢复事实写入失败: \($0)" } ?? detail))
                            continuation.finish()
                            return
                        }
                        do {
                            try FileManager.default.removeItem(at: finalURL)
                            installedPath = nil
                        } catch {
                            let detail = "安装记录写入失败: \(persistenceError.localizedDescription); 最终目录清理失败: \(error.localizedDescription)"
                            let record = RecoveryRecord(
                                kind: "wineRuntimeSetup",
                                taskID: taskID.uuidString,
                                target: Self.fixedRuntimeTag,
                                phase: "runtimeRecord",
                                detail: detail,
                                payload: ["runtimePath": finalURL.path]
                            )
                            let recoveryWriteError = await self.recordRecovery(record)
                            continuation.yield(.recoveryRequired(recoveryWriteError.map { "\(detail); 恢复事实写入失败: \($0)" } ?? detail))
                            continuation.finish()
                            return
                        }
                        throw persistenceError
                    }

                    continuation.yield(.completed(versionPath: finalURL.path))
                    await self.logWriter.record(.init(
                        level: .info,
                        module: "WineVersionManager",
                        eventName: "wine.install",
                        operationID: taskID,
                        taskID: taskID.uuidString,
                        wineTag: version.tagName,
                        phase: "completed",
                        result: "completed",
                        messageCode: "wine.install_completed",
                        fields: ["persistence": "verified", "cleanupVerified": "true"]
                    ))
                    continuation.finish()
                } catch is CancellationError {
                    var cleanupVerified = true
                    do {
                        let paths = [stagingPath, runtimeCommitted ? nil : installedPath].compactMap { $0 }
                        try await self.cleanup(paths: paths)
                    } catch {
                        cleanupVerified = false
                        let detail = "取消后的 Wine 临时资源清理失败: \(error.localizedDescription)"
                        let record = RecoveryRecord(
                            kind: "wineRuntimeSetup",
                            taskID: taskID.uuidString,
                            target: Self.fixedRuntimeTag,
                            phase: "cancelCleanup",
                            detail: detail,
                            payload: [
                                "stagingPath": stagingPath ?? "",
                                "runtimePath": installedPath ?? "",
                                "runtimeCommitted": String(runtimeCommitted),
                                "prefixCommitted": String(prefixCommitted)
                            ]
                        )
                        let recoveryWriteError = await self.recordRecovery(record)
                        continuation.yield(.recoveryRequired(recoveryWriteError.map { "\(detail); 恢复事实写入失败: \($0)" } ?? detail))
                    }
                    if cleanupVerified {
                        continuation.yield(.cancelled)
                    }
                    await self.logWriter.record(.init(
                        level: .warning,
                        module: "WineVersionManager",
                        eventName: "wine.install",
                        operationID: taskID,
                        taskID: taskID.uuidString,
                        wineTag: version.tagName,
                        phase: "cancelCleanup",
                        result: cleanupVerified ? "cancelled" : "recoveryRequired",
                        errorCategory: cleanupVerified ? "userCancelled" : "cancellationUnconfirmed",
                        messageCode: cleanupVerified ? "wine.install_cancelled" : "wine.install_cancel_cleanup_failed",
                        fields: ["cleanupVerified": String(cleanupVerified)]
                    ))
                    continuation.finish()
                } catch {
                    let operationError = error.localizedDescription
                    var cleanupVerified = true
                    do {
                        try await self.cleanup(paths: [stagingPath].compactMap { $0 })
                        continuation.yield(.failed(operationError))
                    } catch {
                        cleanupVerified = false
                        let detail = "\(operationError); 临时资源清理失败: \(error.localizedDescription)"
                        let record = RecoveryRecord(
                        kind: "wineRuntimeSetup",
                        taskID: taskID.uuidString,
                        target: Self.fixedRuntimeTag,
                        phase: "failureCleanup",
                        detail: detail,
                        payload: [
                            "stagingPath": stagingPath ?? "",
                            "runtimePath": installedPath ?? "",
                            "runtimeCommitted": String(runtimeCommitted),
                            "prefixCommitted": String(prefixCommitted)
                        ]
                        )
                        let recoveryWriteError = await self.recordRecovery(record)
                        continuation.yield(.recoveryRequired(recoveryWriteError.map { "\(detail); 恢复事实写入失败: \($0)" } ?? detail))
                    }
                    await self.logWriter.record(.init(
                        level: .error,
                        module: "WineVersionManager",
                        eventName: "wine.install",
                        operationID: taskID,
                        taskID: taskID.uuidString,
                        wineTag: version.tagName,
                        phase: "failed",
                        result: cleanupVerified ? "failed" : "recoveryRequired",
                        errorCategory: cleanupVerified ? "unknown" : "recoveryRequired",
                        messageCode: cleanupVerified ? "wine.install_failed" : "wine.install_cleanup_failed",
                        fields: ["cleanupVerified": String(cleanupVerified)]
                    ))
                    continuation.finish()
                }
                await self.removeDownloadTask(taskID: taskID)
            }
            activeDownloadTasks[taskID] = operation
            continuation.onTermination = { @Sendable _ in
                operation.cancel()
                Task { await self.cancelDownload(taskID: taskID) }
            }
        }
    }

    internal func cancelDownload(taskID: UUID) async {
        let operation = activeDownloadTasks.removeValue(forKey: taskID)
        activeDownloadTags.removeValue(forKey: taskID)
        operation?.cancel()
        await wineVersionDownloader.cancel(sessionID: taskID)
        await operation?.value
    }

    internal func removeDownloadTask(taskID: UUID) {
        activeDownloadTasks.removeValue(forKey: taskID)
        activeDownloadTags.removeValue(forKey: taskID)
    }

    internal func registerDownload(taskID: UUID, tagName: String) {
        activeDownloadTags[taskID] = tagName
    }

    /// Commits the shared prefix only after the fixed runtime record exists.
    /// The provider owns filesystem preparation; this method owns the pair
    /// record and its write/read verification.
    internal func prepareAndCommitSharedPrefix(runtime: ManagedWineRuntime) async throws {
        guard runtime.identity == Self.fixedRuntimeTag,
              let wineRuntimeProvider else {
            throw VersionManagerError.recoveryRequired("共享 prefix 缺少固定 runtime provider")
        }

        let lease: SharedWinePrefixLease
        do {
            lease = try await wineRuntimeProvider.acquireSharedPrefixLease()
        } catch let error as WineRuntimeProvider.WineError {
            throw VersionManagerError.recoveryRequired(error.localizedDescription)
        }

        do {
            let prepared = try await wineRuntimeProvider.prepareSharedPrefix(
                runtime: runtime,
                lease: lease
            )
            guard await wineRuntimeProvider.isSharedPrefixReady() else {
                throw VersionManagerError.recoveryRequired("共享 prefix 准备后结构验证失败")
            }
            let appSupport = await fileSystemRepository.appSupportDirectory()
            let prefixURL = prepared.url.resolvingSymlinksInPath().standardizedFileURL
            let canonicalSupport = appSupport.resolvingSymlinksInPath().standardizedFileURL
            guard prefixURL.path.hasPrefix(canonicalSupport.path + "/") else {
                throw VersionManagerError.recoveryRequired("共享 prefix 越出应用支持目录")
            }
            let record = SharedWinePrefixRecord(
                identity: Self.sharedPrefixIdentity,
                relativePath: "WinePrefixes/shared",
                absolutePath: prefixURL.path,
                runtimeIdentity: Self.fixedRuntimeTag,
                schemaRevision: "1",
                state: "ready",
                verifiedAt: Date()
            )
            try await persistenceStore.updateAppData { appData in
                appData.sharedWinePrefix = record
            }
            let verified = try await persistenceStore.readAppData()
            guard let persisted = verified.sharedWinePrefix,
                  persisted.identity == record.identity,
                  persisted.relativePath == record.relativePath,
                  persisted.absolutePath == record.absolutePath,
                  persisted.runtimeIdentity == record.runtimeIdentity,
                  persisted.schemaRevision == record.schemaRevision,
                  persisted.state == record.state else {
                throw VersionManagerError.persistenceFailed("共享 prefix 记录写回后重读不一致")
            }
            prefixRecord = record
            try await wineRuntimeProvider.releaseSharedPrefixLease(lease)
        } catch {
            try? await wineRuntimeProvider.releaseSharedPrefixLease(lease)
            if let managerError = error as? VersionManagerError { throw managerError }
            if let wineError = error as? WineRuntimeProvider.WineError {
                throw VersionManagerError.recoveryRequired(wineError.localizedDescription)
            }
            throw VersionManagerError.recoveryRequired(error.localizedDescription)
        }
    }

    internal nonisolated func wineBinaryFor(_ root: URL) -> URL {
        root.appendingPathComponent("bin/wine")
    }

    internal nonisolated static func isDirectory(atPath path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }

    /// A download is a side effect and must re-check the immutable catalog
    /// identity. Callers cannot turn a managed tag into an arbitrary URL.
    internal func validateCatalogEntry(_ version: WineVersionInfo) throws {
        guard Self.managedWineTags.contains(version.tagName) else {
            throw VersionManagerError.versionNotFound(version.tagName)
        }
        guard let source = BuiltInWineVersions.sourceDescriptor(for: version.sourceID),
              version.policyRevision == source.policyRevision else {
            throw VersionManagerError.sourceInvalid("Wine 目录来源或策略版本未通过验证")
        }
        let url = version.downloadURL
        guard url.scheme?.lowercased() == "https",
              url.host?.lowercased() == source.allowedAssetHost.lowercased(),
              url.path.hasPrefix(source.allowedAssetPathPrefix),
              url.pathExtension.lowercased() == "xz",
              source.supportsAssetName(url.lastPathComponent) else {
            throw VersionManagerError.sourceInvalid("Wine asset URL 不在批准来源 allowlist 内")
        }
        if !version.assetName.isEmpty,
           version.assetName != url.lastPathComponent {
            throw VersionManagerError.sourceInvalid("Wine asset 身份与 URL 不一致")
        }
        if let sha256 = version.expectedSHA256 {
            guard sha256 == BuiltInWineVersions.fixedAssetSHA256,
                  url == BuiltInWineVersions.fixedAssetURL,
                  version.fileSize == BuiltInWineVersions.fixedAssetSize else {
                throw VersionManagerError.sourceInvalid("固定 Wine 资源身份未通过验证")
            }
        }
    }

    internal func cleanup(paths: [String]) async throws {
        let versionsRoot = (await wineVersionsDirectory()).resolvingSymlinksInPath().standardizedFileURL
        let stagingRoot = versionsRoot.appendingPathComponent(".staging", isDirectory: true)
        let versionsPrefix = versionsRoot.path + "/"
        let stagingPrefix = stagingRoot.path + "/"

        for path in paths where FileManager.default.fileExists(atPath: path) {
            let url = URL(fileURLWithPath: path, isDirectory: true)
            let canonical = url.resolvingSymlinksInPath().standardizedFileURL
            let isStaging = canonical.path.hasPrefix(stagingPrefix) && canonical.path != stagingRoot.path
            let isManagedVersion = canonical.deletingLastPathComponent().path == versionsRoot.path &&
                Self.managedWineTags.contains(canonical.lastPathComponent)
            guard isStaging || isManagedVersion else {
                throw VersionManagerError.recoveryRequired("拒绝清理 Wine 托管目录之外的路径: \(path)")
            }
            guard canonical.path.hasPrefix(versionsPrefix) else {
                throw VersionManagerError.recoveryRequired("拒绝清理越界 Wine 路径: \(path)")
            }
            do {
                try FileManager.default.removeItem(at: url)
            } catch {
                // Downloader cancellation and this manager cleanup can be
                // concurrent. Treat a path already removed by the other
                // owner as verified cleanup; preserve every real failure.
                guard FileManager.default.fileExists(atPath: url.path) else {
                    continue
                }
                throw error
            }
        }
    }

    internal func recordRecovery(_ record: RecoveryRecord) async -> String? {
        do {
            try await persistenceStore.appendRecoveryRecord(record)
            return nil
        } catch {
            await logWriter.error("Wine 恢复事实无法持久化: \(error.localizedDescription)", module: "WineVersionManager")
            return error.localizedDescription
        }
    }

    // MARK: - 目录管理

    /// 获取 Wine 版本管理目录
}
