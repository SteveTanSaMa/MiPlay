//
//  SettingsViewModel.swift
//  MiPlay
//
//  Created by Steve Tan on 2026/6/20.
//

import SwiftUI

@MainActor
@Observable
final class SettingsViewModel {
    let settingsStore: SettingsStore
    private let gameManager: GameManager
    private let wineManager: WineManager
    private let updateManager: UpdateManager

    var enableMetalHUD = false
    var enableRetinaMode = true
    var mapLeftControlToCommand = false
    var language: AppLanguage = .system

    // Global resolution
    var customResolutionWidth = ""
    var customResolutionHeight = ""
    var hostsBlockLaunch = false

    // Per-game resolution
    var usePerGameResolution = false
    var genshinResolutionWidth = ""
    var genshinResolutionHeight = ""
    var starRailResolutionWidth = ""
    var starRailResolutionHeight = ""
    var zenlessResolutionWidth = ""
    var zenlessResolutionHeight = ""

    var selectedWineVersion = ""
    var availableWineVersions: [WineConfig] = []
    var remoteWineVersions: [WineVersion] = []
    var isLoadingWineVersions = false
    var wineInstallProgress: Double?
    var installingVersionID: String?

    var appVersion = ""
    var isCheckingUpdate = false
    var updateAvailable = false

    // Game paths (cached for SettingsView display)
    var genshinInstallPath: String? = nil
    var genshinScreenshotPath: String? = nil
    var starRailInstallPath: String? = nil
    var starRailScreenshotPath: String? = nil
    var zzzInstallPath: String? = nil
    var zzzScreenshotPath: String? = nil

    init(settingsStore: SettingsStore, gameManager: GameManager, wineManager: WineManager, updateManager: UpdateManager) {
        self.settingsStore = settingsStore
        self.gameManager = gameManager
        self.wineManager = wineManager
        self.updateManager = updateManager
        Task {
            await loadSettings()
        }
    }

    func loadSettings() async {
        let settings = await settingsStore.settings
        enableMetalHUD = settings.enableMetalHUD
        enableRetinaMode = settings.enableRetinaMode
        mapLeftControlToCommand = settings.mapLeftControlToCommand
        language = settings.language

        if let width = settings.customResolutionWidth {
            customResolutionWidth = "\(width)"
        }
        if let height = settings.customResolutionHeight {
            customResolutionHeight = "\(height)"
        }
        hostsBlockLaunch = settings.hostsBlockLaunch

        // Per-game resolution
        usePerGameResolution = settings.usePerGameResolution
        if let config = settings.perGameResolution[.genshinImpact] {
            genshinResolutionWidth = "\(config.width)"
            genshinResolutionHeight = "\(config.height)"
        } else {
            genshinResolutionWidth = ""
            genshinResolutionHeight = ""
        }
        if let config = settings.perGameResolution[.starRail] {
            starRailResolutionWidth = "\(config.width)"
            starRailResolutionHeight = "\(config.height)"
        } else {
            starRailResolutionWidth = ""
            starRailResolutionHeight = ""
        }
        if let config = settings.perGameResolution[.zenlessZoneZero] {
            zenlessResolutionWidth = "\(config.width)"
            zenlessResolutionHeight = "\(config.height)"
        } else {
            zenlessResolutionWidth = ""
            zenlessResolutionHeight = ""
        }

        selectedWineVersion = settings.selectedWineVersion
        availableWineVersions = await wineManager.installedVersions
        appVersion = Bundle.main.fullVersionString
        await loadRemoteWineVersions()
        await loadGamePaths()
    }

    func loadGamePaths() async {
        genshinInstallPath = await gameManager.gameInstallPath(for: .genshinImpact)
        genshinScreenshotPath = await gameManager.screenshotDirectory(for: .genshinImpact)
        starRailInstallPath = await gameManager.gameInstallPath(for: .starRail)
        starRailScreenshotPath = await gameManager.screenshotDirectory(for: .starRail)
        zzzInstallPath = await gameManager.gameInstallPath(for: .zenlessZoneZero)
        zzzScreenshotPath = await gameManager.screenshotDirectory(for: .zenlessZoneZero)
    }

