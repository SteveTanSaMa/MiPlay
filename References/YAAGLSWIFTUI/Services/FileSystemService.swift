import Foundation

/// File system operations.
/// Replaces Neutralino's filesystem API.
enum FileSystemService {

    // MARK: - Errors

    enum FSError: LocalizedError {
        case fileNotFound(URL)
        case operationFailed(String)

        var errorDescription: String? {
            switch self {
            case .fileNotFound(let url):
                return "File not found: \(url.path)"
            case .operationFailed(let msg):
                return msg
            }
        }
    }

    private static let fm = FileManager.default

    // MARK: - Path Helpers

    /// Resolve a path relative to the app's support directory.
    static func appSupportPath(_ subpath: String = "") -> URL {
        let paths = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        let base = paths[0].appendingPathComponent("YAAGLSWIFTUI")
        if subpath.isEmpty { return base }
        return base.appendingPathComponent(subpath)
    }

    /// Resolve a path relative to the bundle's Resources directory.
    static func resourcePath(_ subpath: String = "") -> URL {
        guard let resources = Bundle.main.resourceURL else {
            return URL(fileURLWithPath: "./")
        }
        if subpath.isEmpty { return resources }
        return resources.appendingPathComponent(subpath)
    }

    /// Resolve a sidecar binary path.
    /// Checks bundle resources first, then falls back to the YAAGL project directory (dev mode).
    static func sidecarPath(_ subpath: String = "") -> URL {
        // Bundle resource (production)
        let bundled = resourcePath("sidecar")
        if subpath.isEmpty { return bundled }
        let bundledPath = bundled.appendingPathComponent(subpath)
        if fm.fileExists(atPath: bundledPath.path) { return bundledPath }

        // YAAGL project sidecar (development fallback)
        let fallback = URL(fileURLWithPath: Bundle.main.bundlePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("YAAGL/sidecar")
            .appendingPathComponent(subpath)
        if fm.fileExists(atPath: fallback.path) { return fallback }

        return bundledPath
    }

    // MARK: - File Operations

    static func fileExists(at url: URL) -> Bool {
        fm.fileExists(atPath: url.path)
    }

    static func directoryExists(at url: URL) -> Bool {
        var isDir: ObjCBool = false
        let exists = fm.fileExists(atPath: url.path, isDirectory: &isDir)
        return exists && isDir.boolValue
    }

    static func fileSize(at url: URL) throws -> Int64 {
        let attrs = try fm.attributesOfItem(atPath: url.path)
        return (attrs[.size] as? Int64) ?? 0
    }

    @discardableResult
    static func createDirectory(at url: URL, intermediates: Bool = true) throws -> URL {
        try fm.createDirectory(at: url, withIntermediateDirectories: intermediates, attributes: nil)
        return url
    }

    static func removeItem(at url: URL) throws {
        try fm.removeItem(at: url)
    }

    static func removeItemIfExists(at url: URL) throws {
        if fm.fileExists(atPath: url.path) {
            try fm.removeItem(at: url)
        }
    }

    static func copyItem(from src: URL, to dst: URL) throws {
        try fm.copyItem(at: src, to: dst)
    }

    static func moveItem(from src: URL, to dst: URL) throws {
        try fm.moveItem(at: src, to: dst)
    }

    static func contentsOfDirectory(at url: URL) throws -> [URL] {
        try fm.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
    }

    // MARK: - Tar/GZip Extraction

    /// Extract a tar.gz or tar.xz archive to a destination directory.
    static func extractTarArchive(source: URL, destination: URL, isXZ: Bool = false) async throws {
        try createDirectory(at: destination)
        let flag = isXZ ? "-Jxvf" : "-zxvf"
        try await ProcessService.exec([
            .argument("tar"),
            .argument(flag),
            .argument(source.path),
            .argument("-C"),
            .argument(destination.path)
        ])
    }

    /// Extract a specific subdirectory from a tar archive, stripping path components.
    static func extractTarSubdirectory(
        source: URL,
        destination: URL,
        subdirectory: String,
        isXZ: Bool = false
    ) async throws {
        try createDirectory(at: destination)
        let stripCount = subdirectory.split(separator: "/").count
        let flag = isXZ ? "-Jxvf" : "-zxvf"
        try await ProcessService.exec([
            .argument("tar"),
            .argument("--strip-components"),
            .argument("\(stripCount)"),
            .argument("-C"),
            .argument(destination.path),
            .argument(flag),
            .argument(source.path),
            .argument(subdirectory)
        ])
    }

    // MARK: - 7z Extraction

    /// Extract a 7z archive.
    static func extract7z(source: URL, destination: URL) async throws {
        try createDirectory(at: destination)
        try await ProcessService.exec([
            .argument(sidecarPath("7z/7zz").path),
            .argument("x"),
            .argument(source.path),
            .argument("-o\(destination.path)"),
            .argument("-y")
        ])
    }

    /// Extract a segmented 7z archive (e.g., .001).
    static func extractSegmented7z(source: URL, destination: URL) async throws {
        try createDirectory(at: destination)
        let mainFile = source.path.hasSuffix(".001") ? source
            : findMainSegment(directory: source)
        try await ProcessService.exec([
            .argument(sidecarPath("7z/7zz").path),
            .argument("x"),
            .argument("-o\(destination.path)"),
            .argument(mainFile.path)
        ])
    }

    private static func findMainSegment(directory: URL) -> URL {
        // Find .001 file in directory
        guard let contents = try? fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) else {
            return directory
        }
        return contents.first { $0.pathExtension == "001" } ?? directory
    }

