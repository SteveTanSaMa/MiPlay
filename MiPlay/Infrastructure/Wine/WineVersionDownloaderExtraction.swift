// WineVersionDownloaderExtraction.swift
// MiPlay

import Foundation

// Source: Architecture Design -> Wine download -> cancellation and extraction
extension WineVersionDownloader {
    public func cancel(sessionID: UUID) async {
        cancelledSessions.insert(sessionID)
        let producers: [Task<Void, Never>]
        if let sessions = activeSessions.removeValue(forKey: sessionID) {
            producers = Array(sessions.values)
        } else {
            producers = []
        }
        for producer in producers { producer.cancel() }
        await networkProvider.cancelDownload(sessionID: sessionID)
        for producer in producers { await producer.value }
    }

    internal func removeSessionOperation(sessionID: UUID, operationID: UUID) {
        activeSessions[sessionID]?.removeValue(forKey: operationID)
        if activeSessions[sessionID]?.isEmpty == true {
            activeSessions.removeValue(forKey: sessionID)
        }
    }

    /// 解压 `.tar.xz` 归档到目标版本目录
    /// - Parameters:
    ///   - archivePath: 归档文件路径
    ///   - extractionDir: 解压目标目录
    /// - Returns: 解压后的版本路径（包含 bin/wine）
    internal func extractArchive(
        archive: URL,
        staging: ManagedStaging,
        wineTag: String? = nil,
        taskID: String? = nil
    ) async throws -> String {
        let archivePath = archive.path
        let extractionDir = staging.directoryURL.path
        let operationID = UUID()
        await logWriter.record(.init(
            level: .info,
            module: "WineVersionDownloader",
            eventName: "wine.asset.extract",
            operationID: operationID,
            taskID: taskID,
            wineTag: wineTag,
            phase: "started",
            result: "inProgress",
            messageCode: "wine.asset.extract_started"
        ))

        guard fileSystemRepository.validatePath(archivePath),
              archive.resolvingSymlinksInPath().standardizedFileURL.path
                .hasPrefix(staging.rootURL.path + "/") else {
            await logWriter.record(.init(
                level: .error,
                module: "WineVersionDownloader",
                eventName: "wine.asset.extract",
                operationID: operationID,
                taskID: taskID,
                wineTag: wineTag,
                phase: "boundary",
                result: "failed",
                errorCategory: "assetForbidden",
                messageCode: "wine.asset.extract_boundary_rejected"
            ))
            throw DownloaderError.extractionFailed("归档文件不在托管 staging 内: \(archivePath)")
        }

        try FileManager.default.createDirectory(
            at: staging.directoryURL,
            withIntermediateDirectories: true
        )

        // 使用 tar 解压 .tar.xz
        do {
            let listing = try await processManager.launchAndWait(
                executablePath: "/usr/bin/tar",
                arguments: ["-tJf", archivePath],
                timeout: 120
            )
            try validateArchiveEntries(listing)
            let detailedListing = try await processManager.launchAndWait(
                executablePath: "/usr/bin/tar",
                arguments: ["-tvJf", archivePath],
                timeout: 120
            )
            try validateArchiveSymlinks(detailedListing, inside: staging.directoryURL)
            _ = try await processManager.launchAndWait(
                executablePath: "/usr/bin/tar",
                arguments: ["-xJf", archivePath, "-C", extractionDir],
                timeout: 120
            )
            try validateExtractedTree(at: staging.directoryURL)
        } catch is CancellationError {
            await logWriter.record(.init(
                level: .warning,
                module: "WineVersionDownloader",
                eventName: "wine.asset.extract",
                operationID: operationID,
                taskID: taskID,
                wineTag: wineTag,
                phase: "cancelled",
                result: "cancelled",
                errorCategory: "userCancelled",
                messageCode: "wine.asset.extract_cancelled"
            ))
            do {
                try cleanup(staging: staging)
            } catch {
                await logWriter.record(.init(
                    level: .error,
                    module: "WineVersionDownloader",
                    eventName: "wine.asset.cleanup",
                    operationID: operationID,
                    taskID: taskID,
                    wineTag: wineTag,
                    phase: "cancelCleanup",
                    result: "recoveryRequired",
                    errorCategory: "cancellationUnconfirmed",
                    messageCode: "wine.asset.extract_cancel_cleanup_failed",
                    fields: ["cleanupVerified": "false"]
                ))
                throw DownloaderError.cleanupFailed("取消解压后的目录清理失败: \(error.localizedDescription)")
            }
            throw CancellationError()
        } catch {
            await logWriter.record(.init(
                level: .error,
                module: "WineVersionDownloader",
                eventName: "wine.asset.extract",
                operationID: operationID,
                taskID: taskID,
                wineTag: wineTag,
                phase: "failed",
                result: "failed",
                errorCategory: "unknown",
                messageCode: "wine.asset.extract_failed"
            ))
            if Task.isCancelled {
                do {
                    try cleanup(staging: staging)
                } catch {
                    await logWriter.record(.init(
                        level: .error,
                        module: "WineVersionDownloader",
                        eventName: "wine.asset.cleanup",
                        operationID: operationID,
                        taskID: taskID,
                        wineTag: wineTag,
                        phase: "cancelCleanup",
                        result: "recoveryRequired",
                        errorCategory: "cancellationUnconfirmed",
                        messageCode: "wine.asset.extract_cancel_cleanup_failed",
                        fields: ["cleanupVerified": "false"]
                    ))
                    throw DownloaderError.cleanupFailed("取消解压后的目录清理失败: \(error.localizedDescription)")
                }
                throw CancellationError()
            }
            // 清理不完整解压
            let detail = error.localizedDescription
            do {
                try cleanup(staging: staging)
            } catch {
                await logWriter.record(.init(
                    level: .error,
                    module: "WineVersionDownloader",
                    eventName: "wine.asset.cleanup",
                    operationID: operationID,
                    taskID: taskID,
                    wineTag: wineTag,
                    phase: "failureCleanup",
                    result: "recoveryRequired",
                    errorCategory: "recoveryRequired",
                    messageCode: "wine.asset.extract_cleanup_failed",
                    fields: ["cleanupVerified": "false"]
                ))
                throw DownloaderError.extractionFailed("\(detail); 不完整解压目录清理失败: \(error.localizedDescription)")
            }
            throw DownloaderError.extractionFailed(detail)
        }

        // 验证解压结果：检查 wine 可执行文件
        let wineBinPath = "\(extractionDir)/bin/wine"
        guard FileManager.default.fileExists(atPath: wineBinPath) else {
            do {
                try cleanup(staging: staging)
            } catch {
                await logWriter.record(.init(
                    level: .error,
                    module: "WineVersionDownloader",
                    eventName: "wine.asset.cleanup",
                    operationID: operationID,
                    taskID: taskID,
                    wineTag: wineTag,
                    phase: "failureCleanup",
                    result: "recoveryRequired",
                    errorCategory: "recoveryRequired",
                    messageCode: "wine.asset.extract_cleanup_failed",
                    fields: ["cleanupVerified": "false"]
                ))
                throw DownloaderError.extractionFailed("解压后未找到 wine 可执行文件，且不完整目录清理失败: \(error.localizedDescription)")
            }
            throw DownloaderError.extractionFailed("解压后未找到 wine 可执行文件")
        }

        // 设置可执行权限并把失败保留为解压失败事实。
        do {
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: wineBinPath
            )
        } catch {
            let detail = error.localizedDescription
            do {
                try cleanup(staging: staging)
            } catch {
                await logWriter.record(.init(
                    level: .error,
                    module: "WineVersionDownloader",
                    eventName: "wine.asset.cleanup",
                    operationID: operationID,
                    taskID: taskID,
                    wineTag: wineTag,
                    phase: "failureCleanup",
                    result: "recoveryRequired",
                    errorCategory: "recoveryRequired",
                    messageCode: "wine.asset.extract_cleanup_failed",
                    fields: ["cleanupVerified": "false"]
                ))
                throw DownloaderError.extractionFailed("Wine binary 权限设置失败: \(detail); 解压目录清理失败: \(error.localizedDescription)")
            }
            throw DownloaderError.extractionFailed("Wine binary 权限设置失败: \(detail)")
        }

        // 清理归档文件
        do {
            try await fileSystemRepository.deleteFile(at: archivePath)
        } catch {
            await logWriter.record(.init(
                level: .error,
                module: "WineVersionDownloader",
                eventName: "wine.asset.cleanup",
                operationID: operationID,
                taskID: taskID,
                wineTag: wineTag,
                phase: "archiveCleanup",
                result: "recoveryRequired",
                errorCategory: "recoveryRequired",
                messageCode: "wine.asset.archive_cleanup_failed",
                fields: ["cleanupVerified": "false"]
            ))
            throw DownloaderError.extractionFailed("解压已完成但归档清理失败: \(error.localizedDescription)")
        }

        await logWriter.record(.init(
            level: .info,
            module: "WineVersionDownloader",
            eventName: "wine.asset.extract",
            operationID: operationID,
            taskID: taskID,
            wineTag: wineTag,
            phase: "completed",
            result: "completed",
            messageCode: "wine.asset.extract_completed"
        ))
        return extractionDir
    }

    /// Test/migration seam. It still requires the destination to be a managed
    /// `.staging` child; arbitrary paths cannot reach extraction cleanup.
}
