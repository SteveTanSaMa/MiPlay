import Foundation

/// Honkai: Star Rail (HKRPG) client — uses direct Hoyoverse API with 7z segmented downloads.
final class HKRPGClient: GameClient {

    let game: Game
    private let server: GameServer
    private let wineService: WineService
    private let downloadService: DownloadService
    private let configService: ConfigService

    init(game: Game, wineService: WineService, downloadService: DownloadService, configService: ConfigService) {
        self.game = game
        self.server = game.server
        self.wineService = wineService
        self.downloadService = downloadService
        self.configService = configService
    }

    // MARK: - Game State

    var installState: GameInstallState {
        get async {
            let dir = await installDir
            guard let dir = dir else { return .notInstalled }
            let exePath = dir.appendingPathComponent(server.executable)
            guard FileSystemService.fileExists(at: exePath) else { return .notInstalled }

            let dataDir = dir.appendingPathComponent(server.dataDir)
            let version = BinaryUtils.readUnity2019Version(fromGameDataDir: dataDir)
            return .installed(version: version ?? "Unknown")
        }
    }

    var installDir: URL? {
        get async {
            let dirPath = configService.config.installDir(for: game)
            guard !dirPath.isEmpty else { return nil }
            return URL(fileURLWithPath: dirPath)
        }
    }

    var updateRequired: Bool {
        get async {
            guard case .installed(let version) = await installState else { return false }
            guard let latestVersion = try? await HoyoverseAPI.fetchVersionInfo(server: server) else { return false }
            return latestVersion.isNewerVersion(than: version)
        }
    }

    var showPredownloadPrompt: Bool { false }

    // MARK: - UI Content

    var backgroundImageURL: URL? { nil }
    var backgroundVideoURL: URL? { nil }
    var logoImageURL: URL? { nil }
    var iconImageURL: URL? { nil }
    var websiteURL: URL? { nil }

    // MARK: - Actions

    func install(to directory: URL) -> AsyncThrowingStream<ProgressEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                defer { continuation.finish() }

