import Foundation

/// Wine environment management.
/// Replaces YAAGL's `wine/wine.ts`, `wine/distro.ts`, `wine/wine-install-program.ts`.
@Observable
final class WineService {

    // MARK: - Errors

    enum WineError: LocalizedError {
        case binaryNotFound
        case prefixCreationFailed
        case registryFailed(String)

        var errorDescription: String? {
            switch self {
            case .binaryNotFound: return "Wine binary not found"
            case .prefixCreationFailed: return "Failed to create Wine prefix"
            case .registryFailed(let msg): return "Registry operation failed: \(msg)"
            }
        }
    }

    // MARK: - Constants

    static let wineDirName = "wine"
    static let prefixDirName = "wine_prefix"

    // MARK: - State

    private(set) var status: WineStatus = .notInstalled
    private(set) var currentDistribution: WineDistribution?
    private(set) var wineBinaryPath: URL?

    // MARK: - Installation Directories

    /// Path to the installed Wine distribution (in app support).
    private var wineInstallDir: URL {
        FileSystemService.appSupportPath(WineService.wineDirName)
    }

    /// Path to the Wine prefix.
    private var winePrefixDir: URL {
        FileSystemService.appSupportPath(WineService.prefixDirName)
    }

    // MARK: - Initialization

    init() {
        // Detect existing wine installation
        detectCurrentWine()
    }

    private func detectCurrentWine() {
        let installDir = wineInstallDir
        guard FileSystemService.directoryExists(at: installDir) else {
            status = .notInstalled
            return
        }

        // Try to find wine binary
        if let binary = findWineBinary(in: installDir) {
            wineBinaryPath = binary
            status = .installed(distribution: currentDistribution ?? .default)
        } else {
            status = .notInstalled
        }
    }

    // MARK: - Wine Binary Location

    /// Find the wine binary inside a Wine distribution directory.
    private func findWineBinary(in distDir: URL) -> URL? {
        // Try wine64 first (WoW64 mode), fall back to wine
        let candidates = [
            distDir.appendingPathComponent("bin/wine64"),
            distDir.appendingPathComponent("bin/wine")
        ]
        // Also try distribution's winePath
        if let distro = currentDistribution, !distro.winePath.isEmpty {
            let customPath = distDir.appendingPathComponent("\(distro.winePath)/bin/wine64")
            let customPathFallback = distDir.appendingPathComponent("\(distro.winePath)/bin/wine")
            if FileSystemService.fileExists(at: customPath) {
                return customPath
            }
            if FileSystemService.fileExists(at: customPathFallback) {
                return customPathFallback
            }
        }
        return candidates.first { FileSystemService.fileExists(at: $0) }
    }

    // MARK: - Wine Operations

    /// Run a command inside the Wine environment.
    @discardableResult
    func run(program: String, arguments: [String] = [], environment: [String: String]? = nil) async throws -> ProcessService.ExecResult {
        guard let wineBin = wineBinaryPath else {
            throw WineError.binaryNotFound
        }

        var env = wineEnvironment()
        if let extraEnv = environment {
            for (key, value) in extraEnv {
                env[key] = value
            }
        }

        let wineArgs: [CommandSegment]
        if program == "copy" {
            wineArgs = [.argument(wineBin.path), .argument("cmd"), .argument("/c"), .argument(program)]
                + arguments.map { .argument($0) }
        } else {
            wineArgs = [.argument(wineBin.path), .argument(program)] + arguments.map { .argument($0) }
        }

        return try await ProcessService.exec(wineArgs, environment: env)
    }

    /// Run a command inside Wine and stream output.
    func runAsync(program: String, arguments: [String] = [], environment: [String: String]? = nil) -> (stream: AsyncThrowingStream<String, Error>, process: Process) {
        guard let wineBin = wineBinaryPath else {
            fatalError("Wine binary not found")
        }

        var env = wineEnvironment()
        if let extraEnv = environment {
            for (key, value) in extraEnv {
                env[key] = value
            }
        }

        let wineArgs: [CommandSegment]
        if program == "copy" {
            wineArgs = [.argument(wineBin.path), .argument("cmd"), .argument("/c"), .argument(program)]
        } else {
            wineArgs = [.argument(wineBin.path), .argument(program)]
        }

        return ProcessService.spawn(wineArgs, environment: env)
    }

    /// Run a cmd.exe command inside Wine.
    @discardableResult
    func cmd(_ command: String, arguments: [String] = []) async throws -> ProcessService.ExecResult {
        try await run(program: "cmd", arguments: ["/c", command] + arguments)
    }