    func saveSettings() async {
        var settings = await settingsStore.settings
        settings.enableMetalHUD = enableMetalHUD
        settings.enableRetinaMode = enableRetinaMode
        settings.mapLeftControlToCommand = mapLeftControlToCommand
        settings.language = language
        settings.customResolutionWidth = Int(customResolutionWidth)
        settings.customResolutionHeight = Int(customResolutionHeight)
        settings.hostsBlockLaunch = hostsBlockLaunch
        settings.selectedWineVersion = selectedWineVersion

        // Per-game resolution
        settings.usePerGameResolution = usePerGameResolution
        if usePerGameResolution {
            if let width = Int(genshinResolutionWidth), let height = Int(genshinResolutionHeight) {
                settings.perGameResolution[.genshinImpact] = ResolutionConfig(width: width, height: height)
            }
            if let width = Int(starRailResolutionWidth), let height = Int(starRailResolutionHeight) {
                settings.perGameResolution[.starRail] = ResolutionConfig(width: width, height: height)
            }
            if let width = Int(zenlessResolutionWidth), let height = Int(zenlessResolutionHeight) {
                settings.perGameResolution[.zenlessZoneZero] = ResolutionConfig(width: width, height: height)
            }
        } else {
            settings.perGameResolution = [:]
        }

        await settingsStore.updateSettings(settings)
        try? await settingsStore.saveSettings()
    }

    func loadRemoteWineVersions() async {
        guard !isLoadingWineVersions else { return }
        isLoadingWineVersions = true
        do {
            remoteWineVersions = try await wineManager.fetchRemoteVersions()
        } catch {
            Logger.shared.error("获取 Wine 版本列表失败: \(error.localizedDescription)")
        }
        isLoadingWineVersions = false
    }

    func installWineVersion(_ version: WineVersion) async {
        installingVersionID = version.id
        wineInstallProgress = 0

        do {
            // 使用 @Sendable 闭包避免 actor 隔离问题
            try await wineManager.installWine(version: version) { @Sendable progress in
                Task { @MainActor in
                    self.wineInstallProgress = progress
                }
            }

            // 安装完成后刷新列表
            availableWineVersions = await wineManager.installedVersions

            // 第一次安装时自动设为选中版本
            if selectedWineVersion.isEmpty {
                selectedWineVersion = version.version
                var settings = await settingsStore.settings
                settings.selectedWineVersion = version.version
                await settingsStore.updateSettings(settings)
                try? await settingsStore.saveSettings()
            }

            // 确保 default prefix 存在并用当前 Wine 版本初始化
            if let installedConfig = availableWineVersions.first(where: { $0.version == version.version }) {
                let prefixPath = wineManager.prefixPath(for: "default")
                let prefixExists = FileManager.default.fileExists(atPath: prefixPath.path)

                if !prefixExists {
                    Logger.shared.info("创建 default Wine Prefix...")
                    do {
                        let prefix = WinePrefix.defaultPrefix()
                        try await wineManager.createPrefix(config: installedConfig, prefix: prefix)
                        Logger.shared.info("default Wine Prefix 创建成功（使用 \(version.version)）")
                    } catch {
                        Logger.shared.error("创建 default Wine Prefix 失败: \(error.localizedDescription)")
                    }
                } else {
                    // Prefix 已存在，用新版本的 Wine 重新初始化（wineboot -u）
                    Logger.shared.info("更新 default Wine Prefix 到 \(version.version)...")
                    do {
                        try await wineManager.reinitializePrefix(
                            config: installedConfig,
                            prefixName: "default"
                        )
                        Logger.shared.info("default Wine Prefix 更新完成")
                    } catch {
                        Logger.shared.error("更新 Wine Prefix 失败: \(error.localizedDescription)")
                    }
                }
            }
        } catch {
            Logger.shared.error("安装 Wine \(version.version) 失败: \(error.localizedDescription)")
        }
        wineInstallProgress = nil
        installingVersionID = nil
    }

