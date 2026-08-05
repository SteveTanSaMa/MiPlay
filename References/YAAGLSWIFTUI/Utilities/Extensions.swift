import Foundation
import CommonCrypto

// MARK: - Data + Hash

extension Data {
    func sha256() -> Data {
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        self.withUnsafeBytes { buffer in
            _ = CC_SHA256(buffer.baseAddress, CC_LONG(self.count), &hash)
        }
        return Data(hash)
    }

    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - String + Version Comparison

extension String {
    /// Compare semantic version strings (e.g. "5.3.0" > "5.2.1").
    func versionCompare(_ other: String) -> ComparisonResult {
        let lhsParts = self.split(separator: ".").compactMap { Int($0) }
        let rhsParts = other.split(separator: ".").compactMap { Int($0) }
        let maxLen = max(lhsParts.count, rhsParts.count)
        for i in 0..<maxLen {
            let l = i < lhsParts.count ? lhsParts[i] : 0
            let r = i < rhsParts.count ? rhsParts[i] : 0
            if l < r { return .orderedAscending }
            if l > r { return .orderedDescending }
        }
        return .orderedSame
    }

    /// Check if version is newer than the other.
    func isNewerVersion(than other: String) -> Bool {
        self.versionCompare(other) == .orderedDescending
    }
}

// MARK: - URL Session

extension URLSession {
    /// Download a file to a destination with progress reporting via AsyncSequence.
    func downloadWithProgress(from url: URL, to destination: URL) -> AsyncThrowingStream<DownloadProgress, Error> {
        AsyncThrowingStream { continuation in
            let task = self.downloadTask(with: url) { tempURL, response, error in
                if let error = error {
                    continuation.finish(throwing: error)
                    return
                }
                guard let tempURL = tempURL else {
                    continuation.finish(throwing: URLError(.unknown))
                    return
                }
                do {
                    try FileManager.default.moveItem(at: tempURL, to: destination)
                    let totalBytes = response?.expectedContentLength ?? 0
                    continuation.yield(DownloadProgress(
                        url: url, totalBytes: totalBytes, downloadedBytes: totalBytes, speedBytesPerSecond: 0
                    ))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }

            // Track progress via delegate — we'll set up a simple timer-based approach
            Task {
                var lastBytes = Int64(0)
                var lastTime = Date()
                while task.state == .running || task.state == .suspended {
                    try? await Task.sleep(nanoseconds: 500_000_000) // 500ms
                    let progress = task.progress
                    let downloaded = progress.completedUnitCount
                    let total = progress.totalUnitCount
                    let now = Date()
                    let elapsed = now.timeIntervalSince(lastTime)
                    let speed = elapsed > 0 ? Double(downloaded - lastBytes) / elapsed : 0
                    lastBytes = downloaded
                    lastTime = now

                    continuation.yield(DownloadProgress(
                        url: url, totalBytes: total, downloadedBytes: downloaded, speedBytesPerSecond: speed
                    ))
                }
            }

            task.resume()
        }
    }
}
