import Foundation

/// Supported game server definitions.
/// Mirrors the server definitions from YAAGL's `constants/server.ts` and client files.
enum Game: String, CaseIterable, Codable, Identifiable {
    // MARK: - Genshin Impact
    case hk4eCN = "hk4e_cn"
    case hk4eGlobal = "hk4e_global"

    // MARK: - Honkai Star Rail
    case hkrpgCN = "hkrpg_cn"
    case hkrpgGlobal = "hkrpg_global"

    // MARK: - Zenless Zone Zero
    case napCN = "nap_cn"
    case napGlobal = "nap_os"

    // MARK: - Honkai Impact 3rd
    case bh3Global = "BH3_GLB"

    // MARK: - Snowbreak
    case cbjqCN = "CBJQCN"
    case cbjqGlobal = "CBJQ"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .hk4eCN, .hk4eGlobal:          return "Genshin Impact"
        case .hkrpgCN, .hkrpgGlobal:        return "Honkai: Star Rail"
        case .napCN, .napGlobal:            return "Zenless Zone Zero"
        case .bh3Global:                     return "Honkai Impact 3rd"
        case .cbjqCN, .cbjqGlobal:          return "Snowbreak: Containment Zone"
        }
    }

    var regionSuffix: String {
        switch self {
        case .hk4eCN, .hkrpgCN, .napCN, .cbjqCN: return " (CN)"
        case .hk4eGlobal, .hkrpgGlobal, .napGlobal, .bh3Global, .cbjqGlobal: return " (Global)"
        }
    }

    var fullDisplayName: String { displayName + regionSuffix }

    var server: GameServer {
        switch self {
        case .hk4eCN:         return .hk4eCN
        case .hk4eGlobal:     return .hk4eGlobal
        case .hkrpgCN:        return .hkrpgCN
        case .hkrpgGlobal:    return .hkrpgGlobal
        case .napCN:          return .napCN
        case .napGlobal:      return .napGlobal
        case .bh3Global:      return .bh3Global
        case .cbjqCN:         return .cbjqCN
        case .cbjqGlobal:     return .cbjqGlobal
        }
    }

    /// Game's official website URL.
    var websiteURL: URL? {
        switch self {
        case .hk4eCN:          return URL(string: "https://ys.mihoyo.com/")
        case .hk4eGlobal:      return URL(string: "https://genshin.hoyoverse.com/")
        case .hkrpgCN:         return URL(string: "https://sr.mihoyo.com/")
        case .hkrpgGlobal:     return URL(string: "https://hsr.hoyoverse.com/")
        case .napCN:           return URL(string: "https://zzz.mihoyo.com/")
        case .napGlobal:       return URL(string: "https://zenless.hoyoverse.com/")
        case .bh3Global:       return URL(string: "https://honkaiimpact3.hoyoverse.com/")
        case .cbjqCN:          return nil
        case .cbjqGlobal:      return nil
        }
    }

    /// Button position on the launcher screen.
    var launchButtonSide: LaunchButtonSide {
        switch self {
        case .napCN, .napGlobal, .bh3Global, .cbjqCN, .cbjqGlobal: return .left
        default: return .right
        }
    }
}

/// Button position on the launcher.
enum LaunchButtonSide: Equatable {
    case left
    case right
}

/// Server connection configuration — mirrors YAAGL's `Server` type.
struct GameServer: Equatable, Codable {
    let id: String
    let biz: String
    let updateURL: String
    let advURL: String
    let cps: String
    let channelID: Int
    let subchannelID: Int
    let productName: String
    let executable: String
    let dataDir: String
    let companyName: String
    let blockURL: String?
    let hostsEntries: [String: String]

    /// Sophon-compatible games use the Sophon protocol for install/update.
    var usesSophon: Bool {
        switch id {
        case "hk4e_cn", "hk4e_global": return true
        default: return false
        }
    }

    /// Game update mechanism type.
    var updateMechanism: UpdateMechanism {
        if usesSophon { return .sophon }
        switch id {
        case "hkrpg_cn", "hkrpg_global", "nap_cn", "nap_os", "BH3_GLB":
            return .hoyoverseDirect
        case "CBJQCN", "CBJQ":
            return .seasunManifest
        default:
            return .hoyoverseDirect
        }
    }
}