    func removeWineVersion(_ version: String) async {
        do {
            try await wineManager.removeWine(version: version)
            availableWineVersions = await wineManager.installedVersions

            // 如果删除的是当前选中的版本，清空选中状态并持久化
            if selectedWineVersion == version {
                selectedWineVersion = ""
                var settings = await settingsStore.settings
                settings.selectedWineVersion = ""
                await settingsStore.updateSettings(settings)
                try? await settingsStore.saveSettings()
            }
        } catch {
            Logger.shared.error("删除 Wine \(version) 失败: \(error.localizedDescription)")
        }
    }

    func checkForUpdates() async {
        isCheckingUpdate = true
        do {
            let update = try await updateManager.checkForUpdates()
            updateAvailable = update.isNewerThanCurrent(Bundle.main.appVersion)
        } catch {
            Logger.shared.error("检查更新失败: \(error.localizedDescription)")
        }
        isCheckingUpdate = false
    }

    func reinitializeWine() async {
        guard !selectedWineVersion.isEmpty else { return }
        guard let config = availableWineVersions.first(where: { $0.version == selectedWineVersion }) else { return }
        do {
            try await wineManager.reinitializePrefix(config: config, prefixName: "default")
            Logger.shared.info("Wine Prefix 重新初始化完成")
        } catch {
            Logger.shared.error("Wine Prefix 重新初始化失败: \(error.localizedDescription)")
        }
    }

    func openLauncherFolder() {
        let urls = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        guard let dir = urls.first?.appendingPathComponent("MiPlay") else { return }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: dir.path)
    }

    func openGameFolder(for gameType: GameType) {
        Task {
            let path = await gameManager.gameInstallPath(for: gameType)
            guard let path = path else { return }
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
        }
    }

    func openScreenshotFolder(for gameType: GameType) {
        Task {
            let path = await gameManager.screenshotDirectory(for: gameType)
            guard let path = path else { return }
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
        }
    }

    func gameInstallPath(for gameType: GameType) -> String? {
        switch gameType {
        case .genshinImpact: return genshinInstallPath
        case .starRail: return starRailInstallPath
        case .zenlessZoneZero: return zzzInstallPath
        }
    }

    func screenshotDirectory(for gameType: GameType) -> String? {
        switch gameType {
        case .genshinImpact: return genshinScreenshotPath
        case .starRail: return starRailScreenshotPath
        case .zenlessZoneZero: return zzzScreenshotPath
        }
    }

    func openWineShell() {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-a", "Terminal"]
        try? process.run()
    }

    func toAppSettings() async -> AppSettings {
        var settings = await settingsStore.settings
        settings.enableMetalHUD = enableMetalHUD
        settings.enableRetinaMode = enableRetinaMode
        settings.mapLeftControlToCommand = mapLeftControlToCommand
        settings.language = language
        settings.customResolutionWidth = Int(customResolutionWidth)
        settings.customResolutionHeight = Int(customResolutionHeight)
        settings.hostsBlockLaunch = hostsBlockLaunch
        settings.selectedWineVersion = selectedWineVersion
        settings.usePerGameResolution = usePerGameResolution
        if usePerGameResolution {
            if let width = Int(genshinResolutionWidth), let height = Int(genshinResolutionHeight) {
                settings.perGameResolution[.genshinImpact] = ResolutionConfig(width: width, height: height)
            }
            if let width = Int(starRailResolutionWidth), let height = Int(starRailResolutionHeight) {
                settings.perGameResolution[.starRail] = ResolutionConfig(width: width, height: height)
            }
            if let width = Int(zenlessResolutionWidth), let height = Int(zenlessResolutionHeight) {
                settings.perGameResolution[.zenlessZoneZero] = ResolutionConfig(width: width, height: height)
            }
        }
        return settings
    }
}
