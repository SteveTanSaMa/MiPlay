// WineVersionDownloaderDownload.swift
// MiPlay

import Foundation

// Source: Architecture Design -> Wine download -> archive transfer and progress
extension WineVersionDownloader {
    internal func downloadArchive(
        for asset: ApprovedAsset,
        to destinationDir: String,
        sessionID: UUID = UUID()
    ) -> AsyncStream<DownloadPhase> {
        do {
            try validateApprovedAsset(asset)
        } catch {
            return AsyncStream { continuation in
                continuation.yield(.failed(error.localizedDescription))
                continuation.finish()
            }
        }
        return makeDownloadArchiveStream(
            from: asset.url,
            to: destinationDir,
            wineTag: asset.tagName,
            expectedSize: asset.fileSize > 0 ? asset.fileSize : nil,
            sessionID: sessionID,
            resetCancellation: true,
            allowedRedirectHosts: allowedRedirectHosts(for: asset)
        )
    }

    internal func downloadArchive(
        for asset: ApprovedAsset,
        staging: ManagedStaging,
        sessionID: UUID = UUID()
    ) -> AsyncStream<DownloadPhase> {
        do {
            try validateApprovedAsset(asset)
        } catch {
            return AsyncStream { continuation in
                continuation.yield(.failed(error.localizedDescription))
                continuation.finish()
            }
        }
        return makeDownloadArchiveStream(
            from: asset.url,
            to: staging.directoryURL.path,
            wineTag: asset.tagName,
            expectedSize: asset.fileSize > 0 ? asset.fileSize : nil,
            sessionID: sessionID,
            resetCancellation: true,
            allowedRedirectHosts: allowedRedirectHosts(for: asset)
        )
    }

