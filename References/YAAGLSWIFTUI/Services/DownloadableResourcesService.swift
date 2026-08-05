import Foundation

/// Manages downloadable runtime dependencies: MoltenVK, DXVK, Jadeite, DXMT, ReShade.
/// Replaces YAAGL's `downloadable-resource.ts`.
enum DownloadableResourcesService {

    // MARK: - Constants

    static let currentMVKVersion = "1.2.10"
    static let currentDXVKVersion = "1.10.3"
    static let currentJadeiteVersion = "1.3.0"
    static let currentDXMTVersion = "0.74"
    static let currentReshadeVersion = "5.9.0"

    // MARK: - Resource URLs

    enum Resource {
        case moltenVK
        case dxvk
        case jadeite
        case dxmt
        case reshade

        var remoteURL: URL {
            switch self {
            case .moltenVK:
                return URL(string: "https://github.com/KhronosGroup/MoltenVK/releases/download/v\(currentMVKVersion)/MoltenVK-\(currentMVKVersion)-macos.tar")!
            case .dxvk:
                return URL(string: "https://github.com/doitsujin/dxvk/releases/download/v\(currentDXVKVersion)/dxvk-\(currentDXVKVersion).tar.gz")!
            case .jadeite:
                return URL(string: "https://github.com/3Shain/jadeite/releases/download/v\(currentJadeiteVersion)/jadeite-\(currentJadeiteVersion).tar.gz")!
            case .dxmt:
                return URL(string: "https://github.com/3Shain/dxmt/releases/download/v\(currentDXMTVersion)/dxmt-\(currentDXMTVersion).tar.gz")!
            case .reshade:
                return URL(string: "https://github.com/crosire/reshade/releases/download/v\(currentReshadeVersion)/ReShade_Setup_\(currentReshadeVersion).exe")!
            }
        }

        var installDirName: String {
            switch self {
            case .moltenVK: return "MoltenVK"
            case .dxvk: return "DXVK"
            case .jadeite: return "jadeite"
            case .dxmt: return "dxmt"
            case .reshade: return "reshade"
            }
        }
    }

    // MARK: - Check & Download

    /// Check if a resource is installed, and download it if not.
    static func ensureResource(
        _ resource: Resource,
        downloadService: DownloadService
    ) -> AsyncThrowingStream<ProgressEvent, Error> {
        AsyncThrowingStream { continuation in
            let installDir = FileSystemService.appSupportPath(resource.installDirName)
            let versionFile = installDir.appendingPathComponent(".version")
            let archiveURL = FileSystemService.appSupportPath("\(resource.installDirName)_archive.tar.gz")

            // Check if already installed
            if let versionData = try? Data(contentsOf: versionFile),
               let currentVersion = String(data: versionData, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) {
                let expectedVersion: String
                switch resource {
                case .moltenVK: expectedVersion = currentMVKVersion
                case .dxvk: expectedVersion = currentDXVKVersion
                case .jadeite: expectedVersion = currentJadeiteVersion
                case .dxmt: expectedVersion = currentDXMTVersion
                case .reshade: expectedVersion = currentReshadeVersion
                }
                guard currentVersion != expectedVersion else {
                    continuation.yield(.message("\(resource.installDirName) already up to date"))
                    continuation.finish()
                    return
                }
            }

            Task {
                do {
                    try? FileSystemService.removeItem(at: installDir)
                    try FileSystemService.createDirectory(at: installDir)

                    for try await progress in downloadService.download(from: resource.remoteURL, to: archiveURL) {
                        continuation.yield(.download(progress))
                    }

                    // Extract based on resource type
                    switch resource {
                    case .moltenVK:
                        try await FileSystemService.extractTarArchive(source: archiveURL, destination: installDir)
                    case .dxvk:
                        try await FileSystemService.extractTarArchive(source: archiveURL, destination: installDir)
                    case .jadeite:
                        try await FileSystemService.extractTarArchive(source: archiveURL, destination: installDir)
                    case .dxmt:
                        try await FileSystemService.extractTarArchive(source: archiveURL, destination: installDir)
                    case .reshade:
                        try extractReshade(from: archiveURL, to: installDir)
                    }

                    // Write version file
                    let version: String
                    switch resource {
                    case .moltenVK: version = currentMVKVersion
                    case .dxvk: version = currentDXVKVersion
                    case .jadeite: version = currentJadeiteVersion
                    case .dxmt: version = currentDXMTVersion
                    case .reshade: version = currentReshadeVersion
                    }
                    try version.write(to: versionFile, atomically: true, encoding: .utf8)

                    try? FileSystemService.removeItem(at: archiveURL)

                    continuation.yield(.message("\(resource.installDirName) installed"))
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - DXVK Files

    static let DXVKFiles = [
        "x64/d3d9.dll",
        "x64/d3d10core.dll",
        "x64/d3d11.dll",
        "x64/dxgi.dll",
    ]

    // MARK: - DXMT Files

    static let DXMTFiles = [
        "dxmt/d3d9.dll",
        "dxmt/d3d11.dll",
        "dxmt/dxgi.dll",
    ]

    static let DXMTFilesWithUnixLib = DXMTFiles + ["dxmt/libdxmt.dylib"]

    // MARK: - ReShade Extraction

    private static func extractReshade(from source: URL, to destination: URL) throws {
        let data = try Data(contentsOf: source)

        // Find ZIP header in the exe (PK\x03\x04)
        guard let zipStart = BinaryUtils.binaryPatternSearch(in: data, pattern: [0x50, 0x4B, 0x03, 0x04]) else {
            throw FileSystemService.FSError.operationFailed("Could not find embedded ZIP in ReShade installer")
        }

        let zipData = data.advanced(by: zipStart)

        // Write the embedded ZIP and extract
        let zipPath = destination.appendingPathComponent("reshade.zip")
        try zipData.write(to: zipPath)

        // Use unzip to extract — fire-and-forget is OK here; errors surface via the caller's Task
        Task {
            try? await ProcessService.exec([
                .argument("/usr/bin/unzip"),
                .argument("-o"),
                .argument(zipPath.path),
                .argument("-d"),
                .argument(destination.path)
            ])
        }

        try? FileSystemService.removeItem(at: zipPath)

        // Rename ReShade64.dll to dxgi.dll
        let reshade64 = destination.appendingPathComponent("ReShade64.dll")
        let dxgi = destination.appendingPathComponent("dxgi.dll")
        if FileSystemService.fileExists(at: reshade64) {
            try FileSystemService.moveItem(from: reshade64, to: dxgi)
        }
    }
}