enum UpdateMechanism: Equatable {
    case sophon
    case hoyoverseDirect    /// 7z segmented download + hpatchz
    case seasunManifest     /// Pak-based manifest download
}

// MARK: - Server Definitions

extension GameServer {
    static let hk4eCN = GameServer(
        id: "hk4e_cn",
        biz: "hk4e_cn",
        updateURL: "https://hyp-api.mihoyo.com/hyp/hyp-connect/api/getGamePackages?launcher_id=jGHBHlcOq1",
        advURL: "https://hyp-api.mihoyo.com/hyp/hyp-connect/api/getAllGameBasicInfo?launcher_id=jGHBHlcOq1",
        cps: "pcadbdpz",
        channelID: 1,
        subchannelID: 1,
        productName: "原神",
        executable: "YuanShen.exe",
        dataDir: "YuanShen_Data",
        companyName: "miHoYo",
        blockURL: "dispatchcnglobal.yuanshen.com",
        hostsEntries: ["dispatchcnglobal.yuanshen.com": "0.0.0.0"]
    )

    static let hk4eGlobal = GameServer(
        id: "hk4e_global",
        biz: "hk4e_global",
        updateURL: "https://sg-hyp-api.hoyoverse.com/hyp/hyp-connect/api/getGamePackages?launcher_id=VYTpXlbWo8",
        advURL: "https://sg-hyp-api.hoyoverse.com/hyp/hyp-connect/api/getAllGameBasicInfo?launcher_id=VYTpXlbWo8",
        cps: "mihoyo",
        channelID: 1,
        subchannelID: 1,
        productName: "Genshin Impact",
        executable: "GenshinImpact.exe",
        dataDir: "GenshinImpact_Data",
        companyName: "miHoYo",
        blockURL: "dispatchosglobal.yuanshen.com",
        hostsEntries: ["dispatchosglobal.yuanshen.com": "0.0.0.0"]
    )

    static let hkrpgCN = GameServer(
        id: "hkrpg_cn",
        biz: "hkrpg_cn",
        updateURL: "https://hyp-api.mihoyo.com/hyp/hyp-connect/api/getGamePackages?launcher_id=jGHBHlcOq1",
        advURL: "https://hyp-api.mihoyo.com/hyp/hyp-connect/api/getAllGameBasicInfo?launcher_id=jGHBHlcOq1",
        cps: "gw_PC",
        channelID: 1,
        subchannelID: 1,
        productName: "StarRail",
        executable: "StarRail.exe",
        dataDir: "StarRail_Data",
        companyName: "miHoYo",
        blockURL: "globaldp-prod-cn01.bhsr.com",
        hostsEntries: ["globaldp-prod-cn01.bhsr.com": "0.0.0.0"]
    )

    static let hkrpgGlobal = GameServer(
        id: "hkrpg_global",
        biz: "hkrpg_global",
        updateURL: "https://sg-hyp-api.hoyoverse.com/hyp/hyp-connect/api/getGamePackages?launcher_id=VYTpXlbWo8",
        advURL: "https://sg-hyp-api.hoyoverse.com/hyp/hyp-connect/api/getAllGameBasicInfo?launcher_id=VYTpXlbWo8",
        cps: "hoyoverse_PC",
        channelID: 1,
        subchannelID: 1,
        productName: "StarRail",
        executable: "StarRail.exe",
        dataDir: "StarRail_Data",
        companyName: "miHoYo",
        blockURL: "globaldp-prod-os01.starrails.com",
        hostsEntries: ["globaldp-prod-os01.starrails.com": "0.0.0.0"]
    )

    static let napCN = GameServer(
        id: "nap_cn",
        biz: "nap_cn",
        updateURL: "https://hyp-api.mihoyo.com/hyp/hyp-connect/api/getGamePackages?launcher_id=jGHBHlcOq1",
        advURL: "https://hyp-api.mihoyo.com/hyp/hyp-connect/api/getAllGameBasicInfo?launcher_id=jGHBHlcOq1",
        cps: "mihoyo",
        channelID: 1,
        subchannelID: 1,
        productName: "ZenlessZoneZero",
        executable: "ZenlessZoneZero.exe",
        dataDir: "ZenlessZoneZero_Data",
        companyName: "miHoYo",
        blockURL: "globaldp-prod-cn02.juequling.com",
        hostsEntries: ["globaldp-prod-cn02.juequling.com": "0.0.0.0"]
    )

