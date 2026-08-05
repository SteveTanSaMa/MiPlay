import Foundation

/// Zenless Zone Zero (NAP) client — uses direct Hoyoverse API with 7z segmented downloads.
final class NAPClient: GameClient {

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

    var installState: GameInstallState {
        get async {
            let dir = await installDir
            guard let dir = dir else { return .notInstalled }
            let exePath = dir.appendingPathComponent(server.executable)
            guard FileSystemService.fileExists(at: exePath) else { return .notInstalled }

            let dataDir = dir.appendingPathComponent(server.dataDir)
            let version = BinaryUtils.readUnityVersion(fromGameDataDir: dataDir, offset: 0xC4)
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

    var backgroundImageURL: URL? { nil }
    var backgroundVideoURL: URL? { nil }
    var logoImageURL: URL? { nil }
    var iconImageURL: URL? { nil }
    var websiteURL: URL? { nil }

    var launchButtonLocation: LaunchButtonLocation { .left }

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
                    continuation.yield(.message("Installing ZZZ version \(version)..."))

                    if let gamePkgs = major.gamePkgs, !gamePkgs.isEmpty {
                        try await downloadAndExtractSegments(
                            gamePkgs: gamePkgs,
                            to: directory,
                            tempName: "nap_temp",
                            continuation: continuation
                        )
                    } else {
                        continuation.yield(.message("No download packages found — game may need manual installation"))
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

                    guard case .installed(let currentVersion) = await installState,
                          latestVersion.isNewerVersion(than: currentVersion) else {
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
                        tempName: "nap_temp",
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

                    continuation.yield(.message("Pre-downloading ZZZ \(major.version)..."))
                    let predownDir = dir.appendingPathComponent("predownload")
                    try FileSystemService.createDirectory(at: predownDir)

                    try await downloadAndExtractSegments(
                        gamePkgs: gamePkgs,
                        to: predownDir,
                        tempName: "nap_temp",
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
        tempName: String,
        continuation: AsyncThrowingStream<ProgressEvent, Error>.Continuation
    ) async throws {
        let tempDir = FileSystemService.appSupportPath(tempName)
        try FileSystemService.createDirectory(at: tempDir)

        for pkg in gamePkgs {
            guard let url = URL(string: pkg.url) else { continue }
            let filename = pkg.url.split(separator: "/").last.map(String.init) ?? "segment.7z"
            let dest = tempDir.appendingPathComponent(filename)

            continuation.yield(.message("Downloading \(filename)..."))
            for try await _ in downloadService.download(from: url, to: dest) {}
        }

        continuation.yield(.message("Extracting..."))
        try await FileSystemService.extractSegmented7z(source: tempDir, destination: directory)
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

                    continuation.yield(.message("Configuring Wine..."))

                    // Inject DXMT DLLs for D3D→Metal translation
                    await installDXMTIfNeeded()

                    try await wineService.setDriverProperties(retina: config.retinaMode, leftCmd: config.leftCommandIsCtrl)
                    try await wineService.setNVExtension()

                    // Resolution registry
                    if config.resolutionCustom {
                        continuation.yield(.message("Applying resolution settings..."))
                        try await applyResolutionRegistry(config: config)
                    }

                    // FPS Unlock
                    if config.fpsUnlock != .default {
                        continuation.yield(.message("Applying FPS unlock..."))
                        try await wineService.applyFPSUnlock(config.fpsUnlock)
                    }

                    // ReShade
                    if config.reshadeEnabled {
                        continuation.yield(.message("Installing ReShade..."))
                        try await wineService.installReshade(to: dir)
                    }

                    let script = """
                    @echo off
                    cd "%~dp0"
                    start /wait \(server.executable) -platform_type CLOUD_THIRD_PARTY_PC -is_cloud 1
                    """
                    let scriptPath = dir.appendingPathComponent("config.bat")
                    try script.write(to: scriptPath, atomically: true, encoding: .utf8)

                    if config.blockNet, let blockURL = server.blockURL {
                        try await HostsService.ensureHosts(entries: [blockURL: "0.0.0.0"])
                    }

                    let env = wineService.dxmtEnvironment(config: config)

                    continuation.yield(.message("Launching ZZZ..."))
                    let result = try await wineService.run(program: "cmd", arguments: ["/c", wineService.toWinePath(scriptPath.path)], environment: env)
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
        AsyncThrowingStream { continuation in continuation.finish() }
    }

    func initialize(config: AppConfig) async throws {}

    func configSections() -> [GameConfigSection] {
        [
            GameConfigSection(id: "nap_patches", title: "Patches", items: [
                .toggle(id: "nap_patch_off", title: "Turn Off Patches", isOn: configService.config.patchOff, action: { [weak self] value in
                    self?.configService.config.patchOff = value
                }),
                .toggle(id: "nap_block_net", title: "Block Network", isOn: configService.config.blockNet, action: { [weak self] value in
                    self?.configService.config.blockNet = value
                }),
                .toggle(id: "nap_steam_patch", title: "Steam Patch", isOn: configService.config.steamPatch, action: { [weak self] value in
                    self?.configService.config.steamPatch = value
                }),
                .toggle(id: "nap_timeout_fix", title: "Timeout Fix", isOn: configService.config.timeoutFix, action: { [weak self] value in
                    self?.configService.config.timeoutFix = value
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

    private func applyResolutionRegistry(config: AppConfig) async throws {
        guard let width = Int(config.resolutionWidth),
              let height = Int(config.resolutionHeight) else { return }

        let regContent = """
        Windows Registry Editor Version 5.00
        [HKEY_CURRENT_USER\\Software\\miHoYo\\\(game == .napCN ? "绝区零" : "ZenlessZoneZero")]
        "WINDOWS_RESOLUTION_WIDTH"=dword:\(String(format: "%08x", width))
        "WINDOWS_RESOLUTION_HEIGHT"=dword:\(String(format: "%08x", height))
        """
        try await wineService.importRegistry(regContent)
    }
}
