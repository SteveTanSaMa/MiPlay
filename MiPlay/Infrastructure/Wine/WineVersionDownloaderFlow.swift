// WineVersionDownloaderFlow.swift
// MiPlay

import Foundation
import CryptoKit

// Source: Architecture Design -> Wine download -> download and extract lifecycle
extension WineVersionDownloader {
    internal func extractArchive(archivePath: String, to extractionDir: String) async throws -> String {
        let destination = URL(fileURLWithPath: extractionDir, isDirectory: true)
        let staging = try ManagedStaging(
            rootURL: destination.deletingLastPathComponent(),
            directoryURL: destination
        )
        return try await extractArchive(
            archive: URL(fileURLWithPath: archivePath, isDirectory: false),
            staging: staging
        )
    }

    /// 下载并解压完整流程
    /// - Parameters:
    ///   - tagName: 版本标签名
    ///   - targetDir: 目标版本存储目录
    /// - Returns: 解压后的路径
    /// Source: Architecture → ADR 017 — 透传 GitHub Token
    internal func downloadAndExtract(
        asset: ApprovedAsset,
        staging: ManagedStaging,
        githubToken: String? = nil,
        sessionID: UUID = UUID()
    ) -> AsyncStream<DownloadPhase> {
        return AsyncStream { continuation in
            let lifecycle = StreamLifecycle()
            cancelledSessions.remove(sessionID)
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
                do {
                    // 1. Catalog metadata is resolved before this method.
                    continuation.yield(.fetchingMetadata)
                    try self.validateApprovedAsset(asset)
                    let sessionCancelledAfterMetadata = await self.wasCancelled(sessionID: sessionID)
                    if Task.isCancelled || sessionCancelledAfterMetadata {
                        throw CancellationError()
                    }

                    // 2. 下载
                    let archiveDir = staging.directoryURL.path
                    let downloadPhaseStream = await self.makeDownloadArchiveStream(
                        from: asset.url,
                        to: archiveDir, // temp
                        wineTag: asset.tagName,
                        expectedSize: asset.fileSize > 0 ? asset.fileSize : nil,
                        sessionID: sessionID,
                        resetCancellation: false,
                        allowedRedirectHosts: self.allowedRedirectHosts(for: asset)
                    )

                    var archivePath: String?
                    for await phase in downloadPhaseStream {
                        try Task.checkCancellation()
                        switch phase {
                        case .completed(let path):
                            archivePath = path
                        case .failed(let error):
                            throw DownloaderError.downloadFailed(error)
                        case .failedWithFailure(let failure):
                            throw DownloadFlowError.network(failure)
                        default:
                            continuation.yield(phase)
                        }
                    }

                    let sessionCancelledAfterDownload = await self.wasCancelled(sessionID: sessionID)
                    if Task.isCancelled || sessionCancelledAfterDownload {
                        throw CancellationError()
                    }

                    guard let archivePath = archivePath else {
                        throw DownloaderError.downloadFailed("下载未完成")
                    }

                    if let expectedSHA256 = asset.expectedSHA256 {
                        continuation.yield(.verifying)
                        try Self.verifyArchiveSHA256(at: URL(fileURLWithPath: archivePath), expected: expectedSHA256)
                    }

                    // 3. 解压
                    continuation.yield(.extracting(progress: 0))
                    let versionPath = try await self.extractArchive(
                        archive: URL(fileURLWithPath: archivePath, isDirectory: false),
                        staging: staging,
                        wineTag: asset.tagName,
                        taskID: sessionID.uuidString,
                        onExtractionProgress: { fraction in
                            continuation.yield(.extracting(progress: fraction))
                        }
                    )
                    let sessionCancelled = await self.wasCancelled(sessionID: sessionID)
                    if Task.isCancelled || sessionCancelled {
                        throw CancellationError()
                    }

                    continuation.yield(.completed(versionPath: versionPath))
                    lifecycle.markFinished(); continuation.finish()

                } catch is CancellationError {
                    do {
                        try await self.cleanup(staging: staging)
                        continuation.yield(.cancelled)
                    } catch {
                        continuation.yield(.recoveryRequired("取消后的临时目录清理失败: \(error.localizedDescription)"))
                    }
                    lifecycle.markFinished(); continuation.finish()
                } catch {
                    let operationError = error.localizedDescription
                    let sessionCancelled = await self.wasCancelled(sessionID: sessionID)
                    if Task.isCancelled || sessionCancelled {
                        do {
                            try await self.cleanup(staging: staging)
                            continuation.yield(.cancelled)
                        } catch {
                            continuation.yield(.recoveryRequired("取消后的临时目录清理失败: \(error.localizedDescription)"))
                        }
                    } else {
                        do {
                            try await self.cleanup(staging: staging)
                            if let flowError = error as? DownloadFlowError,
                               case .network(let failure) = flowError {
                                continuation.yield(.failedWithFailure(failure))
                            } else {
                                continuation.yield(.failed(operationError))
                            }
                        } catch {
                            continuation.yield(.recoveryRequired("\(operationError); 临时目录清理失败: \(error.localizedDescription)"))
                        }
                    }
                    lifecycle.markFinished(); continuation.finish()
                }
            }
            continuation.onTermination = { @Sendable _ in
                guard lifecycle.markCancelled() else { return }
                producer.cancel()
                Task { await self.cancel(sessionID: sessionID) }
            }
            activeSessions[sessionID, default: [:]][operationID] = producer
        }
    }

    /// Verify the pinned archive before passing it to the extractor; use a
    /// bounded buffer rather than mapping a several-hundred-megabyte archive.
    internal nonisolated static func verifyArchiveSHA256(at url: URL, expected: String) throws {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while true {
            try Task.checkCancellation()
            guard let bytes = try handle.read(upToCount: 1024 * 1024), !bytes.isEmpty else { break }
            hash.update(data: bytes)
        }
        let actual = hash.finalize().map { String(format: "%02x", $0) }.joined()
        guard actual.caseInsensitiveCompare(expected) == .orderedSame else {
            throw DownloaderError.integrityCheckFailed("Wine 归档 SHA-256 不匹配")
        }
    }

}