    static let napGlobal = GameServer(
        id: "nap_os",
        biz: "nap_os",
        updateURL: "https://sg-hyp-api.hoyoverse.com/hyp/hyp-connect/api/getGamePackages?launcher_id=VYTpXlbWo8",
        advURL: "https://sg-hyp-api.hoyoverse.com/hyp/hyp-connect/api/getAllGameBasicInfo?launcher_id=VYTpXlbWo8",
        cps: "mihoyo",
        channelID: 1,
        subchannelID: 1,
        productName: "ZenlessZoneZero",
        executable: "ZenlessZoneZero.exe",
        dataDir: "ZenlessZoneZero_Data",
        companyName: "miHoYo",
        blockURL: "globaldp-prod-os01.zenlesszonezero.com",
        hostsEntries: ["globaldp-prod-os01.zenlesszonezero.com": "0.0.0.0"]
    )

    static let bh3Global = GameServer(
        id: "BH3_GLB",
        biz: "BH3_GLB",
        updateURL: "https://bh3-launcher.hoyoverse.com/bh3_global/mdk/launcher/api/resource?launcher_id=10&key=dpz65xJ3",
        advURL: "https://bh3-launcher.hoyoverse.com/bh3_global/mdk/launcher/api/content?filter_adv=true&launcher_id=10&key=dpz65xJ3",
        cps: "",
        channelID: 1,
        subchannelID: 0,
        productName: "BH3",
        executable: "BH3.exe",
        dataDir: "BH3_Data",
        companyName: "miHoYo",
        blockURL: nil,
        hostsEntries: [:]
    )

    static let cbjqCN = GameServer(
        id: "CBJQCN",
        biz: "CBJQCN",
        updateURL: "https://cbjq.xoyocdn.com/DLC7/PC/updates/manifest.json",
        advURL: "",
        cps: "jinshan",
        channelID: 0,
        subchannelID: 0,
        productName: "Snowbreak",
        executable: "Game/Binaries/Win64/Game.exe",
        dataDir: "",
        companyName: "Seasun",
        blockURL: nil,
        hostsEntries: [:]
    )

    static let cbjqGlobal = GameServer(
        id: "CBJQ",
        biz: "CBJQ",
        updateURL: "https://snowbreak-dl.amazingseasuncdn.com/DLC7/PC/updates/manifest.json",
        advURL: "",
        cps: "seasun",
        channelID: 0,
        subchannelID: 0,
        productName: "Snowbreak",
        executable: "Game/Binaries/Win64/Game.exe",
        dataDir: "",
        companyName: "Seasun",
        blockURL: nil,
        hostsEntries: [:]
    )
}

// MARK: - Game State

/// Installation state for a game.
enum GameInstallState: Equatable {
    case notInstalled
    case installed(version: String)
    case installing(progress: Double)
    case updating(progress: Double)
    case launching

    var isInstalled: Bool {
        if case .installed = self { return true }
        return false
    }
}

/// Content language options for in-game audio/text.
enum ContentLanguage: String, CaseIterable, Codable, Identifiable {
    case enUS = "en-us"
    case ruRU = "ru-ru"
    case esES = "es-es"
    case deDE = "de-de"
    case frFR = "fr-fr"
    case idID = "id-id"
    case jaJP = "ja-jp"
    case koKR = "ko-kr"
    case zhCN = "zh-cn"
    case zhTW = "zh-tw"
    case viVN = "vi-vn"
    case thTH = "th-th"

    var id: String { rawValue }
    var displayName: String { rawValue }
}

/// FPS unlock options.
enum FPSUnlockOption: String, Codable, CaseIterable, Identifiable {
    case `default` = "default"
    case fps120 = "120"
    case fps144 = "144"

    var id: String { rawValue }
    var displayValue: String {
        switch self {
        case .default: return "Default"
        case .fps120: return "120 FPS"
        case .fps144: return "144 FPS"
        }
    }
}
