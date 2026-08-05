//
//  DownloadManager.swift
//  MiPlay
//
//  Created by Steve Tan on 2026/6/20.
//

import Foundation

actor DownloadManager {
    enum DownloadError: LocalizedError {
        case invalidURL
        case networkError(String)
        case cancelled
        case fileError(String)

        var errorDescription: String? {
            switch self {
            case .invalidURL: return "无效的下载链接"
            case .networkError(let detail): return "网络错误: \(detail)"
            case .cancelled: return "下载已取消"
            case .fileError(let detail): return "文件错误: \(detail)"
            }
        }
    }

    private let fileManager = FileManager.default
    private let sessionDelegate = DownloadSessionDelegate()
    private lazy var session: URLSession = {
        URLSession(configuration: .default, delegate: sessionDelegate, delegateQueue: nil)
    }()

    func download(url: URL, to destination: URL) async throws -> URL {
        let (tempURL, response) = try await URLSession.shared.download(from: url)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw DownloadError.networkError("HTTP 状态码错误")
        }

        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }

        try fileManager.moveItem(at: tempURL, to: destination)
        return destination
    }

    /// 带进度报告的下载
    func downloadWithProgress(
        url: URL,
        to destination: URL,
        progressHandler: @Sendable @escaping (Double) -> Void
    ) async throws -> URL {
        // 用 delegate 方式创建下载任务
        let task = session.downloadTask(with: url)
        let delegate = sessionDelegate

        return try await withCheckedThrowingContinuation { continuation in
            // 注册进度回调
            delegate.registerHandler(for: task) { [progressHandler] result, downloadTask in
                switch result {
                case .success(let tempURL):
                    do {
                        if self.fileManager.fileExists(atPath: destination.path) {
                            try self.fileManager.removeItem(at: destination)
                        }
                        try self.fileManager.moveItem(at: tempURL, to: destination)
                        continuation.resume(returning: destination)
                    } catch {
                        continuation.resume(throwing: DownloadError.fileError(error.localizedDescription))
                    }
                case .failure(let error):
                    continuation.resume(throwing: error)
                }
            }

            // 注册进度回调
            delegate.registerProgressHandler(for: task) { progress in
                progressHandler(progress)
            }

            task.resume()
        }
    }

    func cancelDownload(url: URL) {
        session.getAllTasks { tasks in
            tasks.first { $0.originalRequest?.url == url }?.cancel()
        }
    }
}

// MARK: - URLSessionDownloadDelegate

private class DownloadSessionDelegate: NSObject, URLSessionDownloadDelegate {
    private var completionHandlers: [Int: (Result<URL, Error>) -> Void] = [:]
    private var progressHandlers: [Int: (Double) -> Void] = [:]
    private let lock = NSLock()

    func registerHandler(for task: URLSessionDownloadTask, handler: @escaping (Result<URL, Error>, URLSessionDownloadTask) -> Void) {
        lock.lock()
        completionHandlers[task.taskIdentifier] = { result in
            handler(result, task)
        }
        lock.unlock()
    }

    func registerProgressHandler(for task: URLSessionDownloadTask, handler: @escaping (Double) -> Void) {
        lock.lock()
        progressHandlers[task.taskIdentifier] = handler
        lock.unlock()
    }

    // MARK: - URLSessionDownloadDelegate

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try? FileManager.default.copyItem(at: location, to: tempURL)

        lock.lock()
        let handler = completionHandlers.removeValue(forKey: downloadTask.taskIdentifier)
        progressHandlers.removeValue(forKey: downloadTask.taskIdentifier)
        lock.unlock()

        handler?(.success(tempURL))
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        guard let error = error else { return }
        let downloadTask = task as? URLSessionDownloadTask

        lock.lock()
        let handler = downloadTask.flatMap { completionHandlers.removeValue(forKey: $0.taskIdentifier) }
        downloadTask.flatMap { progressHandlers.removeValue(forKey: $0.taskIdentifier) }
        lock.unlock()

        let nsError = error as NSError
        if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled {
            handler?(.failure(DownloadManager.DownloadError.cancelled))
        } else {
            handler?(.failure(DownloadManager.DownloadError.networkError(error.localizedDescription)))
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        let progress = min(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite), 1.0)

        lock.lock()
        let handler = progressHandlers[downloadTask.taskIdentifier]
        lock.unlock()

        // 进度回调直接在主线程执行（progressHandler 内部会用 Task @MainActor 切到主线程）
        handler?(progress)
    }
}