    // MARK: - Disk Space

    /// Get free disk space for the volume containing the given path, in gigabytes.
    static func freeDiskSpace(at url: URL) async -> Int64 {
        let fileURL = url.hasDirectoryPath ? url : url.deletingLastPathComponent()
        let keys: [URLResourceKey] = [.volumeAvailableCapacityKey, .volumeAvailableCapacityForImportantUsageKey]
        guard let values = try? fileURL.resourceValues(forKeys: Set(keys)) else {
            return (try? await fallbackFreeDiskSpace(at: url)) ?? 0
        }
        // Use ImportantUsageKey (more accurate for system-managed space), fall back to raw capacity
        if let capacity = values.volumeAvailableCapacityForImportantUsage {
            return Int64(capacity / 1_000_000_000) // bytes → GB
        }
        if let capacity = values.volumeAvailableCapacity {
            return Int64(capacity) / 1_000_000_000
        }
        return 0
    }

    /// Fallback using df command (slower but always works).
    private static func fallbackFreeDiskSpace(at url: URL) async throws -> Int64 {
        let result = try await ProcessService.exec([
            .argument("/bin/df"),
            .argument("-g"),
            .argument(url.path),
            .raw("|"),
            .argument("/usr/bin/awk"),
            .raw("NR==2{print $4}")
        ])
        return Int64(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    // MARK: - Quarantine

    /// Remove quarantine extended attributes from extracted files.
    /// Uses `-s` flag to also act on symlinks themselves (matches YAAGL's `xattrRemove`).
    static func removeQuarantine(at url: URL) async throws {
        _ = try? await ProcessService.exec([
            .argument("/bin/sh"), .argument("-c"),
            .raw("xattr -s -r -d com.apple.quarantine '\(url.path)' 2>/dev/null; exit 0")
        ])
    }

    // MARK: - File Hash

    /// Calculate MD5 hash of a file.
    static func md5(of url: URL) async throws -> String {
        let result = try await ProcessService.exec([
            .argument("md5"),
            .argument("-q"),
            .argument(url.path)
        ])
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Calculate SHA256 hash of file contents.
    static func sha256(of data: Data) -> String {
        let hash = data.sha256()
        return hash.map { String(format: "%02x", $0) }.joined()
    }
}
