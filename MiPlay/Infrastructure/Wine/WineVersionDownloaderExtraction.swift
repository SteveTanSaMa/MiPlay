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
    ///   - onExtractionProgress: 解压进度回调（0…1），按已展开字节 / 归档未压缩总大小估算
    /// - Returns: 解压后的版本路径（包含 bin/wine）
    internal func extractArchive(
        archive: URL,
        staging: ManagedStaging,
        wineTag: String? = nil,
        taskID: String? = nil,
        onExtractionProgress: (@Sendable (Double) -> Void)? = nil
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
                // `--numeric-owner` 必须在前面：bsdtar 的旧式解析会把跟在
                // `-tvJf` 之后的 `--long-option` 当成要列出的文件名。
                arguments: ["--numeric-owner", "-tvJf", archivePath],
                timeout: 120
            )
            try validateArchiveSymlinks(detailedListing, inside: staging.directoryURL)
            let extractionArguments: [String] = archiveWrapperDirectory(from: listing) == nil
                ? ["-xJf", archivePath, "-C", extractionDir]
                : ["-xJf", archivePath, "-C", extractionDir, "--strip-components", "1"]
            // 解压进度：未压缩总大小直接取自上面已有的明细列表（无额外解压开销），
            // 解压期间轮询目标目录已展开字节数。bsdtar 没有可用的进度回调
            //（不支持 --checkpoint），因此这是最直接且诚实的进度来源。
            let expectedBytes = Self.uncompressedSize(fromDetailedListing: detailedListing)
            let extractionProcessID = try await processManager.launch(
                executablePath: "/usr/bin/tar",
                arguments: extractionArguments,
                captureOutput: true
            )
            let progressMonitor = Task {
                while !Task.isCancelled {
                    if expectedBytes > 0 {
                        let extracted = Self.directoryByteCount(at: extractionDir)
                        onExtractionProgress?(
                            min(Double(extracted) / Double(expectedBytes), 0.99)
                        )
                    }
                    try? await Task.sleep(for: .milliseconds(400))
                }
            }
            do {
                let termination = try await processManager.waitForTermination(
                    processID: extractionProcessID,
                    timeout: 120
                )
                progressMonitor.cancel()
                guard !termination.terminatedBySignal, termination.statusCode == 0 else {
                    let detail = termination.output
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                        .suffix(400)
                    throw DownloaderError.extractionFailed(
                        "tar 解压退出码 \(termination.statusCode)\(termination.terminatedBySignal ? "（信号中断）" : "")\(detail.isEmpty ? "" : ": \(detail)")"
                    )
                }
            } catch {
                progressMonitor.cancel()
                _ = try? await processManager.terminateAndWait(
                    processID: extractionProcessID,
                    force: true,
                    timeout: 5
                )
                throw error
            }
            onExtractionProgress?(1)
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

    // MARK: - 解压进度辅助

    /// 从 `tar -tvJf --numeric-owner` 明细累加未压缩总大小（解析失败的行忽略）。
    /// 形如 `-rw-r--r--  0 501 20 12345 Feb 13 12:34 path`。
    nonisolated internal static func uncompressedSize(fromDetailedListing listing: String) -> Int64 {
        var total: Int64 = 0
        for line in listing.split(whereSeparator: \.isNewline) {
            let fields = line.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count >= 5, let size = Int64(fields[4]) else { continue }
            total += size
        }
        return total
    }

    /// 目录内普通文件的总字节数（解压进度用）。
    nonisolated internal static func directoryByteCount(
        at path: String,
        fileManager: FileManager = .default
    ) -> Int64 {
        guard let enumerator = fileManager.enumerator(atPath: path) else { return 0 }
        var total: Int64 = 0
        for case let item as String in enumerator {
            let fullPath = (path as NSString).appendingPathComponent(item)
            guard let attributes = try? fileManager.attributesOfItem(atPath: fullPath),
                  attributes[.type] as? FileAttributeType == .typeRegular,
                  let size = attributes[.size] as? Int64 else { continue }
            total += size
        }
        return total
    }
}
