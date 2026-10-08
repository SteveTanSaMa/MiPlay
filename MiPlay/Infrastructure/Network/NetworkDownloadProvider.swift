//
//  NetworkDownloadProvider.swift
//  MiPlay
//
//  Created by Steve Tan on 2026/7/7.
//

import Foundation

// Source: Architecture Design → Service Contract → NetworkDownloadProvider
// Source: Architecture Design → ADR 008 → URLSession 原生网络栈
// Source: Architecture Design → ADR 003 → Actor 隔离

nonisolated private final class DownloadProgressState: @unchecked Sendable {
    private let lock = NSLock()
    private var lastBytes: Int64 = 0
    private var lastTime = Date()

    func speed(for bytesReceived: Int64, at time: Date) -> Double {
        lock.lock()
        defer { lock.unlock() }

        let elapsed = time.timeIntervalSince(lastTime)
        let result = elapsed > 0
            ? Double(bytesReceived - lastBytes) / elapsed
            : 0
        lastBytes = bytesReceived
        lastTime = time
        return result
    }
}

/// 网络下载提供商。提供基于 URLSession 的 HTTP 下载能力，支持进度报告。
public actor NetworkDownloadProvider {
    public enum NetworkError: Error, LocalizedError, Sendable {
        case networkUnavailable
        case serviceUnavailable(String)
        case downloadInterrupted(String)
        case diskSpaceInsufficient(String)
        case integrityMismatch(String)
        case invalidURL(String)
        case httpError(statusCode: Int, message: String)
        case cancelled

        public var errorDescription: String? {
            switch self {
            case .networkUnavailable:
                return "网络不可用"
            case .serviceUnavailable(let detail):
                return "服务不可用: \(detail)"
            case .downloadInterrupted(let detail):
                return "下载中断: \(detail)"
            case .diskSpaceInsufficient(let detail):
                return "磁盘空间不足: \(detail)"
            case .integrityMismatch(let detail):
                return "文件完整性不匹配: \(detail)"
            case .invalidURL(let url):
                return "无效URL: \(url)"
            case .httpError(let code, let msg):
                return "HTTP错误 \(code): \(msg)"
            case .cancelled:
                return "下载已取消"
            }
        }
    }

    /// Typed terminal failures for URLSession download tasks. Domain code
    /// must use this value instead of parsing the localized compatibility text.
    public enum DownloadFailure: Error, LocalizedError, Sendable, Equatable {
        case http(statusCode: Int, message: String)
        case cancelled
        case transport(String)
        case missingHTTPResponse
        case nonHTTPResponse
        case temporaryFileMissing
        case diskSpaceInsufficient(String)
        case integrityMismatch(String)
        case fileOperation(String)

        public var statusCode: Int? {
            guard case .http(let statusCode, _) = self else { return nil }
            return statusCode
        }

        public var errorDescription: String? {
            switch self {
            case .http(let statusCode, let message):
                return "HTTP \(statusCode): \(message)"
            case .cancelled:
                return "下载已取消"
            case .transport(let detail):
                return "下载中断: \(detail)"
            case .missingHTTPResponse:
                return "下载失败: 未收到 HTTP 响应"
            case .nonHTTPResponse:
                return "下载失败: 响应不是 HTTP"
            case .temporaryFileMissing:
                return "下载失败: 未收到临时文件"
            case .diskSpaceInsufficient(let detail):
                return "下载失败: 磁盘空间不足，\(detail)"
            case .integrityMismatch(let detail):
                return "下载文件完整性校验失败: \(detail)"
            case .fileOperation(let detail):
                return "下载文件处理失败: \(detail)"
            }
        }

        // Compatibility seam for existing fixtures; business decisions use
        // the enum cases and statusCode above.
        public func contains(_ substring: String) -> Bool {
            errorDescription?.contains(substring) == true
        }
    }

    /// 下载进度信息
    public struct DownloadProgress: Sendable {
        public let bytesReceived: Int64
        public let totalBytes: Int64
        public let speed: Double // bytes per second
        public let fractionCompleted: Double
        /// Source: QA Report → F-002 — 错误信息（nil 表示无错误）
        public let error: String?
        /// The final response URL is retained so a Domain caller can validate
        /// redirect policy before accepting the downloaded bytes.
        public let responseURL: URL?
        /// Structured terminal failure for Domain consumers.
        public let failure: DownloadFailure?

        public init(
            bytesReceived: Int64,
            totalBytes: Int64,
            speed: Double,
            error: String? = nil,
            responseURL: URL? = nil,
            failure: DownloadFailure? = nil
        ) {
            self.bytesReceived = bytesReceived
            self.totalBytes = totalBytes
            self.speed = speed
            self.fractionCompleted = totalBytes > 0
                ? min(max(Double(bytesReceived) / Double(totalBytes), 0), 1)
                : 0
            self.error = error
            self.responseURL = responseURL
            self.failure = failure
        }
    }

    private let session: URLSession
    private var activeDownloadTasks: [UUID: URLSessionDownloadTask] = [:]
    private let decoder = JSONDecoder()
    private let defaultHeaders: [String: String] = [
        "User-Agent": "MiPlay/1.0 (macOS; Hyplay)",
        "Accept": "application/json, */*",
    ]

    public init(session: URLSession? = nil) {
        if let session {
            self.session = session
            return
        }
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 3600 // 1 hour for large downloads
        config.waitsForConnectivity = true
        config.httpAdditionalHeaders = defaultHeaders
        self.session = URLSession(configuration: config)
    }

    // MARK: - Download

    /// 下载文件，通过 AsyncStream 报告进度
    /// - Parameters:
    ///   - url: 下载 URL
    ///   - destinationPath: 目标文件路径
    ///   - expectedSize: 预期文件大小（可选，用于完整性校验）
    /// - Returns: 进度流 (AsyncStream)
    // A destination path is kept as an internal test/migration seam. Domain
    // callers should pass paths resolved inside their authorized scope.
    internal func download(
        from url: URL,
        to destinationPath: String,
        expectedSize: Int64? = nil,
        sessionID: UUID = UUID()
    ) -> AsyncStream<DownloadProgress> {
        return AsyncStream { continuation in
            let task = self.session.downloadTask(with: url) { tempURL, response, error in
                Task { await self.removeDownloadTask(sessionID: sessionID) }
                // Preserve a non-2xx HTTP outcome before handling a transport
                // error. Domain code must not lose the response status.
                if let httpResponse = response as? HTTPURLResponse,
                   !(200...299).contains(httpResponse.statusCode) {
                    let failure = DownloadFailure.http(
                        statusCode: httpResponse.statusCode,
                        message: HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode)
                    )
                    continuation.yield(DownloadProgress(
                        bytesReceived: 0,
                        totalBytes: 0,
                        speed: 0,
                        error: failure.localizedDescription,
                        responseURL: httpResponse.url,
                        failure: failure
                    ))
                    continuation.finish()
                    return
                }

                if let error {
                    let failure: DownloadFailure = error is URLError && (error as NSError).code == NSURLErrorCancelled
                        ? .cancelled
                        : .transport(error.localizedDescription)
                    // Source: QA Report -> F-002 - every terminal download error
                    // is carried through the stream instead of becoming EOF.
                    continuation.yield(DownloadProgress(
                        bytesReceived: 0,
                        totalBytes: 0,
                        speed: 0,
                        error: response == nil ? failure.localizedDescription : "下载失败: 未收到 HTTP 响应",
                        failure: failure
                    ))
                    continuation.finish()
                    return
                }

                guard let httpResponse = response as? HTTPURLResponse else {
                    let failure: DownloadFailure = response == nil ? .missingHTTPResponse : .nonHTTPResponse
                    continuation.yield(DownloadProgress(
                        bytesReceived: 0,
                        totalBytes: 0,
                        speed: 0,
                        error: response == nil ? failure.localizedDescription : "下载失败: 未收到 HTTP 响应",
                        failure: failure
                    ))
                    continuation.finish()
                    return
                }

                guard let tempURL = tempURL else {
                    let failure = DownloadFailure.temporaryFileMissing
                    continuation.yield(DownloadProgress(
                        bytesReceived: 0,
                        totalBytes: 0,
                        speed: 0,
                        error: failure.localizedDescription,
                        failure: failure
                    ))
                    continuation.finish()
                    return
                }

                do {
                    let fileManager = FileManager.default
                    let destURL = URL(fileURLWithPath: destinationPath)
                    let destDir = destURL.deletingLastPathComponent()
                    try fileManager.createDirectory(at: destDir, withIntermediateDirectories: true)

                    // Check disk space
                    let freeSpace = try fileManager.attributesOfFileSystem(forPath: destDir.path)[.systemFreeSize] as? Int64 ?? 0
                    let fileSize = try fileManager.attributesOfItem(atPath: tempURL.path)[.size] as? Int64 ?? 0
                    if freeSpace < fileSize * 2 {
                        let failure = DownloadFailure.diskSpaceInsufficient("无法保存下载文件")
                        continuation.yield(DownloadProgress(
                            bytesReceived: 0,
                            totalBytes: fileSize,
                            speed: 0,
                            error: failure.localizedDescription,
                            failure: failure
                        ))
                        continuation.finish()
                        return
                    }

                    try fileManager.moveItem(at: tempURL, to: destURL)

                    // Verify expected size
                    if let expectedSize = expectedSize {
                        let actualSize = try fileManager.attributesOfItem(atPath: destURL.path)[.size] as? Int64 ?? 0
                        if actualSize != expectedSize {
                            do {
                                try fileManager.removeItem(at: destURL)
                            } catch {
                                let failure = DownloadFailure.fileOperation(
                                    "下载文件大小不匹配，且错误文件清理失败: \(error.localizedDescription)"
                                )
                                continuation.yield(DownloadProgress(
                                    bytesReceived: actualSize,
                                    totalBytes: expectedSize,
                                    speed: 0,
                                    error: failure.localizedDescription,
                                    failure: failure
                                ))
                                continuation.finish()
                                return
                            }
                            let failure = DownloadFailure.integrityMismatch(
                                "预期 \(expectedSize)，实际 \(actualSize)"
                            )
                            continuation.yield(DownloadProgress(
                                bytesReceived: actualSize,
                                totalBytes: expectedSize,
                                speed: 0,
                                error: failure.localizedDescription,
                                failure: failure
                            ))
                            continuation.finish()
                            return
                        }
                    }

                    // Report final progress
                    continuation.yield(DownloadProgress(
                        bytesReceived: fileSize,
                        totalBytes: fileSize,
                        speed: 0,
                        responseURL: httpResponse.url
                    ))
                    continuation.finish()
                } catch {
                    let failure = DownloadFailure.fileOperation(error.localizedDescription)
                    continuation.yield(DownloadProgress(
                        bytesReceived: 0,
                        totalBytes: 0,
                        speed: 0,
                        error: failure.localizedDescription,
                        failure: failure
                    ))
                    continuation.finish()
                }
            }

            // Source: QA Report → F-004 — 基于时间差分的下载速度计算
            //
            // 进度来源：轮询 `URLSessionTask.countOfBytesReceived/ExpectedToReceive`。
            // 实测两种"官方"途径都拿不到持续进度：
            // - `NSProgress` 的 KVO（fractionCompleted）只会给出 `5/100` → `100/100`
            //   → 真实字节三个值，界面因此长时间停在 5%；
            // - 带完成回调的任务不会回调 `URLSessionDownloadDelegate.didWriteData`。
            // 轮询字节计数与完成回调兼容，且字节数是真实值（不是百分比单位）。
            let progressState = DownloadProgressState()
            let progressMonitor = Task {
                while !Task.isCancelled {
                    let received = task.countOfBytesReceived
                    let expected = task.countOfBytesExpectedToReceive
                    if received > 0 {
                        let speed = progressState.speed(for: received, at: Date())
                        continuation.yield(DownloadProgress(
                            bytesReceived: received,
                            totalBytes: expected > 0 ? expected : (expectedSize ?? 0),
                            speed: speed
                        ))
                    }
                    try? await Task.sleep(for: .milliseconds(150))
                }
            }

            // Cleanup on finish
            continuation.onTermination = { @Sendable _ in
                progressMonitor.cancel()
                task.cancel()
                Task { await self.removeDownloadTask(sessionID: sessionID) }
            }

            self.activeDownloadTasks[sessionID] = task
            task.resume()
        }
    }

    /// Cancels the URLSession task belonging to one Wine download session.
    public func cancelDownload(sessionID: UUID) {
        activeDownloadTasks.removeValue(forKey: sessionID)?.cancel()
    }

    private func removeDownloadTask(sessionID: UUID) {
        activeDownloadTasks.removeValue(forKey: sessionID)
    }

    // MARK: - API Request

    /// 发起 API 请求并解码为指定类型
    /// Source: Architecture → ADR 017 — 支持可选 HTTP 头（如 Authorization）
    public func request<T: Decodable>(
        _ type: T.Type,
        from url: URL,
        queryItems: [URLQueryItem]? = nil,
        additionalHeaders: [String: String]? = nil
    ) async throws -> T {
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        if let queryItems = queryItems {
            components?.queryItems = queryItems
        }

        guard let finalURL = components?.url else {
            throw NetworkError.invalidURL(url.absoluteString)
        }

        var request = URLRequest(url: finalURL)
        request.httpMethod = "GET"
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if let additionalHeaders = additionalHeaders {
            for (key, value) in additionalHeaders {
                request.setValue(value, forHTTPHeaderField: key)
            }
        }

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NetworkError.serviceUnavailable("无效的响应")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let responseBody = String(data: Data(data.prefix(512)), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let diagnostics = [
                HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode),
                responseBody.map { "response=\($0)" },
                httpResponse.value(forHTTPHeaderField: "X-RateLimit-Remaining").map { "rateLimitRemaining=\($0)" },
                httpResponse.value(forHTTPHeaderField: "X-RateLimit-Reset").map { "rateLimitReset=\($0)" },
                httpResponse.value(forHTTPHeaderField: "Retry-After").map { "retryAfter=\($0)" }
            ].compactMap { $0 }.joined(separator: "; ")
            throw NetworkError.httpError(
                statusCode: httpResponse.statusCode,
                message: diagnostics
            )
        }

        do {
            return try decoder.decode(type, from: data)
        } catch {
            throw NetworkError.serviceUnavailable("响应解码失败: \(error.localizedDescription)")
        }
    }

    /// 发起 API 请求获取原始数据
    /// Source: Architecture → ADR 017 — 支持可选 HTTP 头（如 Authorization）
    public func requestData(from url: URL, additionalHeaders: [String: String]? = nil) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        if let additionalHeaders = additionalHeaders {
            for (key, value) in additionalHeaders {
                request.setValue(value, forHTTPHeaderField: key)
            }
        }

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw NetworkError.serviceUnavailable("无效的响应")
        }

        guard (200...299).contains(httpResponse.statusCode) else {
            let responseBody = String(data: Data(data.prefix(512)), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let diagnostics = [
                HTTPURLResponse.localizedString(forStatusCode: httpResponse.statusCode),
                responseBody.map { "response=\($0)" },
                httpResponse.value(forHTTPHeaderField: "X-RateLimit-Remaining").map { "rateLimitRemaining=\($0)" },
                httpResponse.value(forHTTPHeaderField: "X-RateLimit-Reset").map { "rateLimitReset=\($0)" },
                httpResponse.value(forHTTPHeaderField: "Retry-After").map { "retryAfter=\($0)" }
            ].compactMap { $0 }.joined(separator: "; ")
            throw NetworkError.httpError(
                statusCode: httpResponse.statusCode,
                message: diagnostics
            )
        }

        return data
    }

    // MARK: - Network Status

    /// 检查网络是否可用（简单检测）
    public func checkNetworkAvailability() async -> Bool {
        do {
            let url = URL(string: "https://www.apple.com")!
            var request = URLRequest(url: url)
            request.httpMethod = "HEAD"
            request.timeoutInterval = 5

            let (_, response) = try await session.data(for: request)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }
}
