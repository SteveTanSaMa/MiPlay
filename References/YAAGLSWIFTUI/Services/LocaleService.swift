import Foundation
import Observation

/// Localization service.
/// Loads strings from Localizable.strings files.
/// Supports 10 languages matching YAAGL's locale system.
@Observable
final class LocaleService {

    // MARK: - Supported Languages

    struct Language: Identifiable, Equatable {
        let id: String
        let displayName: String
    }

    static let supportedLanguages: [Language] = [
        Language(id: "zh_cn", displayName: "简体中文"),
        Language(id: "en", displayName: "English"),
        Language(id: "ja_jp", displayName: "日本語"),
        Language(id: "ko_kr", displayName: "한국어"),
        Language(id: "vi_vn", displayName: "Tiếng Việt"),
        Language(id: "es_es", displayName: "Español"),
        Language(id: "fr_fr", displayName: "Français"),
        Language(id: "de_de", displayName: "Deutsch"),
        Language(id: "ru_ru", displayName: "Русский"),
        Language(id: "th_th", displayName: "ไทย"),
    ]

    // MARK: - State

    private(set) var currentLanguage: Language
    private var strings: [String: String] = [:]

    /// Content language for in-game audio/text.
    var contentLanguageID: String {
        switch currentLanguage.id {
        case "zh_cn": return "zh-cn"
        case "en": return "en-us"
        case "ja_jp": return "ja-jp"
        case "ko_kr": return "ko-kr"
        case "vi_vn": return "vi-vn"
        case "es_es": return "es-es"
        case "fr_fr": return "fr-fr"
        case "de_de": return "de-de"
        case "ru_ru": return "ru-ru"
        case "th_th": return "th-th"
        default: return "en-us"
        }
    }

    // MARK: - Initialization

    init(languageID: String = "") {
        let langID = Self.resolveLanguage(languageID)
        self.currentLanguage = Self.supportedLanguages.first { $0.id == langID } ?? Self.supportedLanguages[1]
        loadStrings(for: self.currentLanguage.id)
    }

    convenience init(configService: ConfigService) {
        let langID = configService.config.uiLocale
        self.init(languageID: langID)
    }

    // MARK: - Language Resolution

    private static func resolveLanguage(_ id: String) -> String {
        guard !id.isEmpty else {
            // Fall back to system language
            let lang = Locale.preferredLanguages.first ?? "en"
            let normalized = lang.replacingOccurrences(of: "-", with: "_").lowercased()
            if normalized.hasPrefix("zh") {
                return normalized.contains("hant") || normalized.contains("tw") ? "zh_cn" : "zh_cn"
            }
            if normalized.hasPrefix("en") { return "en" }
            if normalized.hasPrefix("ja") { return "ja_jp" }
            if normalized.hasPrefix("ko") { return "ko_kr" }
            if normalized.hasPrefix("vi") { return "vi_vn" }
            if normalized.hasPrefix("es") { return "es_es" }
            if normalized.hasPrefix("fr") { return "fr_fr" }
            if normalized.hasPrefix("de") { return "de_de" }
            if normalized.hasPrefix("ru") { return "ru_ru" }
            if normalized.hasPrefix("th") { return "th_th" }
            return "en"
        }

        let normalized = id.lowercased()
        if Self.supportedLanguages.contains(where: { $0.id == normalized }) {
            return normalized
        }
        return "en"
    }

    // MARK: - String Loading

    private func loadStrings(for languageID: String) {
        // Try loading from Main Bundle's localized strings
        let bundle = Bundle.main

        // Map our language IDs to .lproj directory names
        let lprojMap: [String: String] = [
            "zh_cn": "zh-Hans",
            "en": "en",
            "ja_jp": "ja",
            "ko_kr": "ko",
            "vi_vn": "vi",
            "es_es": "es",
            "fr_fr": "fr",
            "de_de": "de",
            "ru_ru": "ru",
            "th_th": "th",
        ]

        if let lprojName = lprojMap[languageID],
           let lprojPath = bundle.path(forResource: lprojName, ofType: "lproj"),
           let lprojBundle = Bundle(path: lprojPath) {
            let stringsPath = lprojBundle.path(forResource: "Localizable", ofType: "strings")
            if let path = stringsPath, let dict = NSDictionary(contentsOfFile: path) as? [String: String] {
                strings = dict
                return
            }
        }

        // Fall back to embedded defaults
        strings = Self.defaultStrings(for: languageID)
    }

    // MARK: - Public API

    /// Get a localized string by key.
    func get(_ key: String) -> String {
        strings[key] ?? key
    }

    /// Format a localized string with interpolated values.
    func format(_ key: String, _ args: CVarArg...) -> String {
        let template = get(key)
        return String(format: template, arguments: args)
    }

