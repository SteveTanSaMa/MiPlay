import Foundation

/// Honkai Impact 3rd (BH3) client — uses direct Hoyoverse API with single 7z downloads.
final class BH3Client: GameClient {

    let game: Game
    private let server: GameServer
    private let wineService: WineService
    private let downloadService: DownloadService
    private let configService: ConfigService

    private let supportedVersion = "7.5.0"

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
            let version = BinaryUtils.readUnityVersion(fromGameDataDir: dataDir)
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
            guard case .installed = await installState else { return false }
            // BH3-specific: fetch from resource API
            return false
        }
    }

    var backgroundImageURL: URL? { nil }
    var backgroundVideoURL: URL? { nil }
    var logoImageURL: URL? { nil }
    var iconImageURL: URL? { nil }
    var websiteURL: URL? { URL(string: "https://honkaiimpact3.hoyoverse.com/") }

    func install(to directory: URL) -> AsyncThrowingStream<ProgressEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                defer { continuation.finish() }
                do {
                    try FileSystemService.createDirectory(at: directory)

                    continuation.yield(.message("Fetching BH3 game info..."))

                    guard let gameInfo = try await BH3ResourceAPI.fetchLatestVersion(server: server) else {
                        continuation.finish(throwing: GameService.GameError.installDirectoryNotFound)
                        return
                    }

                    continuation.yield(.message("Installing Honkai Impact 3rd v\(gameInfo.version)..."))

                    guard let downloadURL = URL(string: gameInfo.decompressedPath) else {
                        continuation.finish(throwing: GameService.GameError.installDirectoryNotFound)
                        return
                    }

                    let tempDir = FileSystemService.appSupportPath("bh3_temp")
                    try FileSystemService.createDirectory(at: tempDir)
                    let archiveURL = tempDir.appendingPathComponent("BH3_\(gameInfo.version).zip")

                    continuation.yield(.message("Downloading game archive..."))
                    for try await _ in downloadService.download(from: downloadURL, to: archiveURL) {}

                    continuation.yield(.message("Extracting..."))
                    try await extractZip(source: archiveURL, destination: directory)

                    try? FileSystemService.removeItem(at: tempDir)
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

                    continuation.yield(.message("Checking for BH3 updates..."))

                    guard let gameInfo = try await BH3ResourceAPI.fetchLatestVersion(server: server) else {
                        continuation.finish(throwing: GameService.GameError.installDirectoryNotFound)
                        return
                    }

                    guard case .installed(let currentVersion) = await installState,
                          gameInfo.version.isNewerVersion(than: currentVersion) else {
                        continuation.yield(.message("BH3 is up to date"))
                        continuation.yield(.completed)
                        return
                    }

                    continuation.yield(.message("Updating to v\(gameInfo.version)..."))

                    guard let downloadURL = URL(string: gameInfo.decompressedPath) else {
                        continuation.finish(throwing: GameService.GameError.installDirectoryNotFound)
                        return
                    }

                    let tempDir = FileSystemService.appSupportPath("bh3_temp")
                    try FileSystemService.createDirectory(at: tempDir)
                    let archiveURL = tempDir.appendingPathComponent("BH3_\(gameInfo.version).zip")

                    for try await _ in downloadService.download(from: downloadURL, to: archiveURL) {}

                    continuation.yield(.message("Extracting..."))
                    try await extractZip(source: archiveURL, destination: dir)

                    try? FileSystemService.removeItem(at: tempDir)
                    continuation.yield(.completed)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    func predownload() -> AsyncThrowingStream<ProgressEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    continuation.yield(.message("BH3 does not support pre-download"))
                    continuation.finish()
                }
            }
        }
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
                    await installDXMTIfNeeded()
                    try await wineService.setDriverProperties(retina: config.retinaMode, leftCmd: config.leftCommandIsCtrl)

                    // FPS Unlock
                    if config.fpsUnlock != .default {
                        continuation.yield(.message("Applying FPS unlock..."))
                        try await wineService.applyFPSUnlock(config.fpsUnlock)
                    }

                    let script = """
                    @echo off
                    cd "%~dp0"
                    start /wait \(server.executable)
                    """
                    let scriptPath = dir.appendingPathComponent("config.bat")
                    try script.write(to: scriptPath, atomically: true, encoding: .utf8)

                    let env = wineService.dxmtEnvironment(config: config)

                    let result = try await wineService.run(program: "cmd", arguments: ["/c", wineService.toWinePath(scriptPath.path)], environment: env)
                    LogService.saveGameLog(gameName: game.displayName, stdout: result.stdout, stderr: result.stderr)

                    try? FileSystemService.removeItem(at: scriptPath)
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
            GameConfigSection(id: "bh3_info", title: "Game Info", items: [
                .info(id: "bh3_version", title: "Supported Version", value: supportedVersion)
            ])
        ]
    }

    // MARK: - Private Helpers

    private func extractZip(source: URL, destination: URL) async throws {
        try await ProcessService.exec([
            .argument("/usr/bin/unzip"),
            .argument("-o"),
            .argument(source.path),
            .argument("-d"),
            .argument(destination.path)
        ])
    }

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

// MARK: - BH3 Resource API

/// Honkai Impact 3rd-specific resource API.
/// BH3 uses a different endpoint format than standard Hoyoverse games.
enum BH3ResourceAPI {

    struct BH3GameInfo: Codable {
        let version: String
        let path: String
        let decompressedPath: String
        let size: String

        enum CodingKeys: String, CodingKey {
            case version
            case path
            case decompressedPath = "decompressed_path"
            case size
        }
    }

    private struct BH3Response: Codable {
        let retcode: Int
        let data: BH3Data?

        struct BH3Data: Codable {
            let game: BH3Game?

            struct BH3Game: Codable {
                let latest: BH3GameInfo?
            }
        }
    }

    static func fetchLatestVersion(server: GameServer) async throws -> BH3GameInfo? {
        guard let url = URL(string: server.updateURL) else { return nil }

        let session = URLSession.shared
        let (data, _) = try await session.data(from: url)

        let response = try JSONDecoder().decode(BH3Response.self, from: data)
        return response.data?.game?.latest
    }
}
