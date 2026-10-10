import Foundation

/// YAAGL's per-game preparation, kept outside the renderer and game files.
enum GameLaunchPreparation {
    nonisolated static func webviewRegistryKeys(for gameType: GameType) -> [String] {
        switch gameType {
        case .genshinImpact: return []
        case .zenlessZoneZero:
            return ["HKCU\\Software\\miHoYo\\绝区零", "HKCU\\Software\\miHoYo\\ZenlessZoneZero"]
        case .honkaiStarRail:
            return ["HKCU\\Software\\miHoYo\\崩坏：星穹铁道", "HKCU\\Software\\Cognosphere\\Star Rail"]
        }
    }

    nonisolated static func webviewValues(in registryOutput: String) -> [String] {
        registryOutput.split(whereSeparator: \.isNewline).compactMap { line in
            guard let name = line.split(whereSeparator: \.isWhitespace).first.map(String.init),
                  name == "MIHOYOSDK_WEBVIEW_RENDER_METHOD_h1573598267" || name.hasPrefix("HOYO_WEBVIEW_RENDER_METHOD_ABTEST_") else { return nil }
            return name
        }
    }

    nonisolated static func fixWebview(gameType: GameType, wineBinary: String, prefix: String, processManager: ProcessManager) async throws {
        let environment = ["WINEPREFIX": prefix, "WINEDLLOVERRIDES": "winemenubuilder.exe=d", "WINEDEBUG": "fixme-all,err-unwind"]
        for key in webviewRegistryKeys(for: gameType) {
            try Task.checkCancellation()
            let output: String
            do {
                output = try await processManager.launchAndWait(executablePath: wineBinary, arguments: ["reg", "query", key], environment: environment, timeout: 15)
            } catch ProcessManager.ProcessError.exitWithError(let code, let signal, _) where code == 1 && signal == nil {
                // A new prefix does not contain the game's registry key yet.
                continue
            }
            for value in webviewValues(in: output) {
                _ = try await processManager.launchAndWait(executablePath: wineBinary, arguments: ["reg", "delete", key, "/v", value, "/f"], environment: environment, timeout: 15)
            }
        }
    }

    /// Star Rail can inspect NGX before creating its DXGI factory. Mirror
    /// YAAGL's early registration rather than relying on DXMT's later setup.
    nonisolated static func prepareStarRailVendorRegistry(wineBinary: String, prefix: String, processManager: ProcessManager) async throws {
        let identifier = "{41FCC608-8496-4DEF-B43E-7D9BD675A6FF}"
        let operations = [
            ["reg", "add", "HKLM\\SOFTWARE\\NVIDIA Corporation\\Global", "/v", identifier, "/t", "REG_BINARY", "/d", "01", "/f"],
            ["reg", "add", "HKLM\\SYSTEM\\ControlSet001\\Services\\nvlddmkm", "/v", identifier, "/t", "REG_BINARY", "/d", "01", "/f"],
            ["reg", "add", "HKLM\\SOFTWARE\\NVIDIA Corporation\\Global\\NGXCore", "/v", "FullPath", "/t", "REG_SZ", "/d", "C:\\Windows\\System32", "/f"],
        ]
        for arguments in operations {
            try Task.checkCancellation()
            _ = try await processManager.launchAndWait(executablePath: wineBinary, arguments: arguments, environment: ["WINEPREFIX": prefix, "WINEDLLOVERRIDES": "winemenubuilder.exe=d"], timeout: 15)
        }
    }

    nonisolated static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    /// Fixed 15-second window matching YAAGL. A separate root subprocess owns
    /// cleanup, so closing MiPlay or a failed game spawn cannot cancel the timer.
    /// Tag each individual line; never remove someone else's hosts entries.
    nonisolated static func networkWindowScript(hostsPath: String = "/etc/hosts", token: String, duration: Double = 15) -> String {
        let marker = "MiPlay-HSR-" + token
        return """
        set -e
        hosts=\(shellQuote(hostsPath))
        cleanup() {
          /usr/bin/sed -i '' '/ # \(marker)$/d' "$hosts"
        }
        trap cleanup EXIT HUP INT TERM
        printf '\\n0.0.0.0 globaldp-prod-cn01.bhsr.com # \(marker)\\n0.0.0.0 globaldp-prod-os01.starrails.com # \(marker)\\n' >> "$hosts"
        (
          trap cleanup EXIT HUP INT TERM
          /bin/sleep \(duration)
        ) </dev/null >/dev/null 2>&1 &
        trap - EXIT HUP INT TERM
        """
    }

    nonisolated static func networkAuthorizationScript(token: String) -> String {
        let script = networkWindowScript(token: token)
        let command = "/bin/sh -c " + shellQuote(script)
        return "do shell script \"" + command.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"").replacingOccurrences(of: "\n", with: "\\n") + "\" with administrator privileges with prompt \"崩铁启动兼容需要短暂屏蔽两个连接域名，15 秒后自动恢复。\""
    }

    nonisolated static func beginStarRailNetworkWindow(processManager: ProcessManager) async throws {
        _ = try await processManager.launchAndWait(executablePath: "/usr/bin/osascript", arguments: ["-e", networkAuthorizationScript(token: UUID().uuidString)], timeout: 120)
    }
}