    /// Switch to a different language.
    func switchTo(languageID: String) {
        let langID = Self.resolveLanguage(languageID)
        guard let language = Self.supportedLanguages.first(where: { $0.id == langID }) else { return }
        currentLanguage = language
        loadStrings(for: langID)
    }

    // MARK: - Default Strings (minimal built-in set)

    private static func defaultStrings(for languageID: String) -> [String: String] {
        let isCN = languageID == "zh_cn"
        return [
            "LAUNCH": isCN ? "启动" : "Launch",
            "INSTALL": isCN ? "安装" : "Install",
            "UPDATE": isCN ? "更新" : "Update",
            "SETTINGS": isCN ? "设置" : "Settings",
            "GENERAL": isCN ? "通用" : "General",
            "GAME": isCN ? "游戏" : "Game",
            "WINE": isCN ? "Wine" : "Wine",
            "ADVANCED": isCN ? "高级" : "Advanced",
            "LICENSES": isCN ? "许可证" : "Licenses",
            "GAME_INSTALL_DIR": isCN ? "游戏安装目录" : "Game Install Directory",
            "METAL_HUD": isCN ? "Metal HUD" : "Metal HUD",
            "RETINA_MODE": isCN ? "Retina 模式" : "Retina Mode",
            "LEFT_CMD": isCN ? "Left Command 为 Ctrl" : "Left Command as Ctrl",
            "PROXY": isCN ? "代理" : "Proxy",
            "PROXY_HOST": isCN ? "代理地址" : "Proxy Host",
            "UI_LOCALE": isCN ? "界面语言" : "UI Language",
            "WINE_DISTRO": isCN ? "Wine 版本" : "Wine Distribution",
            "FPS_UNLOCK": isCN ? "帧率解锁" : "FPS Unlock",
            "RESHADE": isCN ? "ReShade" : "ReShade",
            "ENABLE_HDR": isCN ? "启用 HDR" : "Enable HDR",
            "CUSTOM_RESOLUTION": isCN ? "自定义分辨率" : "Custom Resolution",
            "RESOLUTION_WIDTH": isCN ? "宽度" : "Width",
            "RESOLUTION_HEIGHT": isCN ? "高度" : "Height",
            "PATCH_OFF": isCN ? "关闭补丁" : "Turn Off Patches",
            "STEAM_PATCH": isCN ? "Steam 补丁" : "Steam Patch",
            "BLOCK_NET": isCN ? "屏蔽网络" : "Block Network",
            "TIMEOUT_FIX": isCN ? "超时修复" : "Timeout Fix",
            "WORKAROUND_3": isCN ? "Workaround #3" : "Workaround #3",
            "CHECK_INTEGRITY": isCN ? "检查完整性" : "Check Integrity",
            "SELECT_INSTALLATION_DIR": isCN ? "选择安装目录" : "Select Installation Directory",
            "CANCEL": isCN ? "取消" : "Cancel",
            "CONFIRM": isCN ? "确认" : "Confirm",
            "DOWNLOADING": isCN ? "下载中..." : "Downloading...",
            "EXTRACTING": isCN ? "解压中..." : "Extracting...",
            "UPDATING": isCN ? "更新中..." : "Updating...",
            "DOWNLOAD_PROGRESS": isCN ? "%@ / %@" : "%@ / %@",
            "LAUNCHING": isCN ? "启动中..." : "Launching...",
            "INSTALLING": isCN ? "安装中..." : "Installing...",
            "PREDOWNLOAD_READY": isCN ? "预下载 %@ 可用" : "Pre-download %@ ready",
            "UPDATE_LAUNCHER": isCN ? "更新启动器" : "Update Launcher",
            "UPDATE_PROMPT_IGNORE": isCN ? "忽略此版本" : "Ignore this version",
            "SETTING_CANCEL": isCN ? "取消" : "Cancel",
            "LANGUAGE_LOCALE_NAME": isCN ? "简体中文" : "English",
            "VERSION": isCN ? "版本" : "Version",
            "GAME_CURRENT_VERSION": isCN ? "当前版本" : "Current Version",
            "GAME_LATEST_VERSION": isCN ? "最新版本" : "Latest Version",
            "INSTALL_SIZE": isCN ? "安装大小" : "Install Size",
            "FREE_SPACE": isCN ? "可用空间" : "Free Space",
            "YES": isCN ? "是" : "Yes",
            "NO": isCN ? "否" : "No",
            "OK": isCN ? "确定" : "OK",
            "ERROR": isCN ? "错误" : "Error",
            "SUCCESS": isCN ? "成功" : "Success",
            "CONTENT_LANG_ID": isCN ? "zh-cn" : "en-us",
        ]
    }
}
