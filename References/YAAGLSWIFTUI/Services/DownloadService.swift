import Foundation
import Observation

/// Download management service using URLSession.
/// Replaces aria2 WebSocket RPC client.
@Observable
final class DownloadService: NSObject, @unchecked Sendable {
    private var session: URLSession
    nonisolated private let activeTasksStore = ActiveTasksStore()
    private var _resumeDataCache: [URL: Data] = [:]

    // MARK: - Configuration

    struct Configuration {
        var maxConcurrentDownloads: Int = 4
        var timeout: TimeInterval = 300
    }

    var configuration: Configuration {
        didSet { updateConfiguration() }
    }

    // MARK: - Initialization

    override init() {
        let defaultConfig = Configuration()
        let sessionConfig = URLSessionConfiguration.default
        sessionConfig.timeoutIntervalForResource = defaultConfig.timeout
        sessionConfig.httpMaximumConnectionsPerHost = defaultConfig.maxConcurrentDownloads
        self.session = URLSession(configuration: sessionConfig)
        self.configuration = defaultConfig
        super.init()
    }

    // MARK: - Download

    /// Download a file from a URL to a destination path with progress and speed tracking.
    func download(from url: URL, to destination: URL) -> AsyncThrowingStream<DownloadProgress, Error> {
        let resumeData: Data? = loadResumeData(for: url)
        return streamDownload(url: url, destination: destination, resumeData: resumeData, retryCount: 0)
    }

    private func streamDownload(
        url: URL,
        destination: URL,
        resumeData: Data?,
        retryCount: Int
    ) -> AsyncThrowingStream<DownloadProgress, Error> {
        AsyncThrowingStream { continuation in
            let task: URLSessionDownloadTask
            if let data = resumeData, !data.isEmpty {
                task = session.downloadTask(withResumeData: data)
                saveResumeData(nil, for: url)
            } else {
                task = session.downloadTask(with: url)
            }

            let lock = NSLock()
            var lastBytesWritten = Int64(0)
            var lastTime = Date()

            let progressObserver = task.progress.observe(\.fractionCompleted) { progress, _ in
                lock.lock()
                let total = progress.totalUnitCount
                let completed = progress.completedUnitCount
                let now = Date()
                let elapsed = now.timeIntervalSince(lastTime)
                let speed = elapsed > 0 ? Double(completed - lastBytesWritten) / elapsed : 0
                lastBytesWritten = completed
                lastTime = now
                lock.unlock()

                continuation.yield(DownloadProgress(
                    url: url,
                    totalBytes: total,
                    downloadedBytes: completed,
                    speedBytesPerSecond: speed
                ))
            }

            var completionHandlerCalled = false
            let completionHandler: (URL?, URLResponse?, (any Error)?) -> Void = { tempURL, response, error in
                guard !completionHandlerCalled else { return }
                completionHandlerCalled = true

                progressObserver.invalidate()

                if let error = error {
                    let nsError = error as NSError
                    if nsError.domain == NSURLErrorDomain && nsError.code == NSURLErrorCancelled,
                       let data = nsError.userInfo[NSURLSessionDownloadTaskResumeData] as? Data {
                        self.saveResumeData(data, for: url)
                    }
                    if retryCount < 3 {
                        continuation.finish()
                        return
                    }
                    continuation.finish(throwing: error)
                    return
                }

                guard let tempURL = tempURL else {
                    continuation.finish(throwing: URLError(.unknown))
                    return
                }

                do {
                    let totalBytes = response?.expectedContentLength ?? Int64(0)
                    try? FileManager.default.removeItem(at: destination)
                    try FileManager.default.moveItem(at: tempURL, to: destination)
                    self.saveResumeData(nil, for: url)
                    continuation.yield(DownloadProgress(
                        url: url, totalBytes: totalBytes, downloadedBytes: totalBytes, speedBytesPerSecond: 0
                    ))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            task.delegate = TaskDelegate(completionHandler: completionHandler)
            activeTasksStore[url] = task

            let taskURL = url
            continuation.onTermination = { @Sendable _ in
                progressObserver.invalidate()
                if task.state == .running || task.state == .suspended {
                    task.cancel()
                }
                Task { @MainActor in
                    self.activeTasksStore.removeValue(forKey: taskURL)
                }
            }

            task.resume()
        }
    }

    // MARK: - Resume Data Persistence

    private func resumeDataCacheURL(for url: URL) -> URL {
        let hash = url.absoluteString.data(using: .utf8)?.base64EncodedString() ?? url.lastPathComponent
        return FileSystemService.appSupportPath("downloads").appendingPathComponent("\(hash).resume")
    }

    private func saveResumeData(_ data: Data?, for url: URL) {
        let cacheURL = resumeDataCacheURL(for: url)
        _ = try? FileSystemService.createDirectory(at: cacheURL.deletingLastPathComponent())
        if let data = data {
            try? data.write(to: cacheURL)
        } else {
            try? FileSystemService.removeItemIfExists(at: cacheURL)
        }
    }

    private func loadResumeData(for url: URL) -> Data? {
        let cacheURL = resumeDataCacheURL(for: url)
        return try? Data(contentsOf: cacheURL)
    }

    // MARK: - Batch Download

    /// Download multiple files concurrently, yielding progress per file.
    func downloadBatch(
        _ items: [(url: URL, destination: URL)]
    ) -> AsyncThrowingStream<(index: Int, progress: DownloadProgress), Error> {
        AsyncThrowingStream { continuation in
            Task { [self] in
                await withThrowingTaskGroup(of: (Int, DownloadProgress?).self) { group in
                    for (index, item) in items.enumerated() {
                        group.addTask {
                            for try await progress in await self.download(from: item.url, to: item.destination) {
                                return (index, progress)
                            }
                            return (index, nil)
                        }
                    }

                    do {
                        for try await (index, progress) in group {
                            if let progress = progress {
                                continuation.yield((index, progress))
                            }
                        }
                        continuation.finish()
                    } catch {
                        continuation.finish(throwing: error)
                    }
                }
            }
        }
    }

    // MARK: - Cancellation

    /// Cancel an active download.
    func cancelDownload(for url: URL) {
        activeTasksStore[url]?.cancel()
        activeTasksStore.removeValue(forKey: url)
    }

    /// Cancel all active downloads.
    func cancelAll() {
        for task in activeTasksStore.allValues {
            task.cancel()
        }
        activeTasksStore.removeAll()
    }

    // MARK: - Configuration

    private func updateConfiguration() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForResource = configuration.timeout
        config.httpMaximumConnectionsPerHost = configuration.maxConcurrentDownloads
        session = URLSession(configuration: config)
    }
}

// MARK: - URLSession Task Delegate

private final class TaskDelegate: NSObject, URLSessionTaskDelegate {
    let completionHandler: (URL?, URLResponse?, (any Error)?) -> Void

    init(completionHandler: @escaping (URL?, URLResponse?, (any Error)?) -> Void) {
        self.completionHandler = completionHandler
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        completionHandler(location, downloadTask.response, nil)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
        if let error = error {
            completionHandler(nil, task.response, error)
        }
    }
}