    // MARK: - Wine Environment

    /// Build the environment variables for Wine.
    private func wineEnvironment() -> [String: String] {
        let env: [String: String] = [
            "WINEDEBUG": "fixme-all,err-unwind,+timestamp",
            "WINEPREFIX": winePrefixDir.path
        ]
        return env
    }

    /// Convert a macOS path to a Wine Z: path.
    func toWinePath(_ absPath: String) -> String {
        "Z:" + absPath.replacingOccurrences(of: "/", with: "\\")
    }

    // MARK: - Registry

    /// Apply Wine driver properties (Retina mode, Left Command key).
    func setDriverProperties(retina: Bool, leftCmd: Bool) async throws {
        guard wineBinaryPath != nil else { throw WineError.binaryNotFound }

        let script = """
        @echo off
        cd "%~dp0"
        reg add "HKEY_CURRENT_USER\\Software\\Wine\\Mac Driver" /v RetinaMode /t REG_SZ /d \(retina ? "y" : "n") /f
        reg add "HKEY_CURRENT_USER\\Software\\Wine\\Mac Driver" /v LeftCommandIsCtrl /t REG_SZ /d \(leftCmd ? "y" : "n") /f
        """

        let scriptPath = FileSystemService.appSupportPath("winedrv_config.bat")
        try script.write(to: scriptPath, atomically: true, encoding: .utf8)
        try await cmd(toWinePath(scriptPath.path))
        try await waitForServer()
    }

    /// Apply NVIDIA extension registry entries.
    func setNVExtension() async throws {
        guard wineBinaryPath != nil else { throw WineError.binaryNotFound }

        let script = """
        @echo off
        cd "%~dp0"
        reg add "HKEY_LOCAL_MACHINE\\SOFTWARE\\NVIDIA Corporation\\Global" /v "{41FCC608-8496-4DEF-B43E-7D9BD675A6FF}" /t REG_BINARY /d 1 /f
        reg add "HKEY_LOCAL_MACHINE\\SYSTEM\\ControlSet001\\Services\\nvlddmkm" /v "{41FCC608-8496-4DEF-B43E-7D9BD675A6FF}" /t REG_BINARY /d 1 /f
        reg add "HKEY_LOCAL_MACHINE\\SOFTWARE\\NVIDIA Corporation\\Global\\NGXCore" /v FullPath /t REG_SZ /d "C:\\Windows\\System32" /f
        """

        let scriptPath = FileSystemService.appSupportPath("winedrv_config.bat")
        try script.write(to: scriptPath, atomically: true, encoding: .utf8)
        try await cmd(toWinePath(scriptPath.path))
        try await waitForServer()
    }

    /// Import a .reg file into Wine registry.
    func importRegistry(_ regContent: String) async throws {
        guard wineBinaryPath != nil else { throw WineError.binaryNotFound }

        let regPath = FileSystemService.appSupportPath("temp_registry.reg")
        try regContent.write(to: regPath, atomically: true, encoding: .utf8)
        try await run(program: "regedit", arguments: [toWinePath(regPath.path)])
    }

    /// Delete a registry key.
    func deleteRegistryKey(_ key: String) async throws {
        guard wineBinaryPath != nil else { throw WineError.binaryNotFound }

        try await run(program: "reg", arguments: [
            "delete", key, "/f"
        ], environment: wineEnvironment())
    }

    // MARK: - Server Lifecycle

    /// Wait for wineserver to shut down.
    func waitForServer() async throws {
        guard let wineBin = wineBinaryPath else { return }
        let wineserverPath = wineBin
            .deletingLastPathComponent() // bin/
            .appendingPathComponent("wineserver")

        if FileSystemService.fileExists(at: wineserverPath) {
            let env = wineEnvironment()
            _ = try? await ProcessService.exec(
                [.argument(wineserverPath.path), .argument("-w")],
                environment: env
            )
        }
    }

    // MARK: - Installation

    /// Install a Wine distribution from a URL.
    func installDistribution(_ distribution: WineDistribution, downloadService: DownloadService) async throws {
        let archiveURL = FileSystemService.appSupportPath("wine_archive.tar.xz")
        LogService.wineLog("Downloading Wine archive...")
        for try await _ in downloadService.download(from: distribution.remoteURL, to: archiveURL) {}
        LogService.wineLog("Extracting Wine...")
        try await installFromArchive(at: archiveURL, distribution: distribution)
        try? FileSystemService.removeItem(at: archiveURL)
    }

