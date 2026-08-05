import Foundation

/// All user-configurable settings for the launcher.
/// Persisted via `ConfigService` using `UserDefaults` + `Codable`.
struct AppConfig: Codable, Equatable {
    // MARK: - General
    var gameInstallDir: String = ""
    var metalHudEnabled: Bool = false
    var retinaMode: Bool = false
    var leftCommandIsCtrl: Bool = false
    var proxyEnabled: Bool = false
    var proxyHost: String = "127.0.0.1:8080"
    var uiLocale: String = ""

    // MARK: - HK4E (Genshin Impact) Specific
    var hk4eEnableHDR: Bool = false
    var hk4eWorkaround3Enabled: Bool = false
    var hk4ePatchOff: Bool = false
    var hk4eSteamPatch: Bool = false
    var hk4eBlockNet: Bool = false
    var hk4eResolutionCustom: Bool = false
    var hk4eResolutionWidth: String = "1920"
    var hk4eResolutionHeight: String = "1200"
    var hk4eTimeoutFix: Bool = false

    // MARK: - HSR/ZZZ/BH3 Specific
    var patchOff: Bool = false
    var blockNet: Bool = false
    var steamPatch: Bool = false
    var timeoutFix: Bool = false
    var resolutionCustom: Bool = false
    var resolutionWidth: String = "1920"
    var resolutionHeight: String = "1200"

    // MARK: - Wine
    var wineTag: String = "11.0-dxmt-signed-with-patches"
    var wineState: String = ""
    var wineUpdateTag: String = ""
    var wineNetbiosName: String = ""

    // MARK: - Advanced
    var fpsUnlock: FPSUnlockOption = .default
    var reshadeEnabled: Bool = false

    // MARK: - Launcher
    var ignoreLauncherUpdate: Bool = false
    var lastLauncherUpdateCheck: Date?

    // MARK: - Per-game install directories (fall back to gameInstallDir)
    var installDirHK4ECN: String = ""
    var installDirHK4EGlobal: String = ""
    var installDirHKRPGCN: String = ""
    var installDirHKRPGGlobal: String = ""
    var installDirNAPCN: String = ""
    var installDirNAPGlobal: String = ""
    var installDirBH3Global: String = ""
    var installDirCBJQCN: String = ""
    var installDirCBJQGlobal: String = ""

    static let `default` = AppConfig()
}

// MARK: - Helpers

extension AppConfig {
    /// Returns the effective install directory for a given game.
    func installDir(for game: Game) -> String {
        switch game {
        case .hk4eCN:         return coalesce(installDirHK4ECN, gameInstallDir)
        case .hk4eGlobal:     return coalesce(installDirHK4EGlobal, gameInstallDir)
        case .hkrpgCN:        return coalesce(installDirHKRPGCN, gameInstallDir)
        case .hkrpgGlobal:    return coalesce(installDirHKRPGGlobal, gameInstallDir)
        case .napCN:          return coalesce(installDirNAPCN, gameInstallDir)
        case .napGlobal:      return coalesce(installDirNAPGlobal, gameInstallDir)
        case .bh3Global:      return coalesce(installDirBH3Global, gameInstallDir)
        case .cbjqCN:         return coalesce(installDirCBJQCN, gameInstallDir)
        case .cbjqGlobal:     return coalesce(installDirCBJQGlobal, gameInstallDir)
        }
    }

    mutating func setInstallDir(_ dir: String, for game: Game) {
        switch game {
        case .hk4eCN:         installDirHK4ECN = dir
        case .hk4eGlobal:     installDirHK4EGlobal = dir
        case .hkrpgCN:        installDirHKRPGCN = dir
        case .hkrpgGlobal:    installDirHKRPGGlobal = dir
        case .napCN:          installDirNAPCN = dir
        case .napGlobal:      installDirNAPGlobal = dir
        case .bh3Global:      installDirBH3Global = dir
        case .cbjqCN:         installDirCBJQCN = dir
        case .cbjqGlobal:     installDirCBJQGlobal = dir
        }
    }

    private func coalesce(_ specific: String, _ general: String) -> String {
        specific.isEmpty ? general : specific
    }
}
