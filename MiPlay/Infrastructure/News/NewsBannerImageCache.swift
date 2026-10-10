import Foundation
import CryptoKit
import ImageIO

nonisolated struct NewsBannerImage: @unchecked Sendable {
    let cgImage: CGImage
}

/// Decode once at banner display resolution, away from the main actor.
actor NewsBannerImageCache {
    private let network: NetworkDownloadProvider
    private let directory: URL
    private var images: [URL: NewsBannerImage] = [:]
    private var order: [URL] = []

    init(network: NetworkDownloadProvider) {
        self.network = network
        directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MiPlay/NewsBanners-v1", isDirectory: true)
    }

    func image(for url: URL) async throws -> NewsBannerImage {
        if let image = images[url] { return image }
        let name = SHA256.hash(data: Data(url.absoluteString.utf8)).map { String(format: "%02x", $0) }.joined()
        let file = directory.appendingPathComponent(name)
        let data: Data
        let downloaded: Bool
        if let attributes = try? FileManager.default.attributesOfItem(atPath: file.path),
           let date = attributes[.modificationDate] as? Date,
           Date().timeIntervalSince(date) < 7 * 24 * 3600,
           let cached = try? Data(contentsOf: file) {
            data = cached
            downloaded = false
        } else {
            data = try await network.requestData(from: url)
            downloaded = true
        }
        try Task.checkCancellation()
        guard data.count <= 12 * 1024 * 1024,
              let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceThumbnailMaxPixelSize: 900,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true
              ] as CFDictionary) else {
            try? FileManager.default.removeItem(at: file)
            throw HoYoPlayNewsProvider.NewsError.invalidResponse
        }
        let result = NewsBannerImage(cgImage: image)
        images[url] = result
        order.removeAll { $0 == url }
        order.append(url)
        if order.count > 18 { images.removeValue(forKey: order.removeFirst()) }
        // Cache failure is best-effort; it must not hide a downloaded image.
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if downloaded { try? data.write(to: file, options: .atomic) }
        pruneDiskCache()
        return result
    }

    private func pruneDiskCache() {
        let keys: Set<URLResourceKey> = [.contentModificationDateKey, .fileSizeKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: Array(keys)) else { return }
        let entries = files.compactMap { file -> (URL, Date, Int)? in
            guard let values = try? file.resourceValues(forKeys: keys) else { return nil }
            return (file, values.contentModificationDate ?? .distantPast, values.fileSize ?? 0)
        }.sorted { $0.1 > $1.1 }
        var total = 0
        for (index, entry) in entries.enumerated() {
            total += entry.2
            if index >= 30 || total > 40 * 1024 * 1024 || Date().timeIntervalSince(entry.1) >= 7 * 24 * 3600 {
                try? FileManager.default.removeItem(at: entry.0)
            }
        }
    }
}