    /// Install a Wine distribution from a local archive file (skip download).
    func installDistribution(fromLocalArchive localURL: URL, distribution: WineDistribution) async throws {
        LogService.wineLog("Extracting Wine from local archive...")
        try await installFromArchive(at: localURL, distribution: distribution)
    }

    /// Core installation logic: extract, init prefix, configure.
    private func installFromArchive(at archiveURL: URL, distribution: WineDistribution) async throws {
        let installDir = wineInstallDir

        // Clean existing installation
        try? FileSystemService.removeItem(at: installDir)
        try FileSystemService.createDirectory(at: installDir)

        // Extract
        let winePath = distribution.winePath
        if winePath.isEmpty {
            try await FileSystemService.extractTarArchive(source: archiveURL, destination: installDir, isXZ: true)
        } else {
            try await FileSystemService.extractTarSubdirectory(
                source: archiveURL, destination: installDir, subdirectory: winePath, isXZ: true
            )
        }

        // Create prefix
        guard let wineBin = findWineBinary(in: installDir) else {
            throw WineError.binaryNotFound
        }
        wineBinaryPath = wineBin
        currentDistribution = distribution

        // Remove quarantine from Wine binaries — macOS otherwise blocks execution
        LogService.wineLog("Removing quarantine attributes...")
        try? await FileSystemService.removeQuarantine(at: installDir)

        // Suppress Mono/Gecko install prompts + headless mode
        let initEnv = wineEnvironment().merging([
            "WINEDLLOVERRIDES": "mscoree,mshtml=",
            "DISPLAY": ""
        ]) { $1 }

        // Run wineboot to initialize prefix
        LogService.wineLog("Running wineboot...")
        try await run(program: "wineboot", arguments: ["-i"], environment: initEnv)
        try await waitForServer()

        // Set Windows version to 10
        LogService.wineLog("Configuring Wine...")
        try await run(program: "winecfg", arguments: ["-v", "win10"], environment: initEnv)

        status = .installed(distribution: distribution)
        LogService.wineLog("Wine \(distribution.displayName) installed")
    }

    // MARK: - Certificate Management

    /// Add custom CA certificates to Wine.
    func addCertificates(_ certPEMs: [String]) async throws {
        guard let wineBin = wineBinaryPath else { throw WineError.binaryNotFound }
        let wineDir = wineBin.deletingLastPathComponent().deletingLastPathComponent() // wine/
        let infPath = wineDir.appendingPathComponent("share/wine/wine.inf")

        guard FileSystemService.fileExists(at: infPath) else { return }

        var infContent = try String(contentsOf: infPath, encoding: .utf8)

        // Find insertion point and add certs
        if let range = infContent.range(of: "; URL Associations") {
            let certSection = "\n" + certPEMs.joined(separator: "\n") + "\n"
            infContent.insert(contentsOf: certSection, at: range.lowerBound)
            try infContent.write(to: infPath, atomically: true, encoding: .utf8)
        }
    }

    // MARK: - DLL Injection

    /// Path to Wine's system32 directory inside the prefix.
    var system32Path: URL {
        winePrefixDir.appendingPathComponent("drive_c/windows/system32")
    }

    /// Copy DXMT/DXVK DLLs into Wine system32.
    /// These DLLs translate Direct3D calls to Metal for native GPU performance.
    func installDXMT(from dxmtDir: URL) async throws {
        let targetDir = system32Path
        try FileSystemService.createDirectory(at: targetDir)

        let dxmtDLLs = ["d3d9.dll", "d3d11.dll", "dxgi.dll"]
        for dll in dxmtDLLs {
            let source = dxmtDir.appendingPathComponent("dxmt").appendingPathComponent(dll)
            let dest = targetDir.appendingPathComponent(dll)
            if FileSystemService.fileExists(at: source) {
                if FileSystemService.fileExists(at: dest) {
                    try FileSystemService.removeItem(at: dest)
                }
                try FileSystemService.copyItem(from: source, to: dest)
            }
        }

        // Optionally copy libdxmt.dylib if present
        let libSource = dxmtDir.appendingPathComponent("dxmt/libdxmt.dylib")
        if FileSystemService.fileExists(at: libSource) {
            let libDest = targetDir.appendingPathComponent("libdxmt.dylib")
            if FileSystemService.fileExists(at: libDest) {
                try? FileSystemService.removeItem(at: libDest)
            }
            try? FileSystemService.copyItem(from: libSource, to: libDest)
        }

        LogService.wineLog("DXMT DLLs installed to system32")
    }

