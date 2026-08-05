import Foundation

/// Launcher self-update service.
/// Checks for new YAAGL versions on GitHub and downloads updates.
/// Replaces YAAGL's `updater.ts`.
@Observable
final class UpdaterService {

    // MARK: - Types

    enum UpdateState: Equatable {
        case checking
        case upToDate
        case updateAvailable(version: String, releaseNotes: String?)
        case downloading(progress: Double)
        case readyToInstall
        case failed(String)
    }

    // MARK: - Configuration

    private let githubService: GitHubService
    private let downloadService: DownloadService
    private let configService: ConfigService

    private(set) var updateState: UpdateState = .upToDate
    private(set) var latestVersion: String = ""
    private(set) var releaseNotes: String = ""

    private let currentVersion: String

    // MARK: - Initialization

    init(githubService: GitHubService, downloadService: DownloadService, configService: ConfigService) {
        self.githubService = githubService
        self.downloadService = downloadService
        self.configService = configService

        // Read version from Info.plist or use a default
        self.currentVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String
            ?? ProcessInfo.processInfo.environment["YAAGL_VERSION"]
            ?? "1.0.0"
    }

    // MARK: - Check for Updates

    /// Check for a new version of the launcher.
    func checkForUpdates() async {
        // Skip in development
        guard !isDevelopment else {
            updateState = .upToDate
            return
        }

        // Check if user has ignored updates
        if configService.config.ignoreLauncherUpdate {
            updateState = .upToDate
            return
        }

        updateState = .checking

        do {
            let release = try await githubService.fetchLatestRelease()
            let tagVersion = release.tagName.replacingOccurrences(of: "v", with: "")

            guard tagVersion.isNewerVersion(than: currentVersion) else {
                updateState = .upToDate
                return
            }

            latestVersion = tagVersion
            releaseNotes = release.body ?? ""
            updateState = .updateAvailable(version: tagVersion, releaseNotes: release.body)
        } catch {
            updateState = .failed("Failed to check for updates: \(error.localizedDescription)")
        }
    }

    /// Download the latest update.
    func downloadUpdate() -> AsyncThrowingStream<ProgressEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    let release = try await githubService.fetchLatestRelease()
                    let tagVersion = release.tagName.replacingOccurrences(of: "v", with: "")

                    // Find the .neu resource file and sidecar tar.gz
                    guard let mainAsset = githubService.findAsset(named: "resources_\(tagVersion).neu", in: release) ??
                                          githubService.findAsset(named: ".neu", in: release) else {
                        continuation.finish(throwing: UpdateError.assetNotFound("Main resource file"))
                        return
                    }

                    updateState = .downloading(progress: 0)

                    // Download main resource file
                    guard let downloadURL = githubService.acceleratedURL(for: mainAsset) else {
                        continuation.finish(throwing: UpdateError.invalidURL)
                        return
                    }

                    let destURL = FileSystemService.appSupportPath("resources.neu.update")

                    for try await progress in downloadService.download(from: downloadURL, to: destURL) {
                        updateState = .downloading(progress: progress.fraction)
                        continuation.yield(.download(progress))
                    }

                    // Also download sidecar if available
                    if let sidecarAsset = githubService.findAsset(named: "sidecar", in: release),
                       let sidecarURL = githubService.acceleratedURL(for: sidecarAsset) {
                        let sidecarDest = FileSystemService.appSupportPath("sidecar_update.tar.gz")
                        for try await progress in downloadService.download(from: sidecarURL, to: sidecarDest) {
                            continuation.yield(.download(progress))
                        }
                        // Extract sidecar
                        try await FileSystemService.extractTarArchive(source: sidecarDest, destination: FileSystemService.appSupportPath("sidecar"))
                        try? FileSystemService.removeItem(at: sidecarDest)
                    }

                    // Move update to final location
                    let finalDest = FileSystemService.appSupportPath("resources.neu")
                    try? FileSystemService.removeItem(at: finalDest)
                    try FileSystemService.moveItem(from: destURL, to: finalDest)

                    updateState = .readyToInstall
                    continuation.yield(.completed)
                } catch {
                    updateState = .failed(error.localizedDescription)
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// Relaunch the app to apply the update.
    func applyUpdate() {
        // For a macOS app, this would trigger a relaunch
        // Relies on the update being staged at resources.neu
        let task = Process()
        task.executableURL = Bundle.main.bundleURL
        try? task.run()

        // Exit current process
        exit(0)
    }

    // MARK: - Helpers

    private var isDevelopment: Bool {
        currentVersion == "1.0.0" || currentVersion.contains("dev")
    }
}

// MARK: - Errors

extension UpdaterService {
    enum UpdateError: LocalizedError {
        case assetNotFound(String)
        case invalidURL

        var errorDescription: String? {
            switch self {
            case .assetNotFound(let name): return "Required asset not found: \(name)"
            case .invalidURL: return "Invalid download URL"
            }
        }
    }
}
