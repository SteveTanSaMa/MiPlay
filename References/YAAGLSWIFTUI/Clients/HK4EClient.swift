import Foundation

/// Genshin Impact (HK4E) client — uses Sophon protocol for install/update.
/// Supports both CN (hk4e_cn) and Global (hk4e_global) servers.
final class HK4EClient: GameClient {

    let game: Game
    private let server: GameServer
    private let wineService: WineService
    private let downloadService: DownloadService
    private let configService: ConfigService
    private let sophonService: SophonService

    private let releaseType: String

    // MARK: - Initialization

    init?(game: Game, wineService: WineService, downloadService: DownloadService, configService: ConfigService, sophonService: SophonService) {
        guard game.server.usesSophon else { return nil }
        self.game = game
        self.server = game.server
        self.wineService = wineService
        self.downloadService = downloadService
        self.configService = configService
        self.sophonService = sophonService
        self.releaseType = game == .hk4eCN ? "cn" : "os"
    }

    // MARK: - Sophon Server

    /// Ensure the Sophon server is reachable before performing operations.
    /// Returns true if ready, false if unavailable (caller should handle gracefully).
    private func ensureSophonServer() async -> Bool {
        // Quick health-check with timeout
        if (try? await withTimeout(3) { [self] in try await sophonService.healthCheck() }) == true {
            return true
        }
        // Try to start it
        do {
            _ = try sophonService.startServer(terminateWithPID: Int32(ProcessInfo.processInfo.processIdentifier))
        } catch {
            LogService.gameLog("Sophon server not available: \(error.localizedDescription). Game operations requiring Sophon will be skipped.")
            return false
        }
        // Wait for readiness
        for _ in 0..<30 {
            if (try? await sophonService.healthCheck()) == true {
                LogService.gameLog("Sophon server started on port \(sophonService.port)")
                return true
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
        LogService.gameLog("Sophon server timed out — operations requiring Sophon will be skipped.")
        return false
    }

    /// Run a block with a timeout.
    private func withTimeout<T>(_ seconds: TimeInterval, block: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await block() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw SophonService.SophonError.connectionFailed("Request timed out after \(seconds)s")
            }
            let result = try await group.next()!
            group.cancelAll()
            return result
        }
    }

    // MARK: - Game Client Protocol

    var installState: GameInstallState {
        get async {
            let dir = await installDir
            guard let dir = dir else { return .notInstalled }

            let exePath = dir.appendingPathComponent(server.executable)
            guard FileSystemService.fileExists(at: exePath) else {
                return .notInstalled
            }

            // Try to read version from globalgamemanagers
            let dataDir = dir.appendingPathComponent(server.dataDir)
            let version = BinaryUtils.readUnityVersion(fromGameDataDir: dataDir, offset: 0xAC)
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
            let onlineInfo = try? await sophonService.getLatestOnlineGameInfo(relType: releaseType, gameType: "hk4e")
            guard let onlineVersion = onlineInfo?.version else { return false }
            return version.isNewerVersion(than: onlineVersion)
        }
    }

    // MARK: - UI Content

    var backgroundImageURL: URL? {
        get async {
            let content = await HoyoverseAdvService.fetchAdvContent(for: server)
            return content.backgroundURL
        }
    }

    var backgroundVideoURL: URL? { nil }
    var logoImageURL: URL? { nil }
    var iconImageURL: URL? { nil }
    var websiteURL: URL? {
        game == .hk4eCN
            ? URL(string: "https://ys.mihoyo.com/")
            : URL(string: "https://genshin.hoyoverse.com/")
    }

    // MARK: - Actions

    func install(to directory: URL) -> AsyncThrowingStream<ProgressEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                defer { continuation.finish() }

