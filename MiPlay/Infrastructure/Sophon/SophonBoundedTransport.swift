import Foundation

/// Bounded, chunk-oriented network receiver. It validates headers before
/// accepting data and retains one session so adjacent ranges reuse connections.
nonisolated final class SophonBoundedTransport: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private final class Operation {
        let continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>
        let limit: Int
        let requiredStatus: Int?
        let expectedURL: URL
        var response: HTTPURLResponse?
        var data = Data()
        var failure: Error?
        init(_ continuation: CheckedContinuation<(Data, HTTPURLResponse), Error>, limit: Int,
             requiredStatus: Int?, expectedURL: URL) {
            self.continuation = continuation; self.limit = limit; self.requiredStatus = requiredStatus; self.expectedURL = expectedURL
        }
    }
    private final class Cancellation: @unchecked Sendable {
        let lock = NSLock()
        var task: URLSessionDataTask?
        var cancelled = false
        func set(_ value: URLSessionDataTask) {
            lock.lock(); task = value; let shouldCancel = cancelled; lock.unlock()
            if shouldCancel { value.cancel() }
        }
        func cancel() {
            lock.lock(); cancelled = true; let value = task; lock.unlock()
            value?.cancel()
        }
    }
    private let configuration: URLSessionConfiguration
    private let lock = NSLock()
    private var operations: [Int: Operation] = [:]
    private var storedSession: URLSession?
    init(configuration: URLSessionConfiguration) { self.configuration = configuration; super.init() }
    func invalidate() {
        lock.lock(); let session = storedSession; storedSession = nil; lock.unlock()
        session?.invalidateAndCancel()
    }
    private func sharedSession() -> URLSession {
        lock.lock(); defer { lock.unlock() }
        if let session = storedSession { return session }
        let session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
        storedSession = session
        return session
    }

    func fetch(_ request: URLRequest, limit: Int, requiredStatus: Int? = nil) async throws -> (Data, HTTPURLResponse) {
        guard let url = request.url, url.scheme == "https", url.host != nil, limit >= 0 else {
            throw SophonProtocolError.invalidResponse("受限下载地址无效")
        }
        let cancellation = Cancellation()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let task = sharedSession().dataTask(with: request)
                lock.lock()
                operations[task.taskIdentifier] = Operation(continuation, limit: limit, requiredStatus: requiredStatus, expectedURL: url)
                lock.unlock()
                cancellation.set(task)
                task.resume()
            }
        } onCancel: { cancellation.cancel() }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        let original = task.originalRequest?.url
        let next = request.url
        completionHandler(next?.scheme == "https" && next?.host == original?.host && next?.port == original?.port ? request : nil)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        lock.lock()
        guard let operation = operations[dataTask.taskIdentifier], let http = response as? HTTPURLResponse,
              http.url?.scheme == "https", http.url?.host == operation.expectedURL.host,
              http.url?.port == operation.expectedURL.port,
              operation.requiredStatus.map({ http.statusCode == $0 }) ?? (200..<300).contains(http.statusCode),
              response.expectedContentLength < 0 || response.expectedContentLength <= Int64(operation.limit) else {
            if let operation = operations[dataTask.taskIdentifier] { operation.failure = SophonProtocolError.invalidResponse("下载响应头无效或内容过大") }
            lock.unlock(); completionHandler(.cancel); return
        }
        operation.response = http
        lock.unlock(); completionHandler(.allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        lock.lock()
        guard let operation = operations[dataTask.taskIdentifier] else { lock.unlock(); return }
        if data.count > operation.limit - operation.data.count {
            operation.failure = SophonProtocolError.corrupt("下载内容超过允许长度")
            lock.unlock(); dataTask.cancel(); return
        }
        operation.data.append(data)
        lock.unlock()
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        lock.lock(); let operation = operations.removeValue(forKey: task.taskIdentifier); lock.unlock()
        guard let operation else { return }
        if let failure = operation.failure ?? error { operation.continuation.resume(throwing: failure) }
        else if let response = operation.response { operation.continuation.resume(returning: (operation.data, response)) }
        else { operation.continuation.resume(throwing: SophonProtocolError.invalidResponse("下载没有响应")) }
    }
}
