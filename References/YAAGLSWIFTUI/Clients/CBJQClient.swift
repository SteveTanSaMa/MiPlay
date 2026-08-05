import Foundation

/// Snowbreak: Containment Zone (CBJQ) client — uses Seasun manifest-based update system.
final class CBJQClient: GameClient {

    let game: Game
    private let server: GameServer
    private let wineService: WineService
    private let downloadService: DownloadService
    private let configService: ConfigService

    private let supportedVersion = "2.0.0"

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

            // CBJQ uses manifest.json to track version
            let manifestPath = dir.appendingPathComponent("manifest.json")
            let exePath = dir.appendingPathComponent(server.executable)

            // Check manifest first for version
            if let manifestData = try? Data(contentsOf: manifestPath),
               let manifest = try? JSONSerialization.jsonObject(with: manifestData) as? [String: Any],
               let version = manifest["projectVersion"] as? String {
                return .installed(version: version)
            }

            // Fallback: exe exists but no manifest
            if FileSystemService.fileExists(at: exePath) {
                return .installed(version: "Unknown")
            }
            return .notInstalled
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
            // TODO: Check against remote manifest
            return false
        }
    }

    var backgroundImageURL: URL? {
        // CBJQ uses a custom background URL from server definition
        URL(string: server.advURL).flatMap { $0 }
    }

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

                    continuation.yield(.message("Fetching CBJQ manifest..."))

                    guard let manifest = try await fetchRemoteManifest() else {
                        continuation.finish(throwing: GameService.GameError.installDirectoryNotFound)
                        return
                    }

                    guard let remoteVersion = manifest["projectVersion"] as? String,
                          let paks = manifest["paks"] as? [[String: Any]] else {
                        continuation.finish(throwing: GameService.GameError.installDirectoryNotFound)
                        return
                    }

                    continuation.yield(.message("Installing Snowbreak v\(remoteVersion) (\(paks.count) files)..."))

                    try await downloadPaks(paks, to: directory, continuation: continuation)

                    // Save manifest locally
                    let manifestData = try JSONSerialization.data(withJSONObject: manifest, options: .prettyPrinted)
                    try manifestData.write(to: directory.appendingPathComponent("manifest.json"))

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

                    continuation.yield(.message("Checking for CBJQ updates..."))

                    guard let remoteManifest = try await fetchRemoteManifest(),
                          let remoteVersion = remoteManifest["projectVersion"] as? String,
                          let paks = remoteManifest["paks"] as? [[String: Any]] else {
                        continuation.finish(throwing: GameService.GameError.installDirectoryNotFound)
                        return
                    }

                    guard case .installed(let currentVersion) = await installState,
                          remoteVersion.isNewerVersion(than: currentVersion) else {
                        continuation.yield(.message("Snowbreak is up to date"))
                        continuation.yield(.completed)
                        return
                    }

                    // Compare local vs remote manifests, download only new/changed paks
                    let localManifestPath = dir.appendingPathComponent("manifest.json")
                    var paksToDownload = paks

                    if let localData = try? Data(contentsOf: localManifestPath),
                       let localManifest = try? JSONSerialization.jsonObject(with: localData) as? [String: Any],
                       let localPaks = localManifest["paks"] as? [[String: Any]] {
                        let localMD5s = Set(localPaks.compactMap { $0["md5"] as? String })
                        paksToDownload = paks.filter { pak in
                            guard let md5 = pak["md5"] as? String else { return true }
                            return !localMD5s.contains(md5)
                        }
                    }

                    if paksToDownload.isEmpty {
                        continuation.yield(.message("Snowbreak is up to date"))
                        continuation.yield(.completed)
                        return
                    }

                    continuation.yield(.message("Updating Snowbreak (\(paksToDownload.count) new files)..."))

                    try await downloadPaks(paksToDownload, to: dir, continuation: continuation)

                    // Save updated manifest
                    let manifestData = try JSONSerialization.data(withJSONObject: remoteManifest, options: .prettyPrinted)
                    try manifestData.write(to: localManifestPath)

                    continuation.yield(.completed)
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    func predownload() -> AsyncThrowingStream<ProgressEvent, Error> {
        AsyncThrowingStream { continuation in
            continuation.yield(.message("CBJQ does not support pre-download"))
            continuation.finish()
        }
    }

    // MARK: - Private: Manifest & Download Helpers

    private func fetchRemoteManifest() async throws -> [String: Any]? {
        guard let url = URL(string: server.updateURL) else { return nil }

        let session = URLSession.shared
        let (data, _) = try await session.data(from: url)

        return try JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private func downloadPaks(
        _ paks: [[String: Any]],
        to directory: URL,
        continuation: AsyncThrowingStream<ProgressEvent, Error>.Continuation
    ) async throws {
        for (index, pak) in paks.enumerated() {
            guard let urlString = pak["url"] as? String,
                  let downloadURL = URL(string: urlString) else { continue }

            let filename = urlString.split(separator: "/").last.map(String.init) ?? "pak_\(index)"
            let dest = directory.appendingPathComponent(filename)

            continuation.yield(.message("Downloading \(index + 1)/\(paks.count): \(filename)"))
            for try await _ in downloadService.download(from: downloadURL, to: dest) {}

            // Verify MD5 if present
            if let expectedMD5 = pak["md5"] as? String, !expectedMD5.isEmpty {
                let actualMD5 = (try? await FileSystemService.md5(of: dest)) ?? ""
                if actualMD5 != expectedMD5 {
                    continuation.yield(.message("MD5 mismatch for \(filename), retrying..."))
                    try? FileSystemService.removeItem(at: dest)
                    for try await _ in downloadService.download(from: downloadURL, to: dest) {}
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

                    try await wineService.setDriverProperties(retina: config.retinaMode, leftCmd: config.leftCommandIsCtrl)

                    // CBJQ uses the UE4 executable path
                    let cbjqExecutable = "Game/Binaries/Win64/Game.exe"
                    let script = """
                    @echo off
                    cd "%~dp0"
                    start /wait \(cbjqExecutable) -FeatureLevelES31 -ChannelID
                    """
                    let scriptPath = dir.appendingPathComponent("config.bat")
                    try script.write(to: scriptPath, atomically: true, encoding: .utf8)

                    var env: [String: String] = ["WINEESYNC": "1"]
                    if config.metalHudEnabled { env["MTL_HUD_ENABLED"] = "1" }

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
        AsyncThrowingStream { continuation in
            Task {
                defer { continuation.finish() }
                guard let dir = await installDir else {
                    continuation.yield(.message("No install directory found"))
                    return
                }

                let manifestPath = dir.appendingPathComponent("manifest.json")
                guard let data = try? Data(contentsOf: manifestPath),
                      let manifest = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let paks = manifest["paks"] as? [[String: Any]] else {
                    continuation.yield(.message("No manifest found — cannot verify integrity"))
                    continuation.yield(.completed)
                    return
                }

                var failedCount = 0
                for (index, pak) in paks.enumerated() {
                    guard let md5 = pak["md5"] as? String, !md5.isEmpty,
                          let urlString = pak["url"] as? String else { continue }

                    let filename = urlString.split(separator: "/").last.map(String.init) ?? "pak_\(index)"
                    let fileURL = dir.appendingPathComponent(filename)

                    continuation.yield(.integrityCheck(current: index + 1, total: paks.count))

                    guard FileSystemService.fileExists(at: fileURL) else {
                        continuation.yield(.message("Missing: \(filename)"))
                        failedCount += 1
                        continue
                    }

                    let actualMD5 = (try? await FileSystemService.md5(of: fileURL)) ?? ""
                    if actualMD5 != md5 {
                        continuation.yield(.message("Corrupted: \(filename)"))
                        failedCount += 1
                    }
                }

                if failedCount == 0 {
                    continuation.yield(.message("All files verified ✓"))
                } else {
                    continuation.yield(.message("\(failedCount) file(s) need repair"))
                }
                continuation.yield(.completed)
            }
        }
    }

    func initialize(config: AppConfig) async throws {}

    func configSections() -> [GameConfigSection] {
        [
            GameConfigSection(id: "cbjq_info", title: "Game Info", items: [
                .info(id: "cbjq_version", title: "Supported Version", value: supportedVersion)
            ])
        ]
    }
}