                do {
                    guard await ensureSophonServer() else {
                        continuation.yield(.message("Sophon server is not available. Please install the Sophon backend or install the game manually."))
                        return
                    }

                    // Check disk space
                    let freeSpace = await FileSystemService.freeDiskSpace(at: directory)
                    continuation.yield(.message("Free space: \(freeSpace) GB"))

                    // Get online info for size
                    _ = try await sophonService.getLatestOnlineGameInfo(relType: releaseType, gameType: "hk4e")

                    // Create temp dir
                    let tempDir = FileSystemService.appSupportPath("hk4e_temp")
                    try FileSystemService.createDirectory(at: tempDir)

                    // Start installation
                    let taskId = try await sophonService.startInstallation(options: .init(
                        gameDir: directory.path,
                        gameType: "hk4e",
                        tempDir: tempDir.path,
                        installRelType: releaseType
                    ))

                    // Stream progress
                    for try await event in sophonService.streamOperationProgress(taskId: taskId) {
                        switch event.type {
                        case "download_summary":
                            if let size = event.totalBytes {
                                continuation.yield(.message("Download size: \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))"))
                            }
                        case "chunk_progress":
                            if event.progressPercent != nil {
                                continuation.yield(.download(DownloadProgress(
                                    url: URL(string: "sophon://install")!,
                                    totalBytes: event.totalBytes ?? 1,
                                    downloadedBytes: event.downloadedBytes ?? 0,
                                    speedBytesPerSecond: event.downloadSpeed ?? 0
                                )))
                            }
                        case "file_download_start":
                            if let name = event.filename {
                                continuation.yield(.message("Downloading \(name)"))
                            }
                        case "file_download_complete":
                            if let name = event.filename {
                                LogService.gameLog("Downloaded: \(name)")
                            }
                        case "completed":
                            continuation.yield(.completed)
                        case "error":
                            if let err = event.error {
                                continuation.finish(throwing: SophonService.SophonError.taskFailed(err))
                            }
                        default:
                            break
                        }
                    }

                    // Save install directory
                    configService.setInstallDir(directory.path)
                    continuation.yield(.message("Installation complete"))
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
                    guard await ensureSophonServer() else {
                        continuation.yield(.message("Sophon server is not available. Please install the Sophon backend or install the game manually."))
                        return
                    }

                    guard let dir = await installDir else {
                        continuation.finish(throwing: GameService.GameError.notInstalled)
                        return
                    }

                    let tempDir = FileSystemService.appSupportPath("hk4e_temp")
                    try FileSystemService.createDirectory(at: tempDir)

                    let taskId = try await sophonService.startUpdate(options: .init(
                        gameDir: dir.path,
                        gameType: "hk4e",
                        tempDir: tempDir.path,
                        predownload: false
                    ))

                    for try await event in sophonService.streamOperationProgress(taskId: taskId) {
                        if event.type == "completed" {
                            continuation.yield(.completed)
                        } else if event.type == "error" {
                            if let err = event.error {
                                continuation.finish(throwing: SophonService.SophonError.taskFailed(err))
                            }
                        }
                    }

                    // Clean up temp
                    try? FileSystemService.removeItem(at: tempDir)
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
                    guard await ensureSophonServer() else {
                        continuation.yield(.message("Sophon server is not available. Please install the Sophon backend or install the game manually."))
                        return
                    }

                    guard let dir = await installDir else {
                        continuation.finish(throwing: GameService.GameError.notInstalled)
                        return
                    }

                    let tempDir = FileSystemService.appSupportPath("hk4e_temp")
                    let taskId = try await sophonService.startUpdate(options: .init(
                        gameDir: dir.path,
                        gameType: "hk4e",
                        tempDir: tempDir.path,
                        predownload: true
                    ))

                    for try await event in sophonService.streamOperationProgress(taskId: taskId) {
                        if event.type == "download_summary" {
                            if let size = event.totalBytes {
                                continuation.yield(.message("Pre-download size: \(ByteCountFormatter.string(fromByteCount: size, countStyle: .file))"))
                            }
                        } else if event.type == "completed" {
                            continuation.yield(.completed)
                        }
                    }
                } catch {
                    continuation.finish(throwing: error)
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

                    let gameExecutable = dir.appendingPathComponent(server.executable)
                    guard FileSystemService.fileExists(at: gameExecutable) else {
                        continuation.finish(throwing: GameService.GameError.executableNotFound)
                        return
                    }

                    continuation.yield(.message("Configuring Wine..."))

                    // Inject DXMT DLLs for D3D→Metal translation
                    await installDXMTIfNeeded()

                    // Set Wine display properties
                    try await wineService.setDriverProperties(
                        retina: config.retinaMode,
                        leftCmd: config.leftCommandIsCtrl
                    )

                    // HDR registry (HK4E-specific)
                    if config.hk4eEnableHDR {
                        continuation.yield(.message("Applying HDR settings..."))
                        try await applyHDRRegistry(config: config)
                    }

                    // Resolution registry
                    if config.hk4eResolutionCustom {
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

                    // Create launch script
                    continuation.yield(.message("Preparing launch..."))
                    let launchScript = buildLaunchScript(config: config)
                    let scriptPath = dir.appendingPathComponent("config.bat")
                    try launchScript.write(to: scriptPath, atomically: true, encoding: .utf8)

                    // Apply patches
                    continuation.yield(.message("Applying patches..."))
                    try await patchGame(at: dir, config: config)

                    // Steam patch
                    if config.hk4eSteamPatch {
                        continuation.yield(.message("Setting up Steam patch..."))
                        setupSteamPatch(in: dir)
                    }

                    // Block network if needed
                    if config.hk4eBlockNet, let blockURL = server.blockURL {
                        continuation.yield(.message("Blocking network..."))
                        try await HostsService.ensureHosts(entries: [blockURL: "0.0.0.0"])
                    }

                    // Launch the game
                    continuation.yield(.message("Launching game..."))

                    let wineEnv = buildWineEnvironment(config: config)
                    let result = try await wineService.run(
                        program: "cmd",
                        arguments: ["/c", wineService.toWinePath(scriptPath.path)],
                        environment: wineEnv
                    )
                    LogService.saveGameLog(gameName: game.displayName, stdout: result.stdout, stderr: result.stderr)

                    // Cleanup
                    try? FileSystemService.removeItem(at: scriptPath)
                    if config.hk4eSteamPatch {
                        cleanupSteamPatch(in: dir)
                    }
                    if config.hk4eEnableHDR {
                        try await revertHDRRegistry()
                    }
                    if config.hk4eBlockNet {
                        try await HostsService.removeYaaglEntries()
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
            Task {
                do {
                    guard await ensureSophonServer() else {
                        continuation.yield(.message("Sophon server is not available. Please install the Sophon backend or install the game manually."))
                        return
                    }

                    guard let dir = await installDir else {
                        continuation.finish(throwing: GameService.GameError.notInstalled)
                        return
                    }

                    let tempDir = FileSystemService.appSupportPath("hk4e_temp")
                    let taskId = try await sophonService.startRepair(options: .init(
                        gameDir: dir.path,
                        gameType: "hk4e",
                        tempDir: tempDir.path,
                        repairMode: "reliable"
                    ))

                    for try await event in sophonService.streamOperationProgress(taskId: taskId) {
                        if event.type == "repair_summary" {
                            if let total = event.totalBytes {
                                continuation.yield(.message("Checking \(total) files..."))
                            }
                        } else if event.type == "completed" {
                            continuation.yield(.completed)
                        }
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    func initialize(config: AppConfig) async throws {
        // Roll back any existing patches
        try await revertPatches(at: configService.config.installDir(for: game))
    }

    func dismissPredownload() {
        // No-op — predownload prompt dismissed
    }

    // MARK: - Configuration

    func configSections() -> [GameConfigSection] {
        [
            GameConfigSection(id: "hk4e_video", title: "Video", items: [
                .toggle(id: "hk4e_hdr", title: "HDR", isOn: configService.config.hk4eEnableHDR, action: { [weak self] value in
                    self?.configService.config.hk4eEnableHDR = value
                }),
                .toggle(id: "hk4e_resolution", title: "Custom Resolution", isOn: configService.config.hk4eResolutionCustom, action: { [weak self] value in
                    self?.configService.config.hk4eResolutionCustom = value
                }),
            ]),
            GameConfigSection(id: "hk4e_patches", title: "Patches", items: [
                .toggle(id: "hk4e_patch_off", title: "Turn Off AC Patch", isOn: configService.config.hk4ePatchOff, action: { [weak self] value in
                    self?.configService.config.hk4ePatchOff = value
                }),
                .toggle(id: "hk4e_steam_patch", title: "Steam Patch", isOn: configService.config.hk4eSteamPatch, action: { [weak self] value in
                    self?.configService.config.hk4eSteamPatch = value
                }),
                .toggle(id: "hk4e_block_net", title: "Block Network", isOn: configService.config.hk4eBlockNet, action: { [weak self] value in
                    self?.configService.config.hk4eBlockNet = value
                }),
                .toggle(id: "hk4e_timeout_fix", title: "Timeout Fix", isOn: configService.config.hk4eTimeoutFix, action: { [weak self] value in
                    self?.configService.config.hk4eTimeoutFix = value
                }),
                .toggle(id: "hk4e_workaround3", title: "Workaround #3", isOn: configService.config.hk4eWorkaround3Enabled, action: { [weak self] value in
                    self?.configService.config.hk4eWorkaround3Enabled = value
                }),
            ]),
        ]
    }

    // MARK: - Private: HDR Registry

    private func applyHDRRegistry(config: AppConfig) async throws {
        let regContent: String
        if game == .hk4eCN {
            regContent = """
            Windows Registry Editor Version 5.00
            [HKEY_CURRENT_USER\\Software\\miHoYo\\原神]
            "WINDOWS_HDR_ON"=dword:00000001
            """
        } else {
            regContent = """
            Windows Registry Editor Version 5.00
            [HKEY_CURRENT_USER\\Software\\miHoYo\\Genshin Impact]
            "WINDOWS_HDR_ON"=dword:00000001
            """
        }
        try await wineService.importRegistry(regContent)
    }

    private func revertHDRRegistry() async throws {
        let key = game == .hk4eCN
            ? "HKEY_CURRENT_USER\\Software\\miHoYo\\原神"
            : "HKEY_CURRENT_USER\\Software\\miHoYo\\Genshin Impact"
        try await wineService.deleteRegistryKey(key)
    }

    // MARK: - Private: Resolution Registry

    private func applyResolutionRegistry(config: AppConfig) async throws {
        let width = config.hk4eResolutionWidth
        let height = config.hk4eResolutionHeight
        let regContent: String
        if game == .hk4eCN {
            regContent = """
            Windows Registry Editor Version 5.00
            [HKEY_CURRENT_USER\\Software\\miHoYo\\原神]
            "WINDOWS_HDR_ON"=dword:00000000
            "WINDOWS_RESOLUTION_WIDTH"=dword:\(String(format: "%08x", Int(width) ?? 1920))
            "WINDOWS_RESOLUTION_HEIGHT"=dword:\(String(format: "%08x", Int(height) ?? 1200))
            """
        } else {
            regContent = """
            Windows Registry Editor Version 5.00
            [HKEY_CURRENT_USER\\Software\\miHoYo\\Genshin Impact]
            "WINDOWS_HDR_ON"=dword:00000000
            "WINDOWS_RESOLUTION_WIDTH"=dword:\(String(format: "%08x", Int(width) ?? 1920))
            "WINDOWS_RESOLUTION_HEIGHT"=dword:\(String(format: "%08x", Int(height) ?? 1200))
            """
        }
        try await wineService.importRegistry(regContent)
    }

    // MARK: - Private: Steam Patch

    /// Files to copy from sidecar for Steam patch.
    private static let steamPatchFiles: [(source: String, dest: String)] = [
        ("protonextras/steam64.exe", "steam.exe"),
        ("protonextras/lsteamclient64.dll", "lsteamclient64.dll"),
    ]

    /// Copy steam.exe and lsteamclient DLL into the game directory.
    private func setupSteamPatch(in gameDir: URL) {
        for (srcRel, destName) in Self.steamPatchFiles {
            let src = FileSystemService.sidecarPath(srcRel)
            let dest = gameDir.appendingPathComponent(destName)
            guard FileSystemService.fileExists(at: src) else {
                LogService.gameLog("Steam patch file not found: \(srcRel)")
                continue
            }
            try? FileSystemService.copyItem(from: src, to: dest)
        }
    }

    /// Remove steam patch files from the game directory.
    private func cleanupSteamPatch(in gameDir: URL) {
        for (_, destName) in Self.steamPatchFiles {
            let dest = gameDir.appendingPathComponent(destName)
            try? FileSystemService.removeItemIfExists(at: dest)
        }
    }

    // MARK: - Private: Launch Script

    private func buildLaunchScript(config: AppConfig) -> String {
        if config.hk4eSteamPatch {
            return """
            @echo off
            cd "%~dp0"
            start /wait steam.exe
            """
        }
        // Normal launch with cloud platform args
        return """
        @echo off
        start /wait \(server.executable) -platform_type CLOUD_THIRD_PARTY_PC -is_cloud 1
        """
    }

    // MARK: - Private: Wine Environment

    private func buildWineEnvironment(config: AppConfig) -> [String: String] {
        var env: [String: String] = [:]

        if config.metalHudEnabled {
            env["MTL_HUD_ENABLED"] = "1"
        }
        if config.hk4eTimeoutFix || config.timeoutFix {
            env["WINE_ENABLE_TIMEOUT_FIX"] = "1"
        }
        if config.proxyEnabled {
            env["HTTP_PROXY"] = config.proxyHost
            env["HTTPS_PROXY"] = config.proxyHost
        }

        // DXMT environment
        env["WINEESYNC"] = "1"

        return env
    }

    // MARK: - Private: Patching

    /// Paths for files that need binary patching.
    private static let patchTargets: [String] = [
        "UserAssembly.dll",
        "UnityPlayer.dll"
    ]

    private func patchGame(at dir: URL, config: AppConfig) async throws {
        if config.hk4ePatchOff { return }

        let hpatchzBin = sidecarBinaryPath("hpatchz/hpatchz")
        guard FileSystemService.fileExists(at: hpatchzBin) else {
            LogService.gameLog("hpatchz binary not found, skipping patches")
            return
        }

        let backupDir = dir.appendingPathComponent(".yaagl_backup")
        _ = try? FileSystemService.createDirectory(at: backupDir)

        for target in Self.patchTargets {
            let targetFile = dir.appendingPathComponent(target)
            guard FileSystemService.fileExists(at: targetFile) else { continue }

            // Backup original
            let backup = backupDir.appendingPathComponent(target)
            if !FileSystemService.fileExists(at: backup) {
                try FileSystemService.copyItem(from: targetFile, to: backup)
            }

            // Look for a corresponding .diff file in the sidecar
            let diffFile = sidecarBinaryPath("hpatchz/\(target).diff")
            guard FileSystemService.fileExists(at: diffFile) else { continue }

            do {
                try await ProcessService.exec([
                    .argument(hpatchzBin.path),
                    .argument("-f"),
                    .argument(targetFile.path),
                    .argument(diffFile.path),
                    .argument(targetFile.path)
                ])
                LogService.gameLog("Patched \(target)")
            } catch {
                LogService.gameLog("Failed to patch \(target): \(error.localizedDescription)")
            }
        }
    }

    private func revertPatches(at dir: String) async throws {
        let dirURL = URL(fileURLWithPath: dir)
        let backupDir = dirURL.appendingPathComponent(".yaagl_backup")

        guard FileSystemService.directoryExists(at: backupDir) else { return }

        for target in Self.patchTargets {
            let backup = backupDir.appendingPathComponent(target)
            guard FileSystemService.fileExists(at: backup) else { continue }

            let targetFile = dirURL.appendingPathComponent(target)
            try? FileSystemService.removeItem(at: targetFile)
            try FileSystemService.copyItem(from: backup, to: targetFile)
            LogService.gameLog("Reverted patch for \(target)")
        }

        try? FileSystemService.removeItem(at: backupDir)
    }

    /// Locate a sidecar binary either from bundle resources or the YAAGL directory.
    private func sidecarBinaryPath(_ relativePath: String) -> URL {
        FileSystemService.sidecarPath(relativePath)
    }

    /// Install DXMT DLLs into Wine before launching.
    private func installDXMTIfNeeded() async {
        let dxmtDir = sidecarBinaryPath("dxmt")
        guard FileSystemService.directoryExists(at: dxmtDir) else { return }

        do {
            try await wineService.installDXMT(from: dxmtDir)
        } catch {
            LogService.gameLog("DXMT installation failed: \(error.localizedDescription)")
        }
    }
}
