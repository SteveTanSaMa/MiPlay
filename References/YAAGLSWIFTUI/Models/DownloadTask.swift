import Foundation

/// Represents a download operation with progress tracking.
struct DownloadTask: Identifiable {
    let id: UUID
    let url: URL
    let destination: URL
    let fileSize: Int64

    var downloadedBytes: Int64
    var status: DownloadStatus
    var error: Error?

    var progressFraction: Double {
        guard fileSize > 0 else { return 0 }
        return min(Double(downloadedBytes) / Double(fileSize), 1.0)
    }

    init(
        id: UUID = UUID(),
        url: URL,
        destination: URL,
        fileSize: Int64 = 0,
        downloadedBytes: Int64 = 0,
        status: DownloadStatus = .pending
    ) {
        self.id = id
        self.url = url
        self.destination = destination
        self.fileSize = fileSize
        self.downloadedBytes = downloadedBytes
        self.status = status
        self.error = nil
    }

    enum DownloadStatus: Equatable {
        case pending
        case downloading
        case paused
        case completed
        case failed
    }
}

/// A download progress event yielded by an async sequence.
struct DownloadProgress: Sendable {
    let url: URL
    let totalBytes: Int64
    let downloadedBytes: Int64
    let speedBytesPerSecond: Double

    var fraction: Double {
        guard totalBytes > 0 else { return 0 }
        return min(Double(downloadedBytes) / Double(totalBytes), 1.0)
    }
}

/// A generic progress event for any long-running operation.
enum ProgressEvent: Sendable {
    case download(DownloadProgress)
    case extraction(current: Int, total: Int)
    case patch(current: Int, total: Int)
    case integrityCheck(current: Int, total: Int)
    case message(String)
    case indeterminate
    case completed
    case failed(Error)
    
}