                do {
                    try FileSystemService.createDirectory(at: directory)

                    continuation.yield(.message("Fetching game package info..."))

                    guard let package = try await HoyoverseAPI.fetchPackage(for: server),
                          let major = package.main?.major else {
                        continuation.finish(throwing: GameService.GameError.installDirectoryNotFound)
                        return
                    }

                    let version = major.version
                    continuation.yield(.message("Installing version \(version)..."))

                    if let gamePkgs = major.gamePkgs, !gamePkgs.isEmpty {
                        try await downloadAndExtractSegments(
                            gamePkgs: gamePkgs,
                            to: directory,
                            continuation: continuation
                        )
                    } else if let resListURL = major.resListURL {
                        // Fallback: download a single archive
                        try await downloadAndExtractSingleArchive(
                            urlString: resListURL,
                            to: directory,
                            continuation: continuation
                        )
                    } else {
                        continuation.finish(throwing: GameService.GameError.installDirectoryNotFound)
                        return
                    }

                    configService.setInstallDir(directory.path)
                    continuation.yield(.completed)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    func update() -> AsyncThrowingStream<ProgressEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                defer { continuation.finish() }

                do {
                    guard let dir = await installDir else {
                        continuation.finish(throwing: GameService.GameError.notInstalled)
                        return
                    }

                    continuation.yield(.message("Checking for updates..."))

                    guard let latestVersion = try? await HoyoverseAPI.fetchVersionInfo(server: server) else {
                        continuation.finish(throwing: GameService.GameError.installDirectoryNotFound)
                        return
                    }

                    guard case .installed(let currentVersion) = await installState else {
                        continuation.finish(throwing: GameService.GameError.notInstalled)
                        return
                    }

                    if !latestVersion.isNewerVersion(than: currentVersion) {
                        continuation.yield(.message("Game is up to date"))
                        continuation.yield(.completed)
                        return
                    }

                    continuation.yield(.message("Updating to \(latestVersion)..."))

                    guard let package = try await HoyoverseAPI.fetchPackage(for: server),
                          let major = package.main?.major,
                          let gamePkgs = major.gamePkgs, !gamePkgs.isEmpty else {
                        continuation.finish(throwing: GameService.GameError.installDirectoryNotFound)
                        return
                    }

                    try await downloadAndExtractSegments(
                        gamePkgs: gamePkgs,
                        to: dir,
                        continuation: continuation
                    )

                    continuation.yield(.completed)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    func predownload() -> AsyncThrowingStream<ProgressEvent, Error> {
        AsyncThrowingStream(ProgressEvent.self, bufferingPolicy: .unbounded) { continuation in
            Task {
                do {
                    guard let dir = await installDir else {
                        return continuation.finish(throwing: GameService.GameError.notInstalled)
                    }

                    guard let package = try await HoyoverseAPI.fetchPreDownloadPackage(for: server),
                          let major = package.preDownload?.major,
                          let gamePkgs = major.gamePkgs, !gamePkgs.isEmpty else {
                        continuation.yield(.message("No pre-download available"))
                        return continuation.finish()
                    }

                    continuation.yield(.message("Pre-downloading version \(major.version)..."))

                    let predownDir = dir.appendingPathComponent("predownload")
                    try FileSystemService.createDirectory(at: predownDir)

                    try await downloadAndExtractSegments(
                        gamePkgs: gamePkgs,
                        to: predownDir,
                        continuation: continuation
                    )

                    continuation.yield(.completed)
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    // MARK: - Private: Download Helpers

    private func downloadAndExtractSegments(
        gamePkgs: [HoyoverseAPI.GamePackage.GamePkg],
        to directory: URL,
        continuation: AsyncThrowingStream<ProgressEvent, Error>.Continuation
    ) async throws {
        let tempDir = FileSystemService.appSupportPath("hkrpg_temp")
        try FileSystemService.createDirectory(at: tempDir)

        var totalSize: Int64 = 0
        var downloadedSize: Int64 = 0

        for (_, pkg) in gamePkgs.enumerated() {
            guard let url = URL(string: pkg.url) else { continue }
            let filename = pkg.url.split(separator: "/").last.map(String.init) ?? "segment.7z"
            let dest = tempDir.appendingPathComponent(filename)
            totalSize += pkg.sizeBytes

            continuation.yield(.message("Downloading \(filename)..."))

            for try await progress in downloadService.download(from: url, to: dest) {
                downloadedSize += progress.downloadedBytes
            }

            // Verify MD5 if available
            if !pkg.md5.isEmpty {
                let actualMD5 = (try? await FileSystemService.md5(of: dest)) ?? ""
                guard actualMD5 == pkg.md5 else {
                    throw GameService.GameError.installDirectoryNotFound
                }
            }
        }

        continuation.yield(.message("Extracting files..."))
        try await FileSystemService.extractSegmented7z(source: tempDir, destination: directory)

        // Clean up temp
        try? FileSystemService.removeItem(at: tempDir)
    }

    private func downloadAndExtractSingleArchive(
        urlString: String,
        to directory: URL,
        continuation: AsyncThrowingStream<ProgressEvent, Error>.Continuation
    ) async throws {
        guard let url = URL(string: urlString) else {
            throw GameService.GameError.installDirectoryNotFound
        }

        let tempDir = FileSystemService.appSupportPath("hkrpg_temp")
        try FileSystemService.createDirectory(at: tempDir)
        let archiveURL = tempDir.appendingPathComponent("game_archive.7z")

        continuation.yield(.message("Downloading game archive..."))
        for try await _ in downloadService.download(from: url, to: archiveURL) {}

        continuation.yield(.message("Extracting..."))
        try await FileSystemService.extract7z(source: archiveURL, destination: directory)

        try? FileSystemService.removeItem(at: tempDir)
    }

    func launch(config: AppConfig) -> AsyncThrowingStream<ProgressEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                defer { continuation.finish() }

                do {
                    guard let dir = await installDir else {
                        continuation.finish(throwing: GameService.GameError.notInstalled)
                        return
                    }

                    let gameExecutable = dir.appendingPathComponent(server.executable)
                    guard FileSystemService.fileExists(at: gameExecutable) else {
                        continuation.finish(throwing: GameService.GameError.executableNotFound)
                        return
                    }

                    // Wine configuration
                    continuation.yield(.message("Configuring Wine..."))
                    await installDXMTIfNeeded()
                    try await wineService.setDriverProperties(retina: config.retinaMode, leftCmd: config.leftCommandIsCtrl)
                    try await wineService.setNVExtension()

                    // FPS Unlock
                    if config.fpsUnlock != .default {
                        continuation.yield(.message("Applying FPS unlock..."))
                        try await wineService.applyFPSUnlock(config.fpsUnlock)
                    }

                    // Build launch script
                    let script = """
                    @echo off
                    cd "%~dp0"
                    start /wait \(server.executable) -platform_type CLOUD_THIRD_PARTY_PC -is_cloud 1
                    """

                    let scriptPath = dir.appendingPathComponent("config.bat")
                    try script.write(to: scriptPath, atomically: true, encoding: .utf8)

                    // Block network if needed
                    if config.blockNet, let bh3BlockURL = server.blockURL {
                        try await HostsService.ensureHosts(entries: [bh3BlockURL: "0.0.0.0"])
                    }

                    // Launch
                    let env = wineService.dxmtEnvironment(config: config)

                    let result = try await wineService.run(
                        program: "cmd",
                        arguments: ["/c", wineService.toWinePath(scriptPath.path)],
                        environment: env
                    )
                    LogService.saveGameLog(gameName: game.displayName, stdout: result.stdout, stderr: result.stderr)

                    try? FileSystemService.removeItem(at: scriptPath)

                    if config.blockNet {
                        try? await HostsService.removeYaaglEntries()
                    }

                    continuation.yield(.completed)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    func checkIntegrity() -> AsyncThrowingStream<ProgressEvent, Error> {
        AsyncThrowingStream { continuation in
            // Would check pkg_version manifest against local files
            continuation.finish()
        }
    }

    func initialize(config: AppConfig) async throws {
        // Revert patches
    }

    func configSections() -> [GameConfigSection] {
        [
            GameConfigSection(id: "hkrpg_patches", title: "Patches", items: [
                .toggle(id: "hkrpg_patch_off", title: "Turn Off Patches", isOn: configService.config.patchOff, action: { [weak self] value in
                    self?.configService.config.patchOff = value
                }),
                .toggle(id: "hkrpg_block_net", title: "Block Network", isOn: configService.config.blockNet, action: { [weak self] value in
                    self?.configService.config.blockNet = value
                }),
            ])
        ]
    }

    // MARK: - Private Helpers

    private func installDXMTIfNeeded() async {
        let dxmtDir = FileSystemService.sidecarPath("dxmt")
        guard FileSystemService.directoryExists(at: dxmtDir) else { return }
        do {
            try await wineService.installDXMT(from: dxmtDir)
        } catch {
            LogService.gameLog("DXMT installation failed: \(error.localizedDescription)")
        }
    }
}