    internal func makeDownloadArchiveStream(
        from downloadURL: URL,
        to destinationDir: String,
        wineTag: String?,
        expectedSize: Int64?,
        sessionID: UUID,
        resetCancellation: Bool,
        allowedRedirectHosts: [String]
    ) -> AsyncStream<DownloadPhase> {
        return AsyncStream { continuation in
            let lifecycle = StreamLifecycle()
            if resetCancellation {
                cancelledSessions.remove(sessionID)
            }
            let operationID = UUID()
            let producer = Task { [weak self] in
                guard let self else {
                    lifecycle.markFinished()
                    continuation.finish()
                    return
                }
                defer {
                    Task { [weak self] in
                        await self?.removeSessionOperation(sessionID: sessionID, operationID: operationID)
                    }
                }
                await self.logWriter.record(.init(
                    level: .info,
                    module: "WineVersionDownloader",
                    eventName: "wine.asset.download",
                    operationID: sessionID,
                    taskID: sessionID.uuidString,
                    wineTag: wineTag,
                    phase: "started",
                    result: "inProgress",
                    messageCode: "wine.asset.download_started"
                ))

                let archivePath = (destinationDir as NSString).appendingPathComponent("wine.tar.xz")

                // 检查磁盘空间
                do {
                    let fileManager = FileManager.default
                    try fileManager.createDirectory(
                        at: URL(fileURLWithPath: destinationDir, isDirectory: true),
                        withIntermediateDirectories: true
                    )
                    let attrs = try fileManager.attributesOfFileSystem(forPath: destinationDir)
                    let freeSpace = (attrs[.systemFreeSize] as? NSNumber)?.uint64Value ?? 0
                    let neededSpace = UInt64(expectedSize ?? 2_000_000_000) * 3 // 下载 + 解压需要 3x 空间
                    if freeSpace < neededSpace {
                        await self.logWriter.record(.init(
                            level: .error,
                            module: "WineVersionDownloader",
                            eventName: "wine.asset.download",
                    operationID: sessionID,
                    taskID: sessionID.uuidString,
                    wineTag: wineTag,
                            phase: "preflight",
                            result: "failed",
                            errorCategory: "unknown",
                            messageCode: "wine.asset.disk_space_insufficient",
                            fields: ["reasonCode": "diskSpaceInsufficient"]
                        ))
                        continuation.yield(.failed("磁盘空间不足，需要至少 \(ByteCountFormatter.string(fromByteCount: Int64(neededSpace), countStyle: .file))"))
                        lifecycle.markFinished(); continuation.finish()
                        return
                    }
                } catch {
                    await self.logWriter.record(.init(
                        level: .error,
                        module: "WineVersionDownloader",
                        eventName: "wine.asset.download",
                    operationID: sessionID,
                    taskID: sessionID.uuidString,
                    wineTag: wineTag,
                        phase: "preflight",
                        result: "failed",
                        errorCategory: "unknown",
                        messageCode: "wine.asset.disk_space_check_failed",
                        fields: ["reasonCode": "diskSpaceCheckFailed"]
                    ))
                    continuation.yield(.failed("磁盘空间检查失败: \(error.localizedDescription)"))
                    lifecycle.markFinished(); continuation.finish()
                    return
                }

                continuation.yield(.downloading(progress: 0, speed: 0, bytesReceived: 0, totalBytes: expectedSize ?? 0))

                // 执行下载
                let downloadStream = await self.networkProvider.download(
                    from: downloadURL,
                    to: archivePath,
                    expectedSize: expectedSize,
                    sessionID: sessionID
                )

                var lastProgress: Double = 0
                var downloadFailure: NetworkDownloadProvider.DownloadFailure?
                var finalResponseURL: URL?
                for await progress in downloadStream {
                    let sessionCancelled = await self.wasCancelled(sessionID: sessionID)
                    if Task.isCancelled || sessionCancelled {
                        await self.networkProvider.cancelDownload(sessionID: sessionID)
                        var cleanupVerified = true
                        do {
                            if FileManager.default.fileExists(atPath: archivePath) {
                                try FileManager.default.removeItem(atPath: archivePath)
                            }
                            continuation.yield(.cancelled)
                        } catch {
                            cleanupVerified = false
                            continuation.yield(.recoveryRequired("取消后的临时归档清理失败: \(error.localizedDescription)"))
                        }
                        await self.logWriter.record(.init(
                            level: .warning,
                            module: "WineVersionDownloader",
                            eventName: "wine.asset.cancel",
                    operationID: sessionID,
                    taskID: sessionID.uuidString,
                    wineTag: wineTag,
                            phase: "cleanup",
                            result: cleanupVerified ? "cancelled" : "recoveryRequired",
                            errorCategory: cleanupVerified ? "userCancelled" : "cancellationUnconfirmed",
                            messageCode: cleanupVerified ? "wine.asset.cancelled" : "wine.asset.cancel_cleanup_failed",
                            fields: ["cleanupVerified": String(cleanupVerified)]
                        ))
                        lifecycle.markFinished(); continuation.finish()
                        return
                    }
                    if let failure = progress.failure {
                        downloadFailure = failure
                    }
                    if let responseURL = progress.responseURL {
                        finalResponseURL = responseURL
                    }
                    continuation.yield(.downloading(
                        progress: progress.fractionCompleted,
                        speed: progress.speed,
                        bytesReceived: progress.bytesReceived,
                        totalBytes: progress.totalBytes
                    ))
                    lastProgress = progress.fractionCompleted
                }

                let sessionCancelledAfterDownload = await self.wasCancelled(sessionID: sessionID)
                if Task.isCancelled || sessionCancelledAfterDownload {
                    var cleanupVerified = true
                    do {
                        if FileManager.default.fileExists(atPath: archivePath) {
                            try FileManager.default.removeItem(atPath: archivePath)
                        }
                        continuation.yield(.cancelled)
                    } catch {
                        cleanupVerified = false
                        continuation.yield(.recoveryRequired("取消后的临时归档清理失败: \(error.localizedDescription)"))
                    }
                    await self.logWriter.record(.init(
                        level: .warning,
                        module: "WineVersionDownloader",
                        eventName: "wine.asset.cancel",
                    operationID: sessionID,
                    taskID: sessionID.uuidString,
                    wineTag: wineTag,
                        phase: "cleanup",
                        result: cleanupVerified ? "cancelled" : "recoveryRequired",
                        errorCategory: cleanupVerified ? "userCancelled" : "cancellationUnconfirmed",
                        messageCode: cleanupVerified ? "wine.asset.cancelled" : "wine.asset.cancel_cleanup_failed",
                        fields: ["cleanupVerified": String(cleanupVerified)]
                    ))
                    lifecycle.markFinished(); continuation.finish()
                    return
                }

                if let downloadFailure {
                    let errorCategory: String
                    switch downloadFailure.statusCode {
                    case 403: errorCategory = "assetForbidden"
                    case 404: errorCategory = "assetResourceNotFound"
                    case 429: errorCategory = "assetRateLimited"
                    case .some(500...599): errorCategory = "assetServerError"
                    default: errorCategory = "networkUnavailable"
                    }
                    await self.logWriter.record(.init(
                        level: .error,
                        module: "WineVersionDownloader",
                        eventName: "wine.asset.download",
                    operationID: sessionID,
                    taskID: sessionID.uuidString,
                    wineTag: wineTag,
                        phase: "download",
                        result: "failed",
                        errorCategory: errorCategory,
                        messageCode: "wine.asset.download_failed",
                        fields: downloadFailure.statusCode.map { ["statusCode": String($0)] } ?? [:]
                    ))
                    continuation.yield(.failedWithFailure(downloadFailure))
                    lifecycle.markFinished(); continuation.finish()
                    return
                }

                guard let finalResponseURL else {
                    await self.logWriter.record(.init(
                        level: .error,
                        module: "WineVersionDownloader",
                        eventName: "wine.asset.response",
                    operationID: sessionID,
                    taskID: sessionID.uuidString,
                    wineTag: wineTag,
                        phase: "response",
                        result: "failed",
                        errorCategory: "networkUnavailable",
                        messageCode: "wine.asset.http_response_missing"
                    ))
                    continuation.yield(.failed("下载未收到最终 HTTP 响应"))
                    lifecycle.markFinished(); continuation.finish()
                    return
                }
                guard let finalHost = finalResponseURL.host?.lowercased(),
                      allowedRedirectHosts.contains(finalHost) else {
                    do { try FileManager.default.removeItem(atPath: archivePath) }
                    catch {
                        await self.logWriter.record(.init(
                            level: .error,
                            module: "WineVersionDownloader",
                            eventName: "wine.asset.cleanup",
                    operationID: sessionID,
                    taskID: sessionID.uuidString,
                    wineTag: wineTag,
                            phase: "redirectCleanup",
                            result: "recoveryRequired",
                            errorCategory: "recoveryRequired",
                            messageCode: "wine.asset.redirect_cleanup_failed",
                            fields: ["cleanupVerified": "false"]
                        ))
                        continuation.yield(.recoveryRequired("重定向来源不受信任，且临时归档清理失败: \(error.localizedDescription)"))
                        lifecycle.markFinished(); continuation.finish()
                        return
                    }
                    await self.logWriter.record(.init(
                        level: .error,
                        module: "WineVersionDownloader",
                        eventName: "wine.asset.response",
                    operationID: sessionID,
                    taskID: sessionID.uuidString,
                    wineTag: wineTag,
                        phase: "response",
                        result: "failed",
                        errorCategory: "assetForbidden",
                        messageCode: "wine.asset.redirect_rejected"
                    ))
                    continuation.yield(.failed("Wine asset 重定向到未批准来源: \(finalResponseURL.absoluteString)"))
                    lifecycle.markFinished(); continuation.finish()
                    return
                }

                guard lastProgress >= 1.0 else {
                    await self.logWriter.record(.init(
                        level: .error,
                        module: "WineVersionDownloader",
                        eventName: "wine.asset.download",
                    operationID: sessionID,
                    taskID: sessionID.uuidString,
                    wineTag: wineTag,
                        phase: "download",
                        result: "failed",
                        errorCategory: "networkUnavailable",
                        messageCode: "wine.asset.incomplete"
                    ))
                    continuation.yield(.failed("下载未完成"))
                    lifecycle.markFinished(); continuation.finish()
                    return
                }

                await self.logWriter.record(.init(
                    level: .info,
                    module: "WineVersionDownloader",
                    eventName: "wine.asset.download",
                    operationID: sessionID,
                    taskID: sessionID.uuidString,
                    wineTag: wineTag,
                    phase: "download",
                    result: "completed",
                    messageCode: "wine.asset.download_completed",
                    fields: ["bytesReceived": String(expectedSize ?? 0)]
                ))

                // 完整性校验
                continuation.yield(.verifying)
                if let expectedSize = expectedSize {
                    do {
                        let actualSize = try await self.fileSystemRepository.fileSize(at: archivePath)
                        guard actualSize == expectedSize else {
                            do {
                                try await self.fileSystemRepository.deleteFile(at: archivePath)
                            } catch {
                                await self.logWriter.record(.init(
                                    level: .error,
                                    module: "WineVersionDownloader",
                                    eventName: "wine.asset.cleanup",
                    operationID: sessionID,
                    taskID: sessionID.uuidString,
                    wineTag: wineTag,
                                    phase: "verifyCleanup",
                                    result: "recoveryRequired",
                                    errorCategory: "recoveryRequired",
                                    messageCode: "wine.asset.verify_cleanup_failed",
                                    fields: ["cleanupVerified": "false"]
                                ))
                                continuation.yield(.failed("文件大小不匹配，且临时归档清理失败: \(error.localizedDescription)"))
                                lifecycle.markFinished(); continuation.finish()
                                return
                            }
                            continuation.yield(.failed("文件大小不匹配: 预期 \(expectedSize), 实际 \(actualSize)"))
                            await self.logWriter.record(.init(
                                level: .error,
                                module: "WineVersionDownloader",
                                eventName: "wine.asset.verify",
                    operationID: sessionID,
                    taskID: sessionID.uuidString,
                    wineTag: wineTag,
                                phase: "verify",
                                result: "failed",
                                errorCategory: "integrityFailed",
                                messageCode: "wine.asset.size_mismatch"
                            ))
                            lifecycle.markFinished(); continuation.finish()
                            return
                        }
                    } catch {
                        do {
                            try await self.fileSystemRepository.deleteFile(at: archivePath)
                        } catch {
                            await self.logWriter.record(.init(
                                level: .error,
                                module: "WineVersionDownloader",
                                eventName: "wine.asset.cleanup",
                    operationID: sessionID,
                    taskID: sessionID.uuidString,
                    wineTag: wineTag,
                                phase: "verifyCleanup",
                                result: "recoveryRequired",
                                errorCategory: "recoveryRequired",
                                messageCode: "wine.asset.verify_cleanup_failed",
                                fields: ["cleanupVerified": "false"]
                            ))
                            continuation.yield(.failed("完整性校验失败，且临时归档清理失败: \(error.localizedDescription)"))
                            lifecycle.markFinished(); continuation.finish()
                            return
                        }
                        continuation.yield(.failed("完整性校验失败: \(error.localizedDescription)"))
                        await self.logWriter.record(.init(
                            level: .error,
                            module: "WineVersionDownloader",
                            eventName: "wine.asset.verify",
                    operationID: sessionID,
                    taskID: sessionID.uuidString,
                    wineTag: wineTag,
                            phase: "verify",
                            result: "failed",
                            errorCategory: "integrityFailed",
                            messageCode: "wine.asset.verify_failed"
                        ))
                        lifecycle.markFinished(); continuation.finish()
                        return
                    }
                }
                if expectedSize != nil {
                    await self.logWriter.record(.init(
                        level: .info,
                        module: "WineVersionDownloader",
                        eventName: "wine.asset.verify",
                    operationID: sessionID,
                    taskID: sessionID.uuidString,
                    wineTag: wineTag,
                        phase: "verify",
                        result: "completed",
                        messageCode: "wine.asset.verify_completed",
                        fields: ["sizePresent": "true"]
                    ))
                }

                let sessionCancelledBeforeCompletion = await self.wasCancelled(sessionID: sessionID)
                guard !Task.isCancelled, !sessionCancelledBeforeCompletion else {
                    var cleanupVerified = true
                    do {
                        if FileManager.default.fileExists(atPath: archivePath) {
                            try FileManager.default.removeItem(atPath: archivePath)
                        }
                        continuation.yield(.cancelled)
                    } catch {
                        cleanupVerified = false
                        continuation.yield(.recoveryRequired("取消后的临时归档清理失败: \(error.localizedDescription)"))
                    }
                    await self.logWriter.record(.init(
                        level: .warning,
                        module: "WineVersionDownloader",
                        eventName: "wine.asset.cancel",
                    operationID: sessionID,
                    taskID: sessionID.uuidString,
                    wineTag: wineTag,
                        phase: "cleanup",
                        result: cleanupVerified ? "cancelled" : "recoveryRequired",
                        errorCategory: cleanupVerified ? "userCancelled" : "cancellationUnconfirmed",
                        messageCode: cleanupVerified ? "wine.asset.cancelled" : "wine.asset.cancel_cleanup_failed",
                        fields: ["cleanupVerified": String(cleanupVerified)]
                    ))
                    lifecycle.markFinished(); continuation.finish()
                    return
                }

                continuation.yield(.completed(versionPath: archivePath))
                lifecycle.markFinished(); continuation.finish()
            }
            continuation.onTermination = { @Sendable _ in
                guard lifecycle.markCancelled() else { return }
                producer.cancel()
                Task { await self.cancel(sessionID: sessionID) }
            }
            activeSessions[sessionID, default: [:]][operationID] = producer
        }
    }

    /// Cancels both the producer task and its URLSession download.
}