    /// Copy DXVK DLLs into Wine system32.
    func installDXVK(from dxvkDir: URL) async throws {
        let targetDir = system32Path
        try FileSystemService.createDirectory(at: targetDir)

        let dxvkDLLs = ["d3d9.dll", "d3d10core.dll", "d3d11.dll", "dxgi.dll"]
        for dll in dxvkDLLs {
            let source = dxvkDir.appendingPathComponent("x64").appendingPathComponent(dll)
            let dest = targetDir.appendingPathComponent(dll)
            if FileSystemService.fileExists(at: source) {
                if FileSystemService.fileExists(at: dest) {
                    try FileSystemService.removeItem(at: dest)
                }
                try FileSystemService.copyItem(from: source, to: dest)
            }
        }

        LogService.wineLog("DXVK DLLs installed to system32")
    }

    // MARK: - Media Foundation

    /// Install Windows Media Foundation components into Wine.
    /// Required by BH3 and CBJQ for cutscene/video playback.
    func installMediaFoundation() async throws {
        guard wineBinaryPath != nil else { throw WineError.binaryNotFound }

        // Use winetricks to install Media Foundation
        let winetricksPath = "/usr/local/bin/winetricks"
        let hasWinetricks = FileSystemService.fileExists(at: URL(fileURLWithPath: winetricksPath))

        if hasWinetricks {
            var env = wineEnvironment()
            env["WINEPREFIX"] = winePrefixDir.path

            try await ProcessService.exec([
                .argument(winetricksPath),
                .argument("--unattended"),
                .argument("mf")
            ], environment: env)
        } else {
            // Fallback: manual MF install via mf-install script
            try await installMFManually()
        }

        try await waitForServer()
        LogService.wineLog("Media Foundation installed")
    }

    /// Manual Media Foundation installation using mf-install or direct registry.
    private func installMFManually() async throws {
        let mfInstallScript = FileSystemService.resourcePath("mf-install.sh")
        if FileSystemService.fileExists(at: mfInstallScript) {
            var env = wineEnvironment()
            env["WINEPREFIX"] = winePrefixDir.path
            try await ProcessService.exec([
                .argument("/bin/bash"),
                .argument(mfInstallScript.path)
            ], environment: env)
        } else {
            LogService.wineLog("mf-install.sh not found — Media Foundation installation skipped")
        }
    }

    // MARK: - Environment Helpers

    /// Build DXMT-specific environment variables for game launch.
    func dxmtEnvironment(config: AppConfig) -> [String: String] {
        var env: [String: String] = [
            "WINEESYNC": "1",
            "DXMT_CONFIG": "dxmt.conf"
        ]
        if config.metalHudEnabled {
            env["MTL_HUD_ENABLED"] = "1"
        }
        if config.proxyEnabled, !config.proxyHost.isEmpty {
            env["HTTP_PROXY"] = config.proxyHost
            env["HTTPS_PROXY"] = config.proxyHost
        }
        // FPS unlock environment
        switch config.fpsUnlock {
        case .fps120: env["DXVK_FRAME_RATE"] = "120"
        case .fps144: env["DXVK_FRAME_RATE"] = "144"
        case .default: break
        }
        return env
    }

    // MARK: - FPS Unlock

    /// Apply FPS unlock via Unity registry override.
    func applyFPSUnlock(_ option: FPSUnlockOption) async throws {
        guard option != .default, let fpsValue = Int(option.rawValue) else { return }
        let regContent = """
        Windows Registry Editor Version 5.00
        [HKEY_CURRENT_USER\\Software\\Unity\\UnityEditor\\DefaultCompany\\]
        "TargetFrameRate"=dword:\(String(format: "%08x", fpsValue))
        """
        try await importRegistry(regContent)
    }

    // MARK: - ReShade

    /// Copy ReShade DLL to game directory as dxgi.dll.
    func installReshade(to gameDir: URL) async throws {
        let reshadeDir = FileSystemService.sidecarPath("reshade")
        var reshadeDLL = reshadeDir.appendingPathComponent("dxgi.dll")
        if !FileSystemService.fileExists(at: reshadeDLL) {
            reshadeDLL = reshadeDir.appendingPathComponent("ReShade64.dll")
        }
        guard FileSystemService.fileExists(at: reshadeDLL) else {
            LogService.gameLog("ReShade DLL not found")
            return
        }
        let dest = gameDir.appendingPathComponent("dxgi.dll")
        if FileSystemService.fileExists(at: dest) {
            let backup = gameDir.appendingPathComponent("dxgi.dll.bak")
            try? FileSystemService.copyItem(from: dest, to: backup)
        }
        try FileSystemService.copyItem(from: reshadeDLL, to: dest)
        LogService.gameLog("ReShade installed")
    }
}
