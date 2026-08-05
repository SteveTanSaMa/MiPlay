//
//  WineVersionDownloader.swift
//  MiPlay
//
//  Created by Steve Tan on 2026/7/7.
//

@preconcurrency import Foundation

// Source: Architecture Design → Service Contract → WineVersionDownloader
// Source: Architecture Design → ADR 011 → Wine 版本管理双层分离
// Source: Architecture Design → ADR 008 → URLSession 原生网络栈

/// Wine 版本下载与解压器。
/// 从 yaagl/anime-game-wine 的 GitHub Release 下载 `.tar.xz` 压缩包，
/// 验证下载完整性，解压到目标版本存储目录。
/// 由 WineVersionManager 驱动，自身不管理业务状态。
public actor WineVersionDownloader {
    public enum DownloaderError: Error, LocalizedError {
        case apiUnavailable(String)
        case apiForbidden(String)
        case apiNotFound(String)
        case apiRateLimited(String)
        case apiServerError(statusCode: Int, detail: String)
        case assetForbidden(String)
        case assetRateLimited(String)
        case assetServerError(statusCode: Int, detail: String)
        case assetResourceNotFound(String)
        case resourceNotFound(String)
        case assetNotFound(String)
        case downloadFailed(String)
        case integrityCheckFailed(String)
        case extractionFailed(String)
        case diskSpaceInsufficient(String)
        case cancelled
        case cleanupFailed(String)

        public var errorDescription: String? {
            switch self {
            case .apiUnavailable(let detail):
                return "GitHub API 不可用: \(detail)"
            case .apiForbidden(let detail):
                return "Wine 来源 API 访问被拒绝: \(detail)"
            case .apiNotFound(let detail):
                return "Wine 来源 API 资源不存在: \(detail)"
            case .apiRateLimited(let detail):
                return "Wine 来源 API 受到速率限制: \(detail)"
            case .apiServerError(let statusCode, let detail):
                return "Wine 来源 API 服务错误 (HTTP \(statusCode)): \(detail)"
            case .assetForbidden(let detail):
                return "Wine 下载资源访问被拒绝: \(detail)"
            case .assetRateLimited(let detail):
                return "Wine 下载资源受到速率限制: \(detail)"
            case .assetServerError(let statusCode, let detail):
                return "Wine 下载资源服务错误 (HTTP \(statusCode)): \(detail)"
            case .assetResourceNotFound(let detail):
                return "Wine 下载资源不存在: \(detail)"
            case .resourceNotFound(let detail):
                return "Wine 下载资源不存在: \(detail)"
            case .assetNotFound(let name):
                return "未找到匹配的下载资源: \(name)"
            case .downloadFailed(let detail):
                return "下载失败: \(detail)"
            case .integrityCheckFailed(let detail):
                return "完整性校验失败: \(detail)"
            case .extractionFailed(let detail):
                return "解压失败: \(detail)"
            case .diskSpaceInsufficient(let detail):
                return "磁盘空间不足: \(detail)"
            case .cancelled:
                return "Wine 下载已取消"
            case .cleanupFailed(let detail):
                return "Wine 下载清理失败: \(detail)"
            }
        }
    }

    /// 下载阶段进度
    public enum DownloadPhase: Sendable {
        case fetchingMetadata
        case downloading(progress: Double, speed: Double, bytesReceived: Int64, totalBytes: Int64)
        case verifying
        case extracting(progress: Double)
        case installing
        case installed(versionPath: String)
        case completed(versionPath: String)
        case failed(String)
        case failedWithFailure(NetworkDownloadProvider.DownloadFailure)
        case cancelled
        case recoveryRequired(String)
    }

    /// Identity returned by the policy-validated catalog. The downloader never
    /// accepts a caller-provided URL without this identity envelope.
    internal struct ApprovedAsset: Sendable, Equatable {
        let sourceID: String
        let tagName: String
        let url: URL
        let assetName: String
        let fileSize: Int64

        nonisolated init(
            sourceID: String,
            tagName: String,
            url: URL,
            assetName: String,
            fileSize: Int64
        ) {
            self.sourceID = sourceID
            self.tagName = tagName
            self.url = url
            self.assetName = assetName
            self.fileSize = fileSize
        }
    }

    /// A staging identity is valid only below the managed WineVersions/.staging
    /// directory. It is deliberately not constructible from the public API.
    internal struct ManagedStaging: Sendable, Equatable {
        let rootURL: URL
        let directoryURL: URL

        init(rootURL: URL, directoryURL: URL) throws {
            let canonicalRoot = rootURL.resolvingSymlinksInPath().standardizedFileURL
            let canonicalDirectory = directoryURL.resolvingSymlinksInPath().standardizedFileURL
            let rootPath = canonicalRoot.path.hasSuffix("/") ? canonicalRoot.path : canonicalRoot.path + "/"

            guard canonicalRoot.lastPathComponent == ".staging",
                  canonicalRoot.deletingLastPathComponent().lastPathComponent == "WineVersions",
                  canonicalDirectory.path.hasPrefix(rootPath),
                  canonicalDirectory.path != canonicalRoot.path,
                  canonicalDirectory.path.hasPrefix(rootPath) else {
                throw DownloaderError.extractionFailed("解压 staging 不在 MiPlay 托管目录内")
            }

            // The destination itself may not be a symlink. A symlink below the
            // staging directory is checked again after extraction.
            if let values = try? directoryURL.resourceValues(forKeys: [.isSymbolicLinkKey]),
               values.isSymbolicLink == true {
                throw DownloaderError.extractionFailed("解压 staging 不能是符号链接")
            }
            self.rootURL = canonicalRoot
            self.directoryURL = canonicalDirectory
        }

        var archiveURL: URL {
            directoryURL.appendingPathComponent("wine.tar.xz", isDirectory: false)
        }
    }

    internal let networkProvider: NetworkDownloadProvider
    internal let fileSystemRepository: GameFileSystemRepository
    internal let processManager: ProcessManager
    internal let logWriter: LogWriter

    internal let githubRepo = "yaagl/anime-game-wine"
    internal var activeSessions: [UUID: [UUID: Task<Void, Never>]] = [:]
    internal var cancelledSessions: Set<UUID> = []

    internal final class StreamLifecycle: @unchecked Sendable {
        internal let lock = NSLock()
        internal var terminated = false

        func markFinished() {
            lock.lock()
            terminated = true
            lock.unlock()
        }

        func markCancelled() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !terminated else { return false }
            terminated = true
            return true
        }
    }

    internal enum DownloadFlowError: Error {
        case network(NetworkDownloadProvider.DownloadFailure)
    }

    public init(
        networkProvider: NetworkDownloadProvider,
        fileSystemRepository: GameFileSystemRepository,
        processManager: ProcessManager,
        logWriter: LogWriter
    ) {
        self.networkProvider = networkProvider
        self.fileSystemRepository = fileSystemRepository
        self.processManager = processManager
        self.logWriter = logWriter
    }

    /// 从 GitHub API 获取版本发布信息
    /// - Parameter tagName: 版本标签名
    /// - Returns: 可下载的 asset 信息
    /// Source: Architecture → ADR 017 — 支持 GitHub Token 和 429 处理
    /// Source: QA Report → F-006 — 使用共享 GitHub API 模型
    internal func fetchReleaseAsset(tagName: String, githubToken: String? = nil) async throws -> ApprovedAsset {
        try validateManagedTag(tagName)
        let operationID = UUID()
        await logWriter.record(.init(
            level: .info,
            module: "WineVersionDownloader",
            eventName: "wine.catalog.request",
            operationID: operationID,
            wineTag: tagName,
            phase: "request",
            result: "inProgress",
            messageCode: "wine.catalog.request_started",
            fields: ["sourceID": "officialGitHub"]
        ))
        let apiURL = URL(string: "https://api.github.com/repos/\(githubRepo)/releases/tags/\(tagName)")!

        var headers: [String: String]? = nil
        if let token = githubToken {
            headers = ["Authorization": "Bearer \(token)"]
        }

        do {
            let release: GitHubReleaseResponse = try await networkProvider.request(
                GitHubReleaseResponse.self,
                from: apiURL,
                additionalHeaders: headers
            )

            guard let asset = release.assets.first(where: {
                $0.name.hasSuffix(".tar.xz") && BuiltInWineVersions.officialSource.supportsAssetName($0.name)
            }) else {
                throw DownloaderError.assetNotFound("tag: \(tagName)")
            }

            guard let downloadURL = URL(string: asset.browserDownloadURL) else {
                throw DownloaderError.assetNotFound("无效的下载 URL")
            }

            try validateApprovedAsset(downloadURL, tagName: tagName, assetName: asset.name)

            let approvedAsset = ApprovedAsset(
                sourceID: "officialGitHub",
                tagName: tagName,
                url: downloadURL,
                assetName: asset.name,
                fileSize: asset.size
            )
            await logWriter.record(.init(
                level: .info,
                module: "WineVersionDownloader",
                eventName: "wine.catalog.asset",
                operationID: operationID,
                wineTag: tagName,
                phase: "validated",
                result: "completed",
                messageCode: "wine.catalog.asset_approved",
                fields: ["sourceID": "officialGitHub", "assetSize": String(asset.size)]
            ))
            return approvedAsset
        } catch let error as NetworkDownloadProvider.NetworkError {
            if case .httpError(let statusCode, let message) = error, statusCode == 403 {
                await logWriter.record(.init(
                    level: .error,
                    module: "WineVersionDownloader",
                    eventName: "wine.catalog.response",
                    operationID: operationID,
                    wineTag: tagName,
                    phase: "response",
                    result: "failed",
                    errorCategory: "apiForbidden",
                    messageCode: "wine.catalog.forbidden",
                    fields: ["sourceID": "officialGitHub", "statusCode": "403"]
                ))
                throw DownloaderError.apiForbidden(message)
            }
            if case .httpError(let statusCode, let message) = error, statusCode == 404 {
                await logWriter.record(.init(
                    level: .error,
                    module: "WineVersionDownloader",
                    eventName: "wine.catalog.response",
                    operationID: operationID,
                    wineTag: tagName,
                    phase: "response",
                    result: "failed",
                    errorCategory: "apiNotFound",
                    messageCode: "wine.catalog.not_found",
                    fields: ["sourceID": "officialGitHub", "statusCode": "404"]
                ))
                throw DownloaderError.apiNotFound(message)
            }
            if case .httpError(let statusCode, _) = error, statusCode == 429 {
                await logWriter.record(.init(
                    level: .warning,
                    module: "WineVersionDownloader",
                    eventName: "wine.catalog.response",
                    operationID: operationID,
                    wineTag: tagName,
                    phase: "response",
                    result: "failed",
                    errorCategory: "apiRateLimited",
                    messageCode: "wine.catalog.rate_limited",
                    fields: ["sourceID": "officialGitHub", "statusCode": "429"]
                ))
                throw DownloaderError.apiRateLimited("GitHub API 速率限制，请稍后重试")
            }
            if case .httpError(let statusCode, let message) = error, (500...599).contains(statusCode) {
                await logWriter.record(.init(
                    level: .error,
                    module: "WineVersionDownloader",
                    eventName: "wine.catalog.response",
                    operationID: operationID,
                    wineTag: tagName,
                    phase: "response",
                    result: "failed",
                    errorCategory: "apiServerError",
                    messageCode: "wine.catalog.server_error",
                    fields: ["sourceID": "officialGitHub", "statusCode": String(statusCode)]
                ))
                throw DownloaderError.apiServerError(statusCode: statusCode, detail: message)
            }
            await logWriter.record(.init(
                level: .error,
                module: "WineVersionDownloader",
                eventName: "wine.catalog.response",
                operationID: operationID,
                wineTag: tagName,
                phase: "response",
                result: "failed",
                errorCategory: "networkUnavailable",
                messageCode: "wine.catalog.request_failed",
                fields: ["sourceID": "officialGitHub"]
            ))
            throw DownloaderError.apiUnavailable(error.localizedDescription)
        } catch let error as DownloaderError {
            await logWriter.record(.init(
                level: .error,
                module: "WineVersionDownloader",
                eventName: "wine.catalog.response",
                operationID: operationID,
                wineTag: tagName,
                phase: "response",
                result: "failed",
                errorCategory: "catalogInvalid",
                messageCode: "wine.catalog.invalid",
                fields: ["sourceID": "officialGitHub"]
            ))
            throw error
        } catch {
            await logWriter.record(.init(
                level: .error,
                module: "WineVersionDownloader",
                eventName: "wine.catalog.response",
                operationID: operationID,
                wineTag: tagName,
                phase: "response",
                result: "failed",
                errorCategory: "networkUnavailable",
                messageCode: "wine.catalog.request_failed",
                fields: ["sourceID": "officialGitHub"]
            ))
            throw DownloaderError.apiUnavailable(error.localizedDescription)
        }
    }

    /// 下载 `.tar.xz` 包到临时路径
    /// - Parameters:
    ///   - downloadURL: 下载 URL
    ///   - destinationDir: 目标存储目录
    ///   - expectedSize: 预期文件大小
    /// - Returns: 下载后的归档文件路径
}
