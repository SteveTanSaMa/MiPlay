//
//  LaunchService.swift
//  MiPlay
//
//  Created by Steve Tan on 2026/6/20.
//

import Foundation
import CoreGraphics

actor LaunchService {
    private let gameManager: GameManager
    private let wineManager: WineManager
    private let gameLauncher: GameLauncher
    private let launchValidator: LaunchValidator

    init(gameManager: GameManager, wineManager: WineManager) {
        self.gameManager = gameManager
        self.wineManager = wineManager
        self.gameLauncher = GameLauncher(gameManager: gameManager)
        self.launchValidator = LaunchValidator(gameManager: gameManager, wineManager: wineManager)
    }

    func launch(
        gameType: GameType,
        configuration: LaunchConfiguration? = nil,
        settings: AppSettings
    ) async throws {
        _ = try await launchValidator.validate(gameType: gameType)

        let installedVersions = await wineManager.installedVersions
        guard let wineConfig = installedVersions.first(where: { $0.version == settings.selectedWineVersion })
                ?? installedVersions.first else {
            throw GameLauncher.LaunchError.wineNotConfigured
        }

        // 获取游戏安装目录
        guard let gameDir = await gameManager.gameInstallPath(for: gameType) else {
            throw GameLauncher.LaunchError.gameNotInstalled
        }

        let config = configuration ?? buildConfiguration(for: gameType, gameDir: gameDir, settings: settings)

        // 确保 Wine Prefix 存在，如不存在则自动创建
        let prefixPath = wineManager.prefixPath(for: config.winePrefix)
        if !FileManager.default.fileExists(atPath: prefixPath.path) {
            Logger.shared.info("Wine Prefix '\(config.winePrefix)' 不存在，正在自动创建...")
            let prefix = WinePrefix.defaultPrefix(name: config.winePrefix)
            try await wineManager.createPrefix(config: wineConfig, prefix: prefix)
            Logger.shared.info("Wine Prefix '\(config.winePrefix)' 创建成功")
        }

        // 应用注册表优化
        try await applyRegistryOptimizations(wineConfig: wineConfig, config: config, settings: settings)

        // 启动游戏
        try await gameLauncher.launchGame(
            type: gameType,
            configuration: config,
            wineConfig: wineConfig,
            prefixPath: prefixPath.path
        )
    }

    // MARK: - 注册表优化

    private func applyRegistryOptimizations(
        wineConfig: WineConfig,
        config: LaunchConfiguration,
        settings: AppSettings
    ) async throws {
        let prefixPath = wineManager.prefixPath(for: config.winePrefix)

        // Retina 模式
        let retinaValue = settings.enableRetinaMode ? "y" : "n"
        _ = try? runWineRegistry(
            wineConfig: wineConfig,
            prefixPath: prefixPath,
            args: ["set", "HKEY_CURRENT_USER\\Software\\Wine\\Mac Driver", "RetinaMode", retinaValue]
        )

        // 左 Control 映射为 Command
        let leftCmdValue = settings.mapLeftControlToCommand ? "y" : "n"
        _ = try? runWineRegistry(
            wineConfig: wineConfig,
            prefixPath: prefixPath,
            args: ["set", "HKEY_CURRENT_USER\\Software\\Wine\\Mac Driver", "LeftCommandIsCtrl", leftCmdValue]
        )

        // 全局分辨率
        if let width = settings.customResolutionWidth, let height = settings.customResolutionHeight {
            _ = try? runWineRegistry(
                wineConfig: wineConfig,
                prefixPath: prefixPath,
                args: ["set", "HKEY_CURRENT_USER\\Software\\Wine\\Mac Driver", "Resolution", "\(width)x\(height)"]
            )
        }

        // 游戏内分辨率（写入游戏注册表）
        try await applyInGameResolution(wineConfig: wineConfig, prefixPath: prefixPath, gameType: config.game, settings: settings)
    }

    /// 写入游戏分辨率到注册表（原神/星铁/绝区零各自的分辨率键）
    private func applyInGameResolution(
        wineConfig: WineConfig,
        prefixPath: URL,
        gameType: GameType,
        settings: AppSettings
    ) async throws {
        // 根据 settings 获取该游戏的分辨率
        let width: Int?
        let height: Int?

        if settings.usePerGameResolution {
            switch gameType {
            case .genshinImpact:
                width = Int(settings.perGameResolution[.genshinImpact]?.width ?? 0)
                height = Int(settings.perGameResolution[.genshinImpact]?.height ?? 0)
            case .starRail:
                width = Int(settings.perGameResolution[.starRail]?.width ?? 0)
                height = Int(settings.perGameResolution[.starRail]?.height ?? 0)
            case .zenlessZoneZero:
                width = Int(settings.perGameResolution[.zenlessZoneZero]?.width ?? 0)
                height = Int(settings.perGameResolution[.zenlessZoneZero]?.height ?? 0)
            }
        } else {
            width = settings.customResolutionWidth
            height = settings.customResolutionHeight
        }

        guard let w = width, let h = height, w > 0, h > 0 else { return }

        // 写入 Unity 游戏分辨率注册表项
        // 参考 yaagl: miHoYo 原神注册表路径
        let gameRegPath = gameRegistryKey(for: gameType)
        if let regPath = gameRegPath {
            let regContent = """
            Windows Registry Editor Version 5.00

            [\(regPath)]
            "Screenmanager Is Fullscreen mode_h3981298716"=dword:00000000
            "Screenmanager Resolution Width_h182942802"=dword:\(String(format: "%08x", w))
            "Screenmanager Resolution Height_h2627697771"=dword:\(String(format: "%08x", h))
            """

            // 写入临时 reg 文件并导入
            let regFile = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(gameType.rawValue)_resolution.reg")
            try regContent.write(to: regFile, atomically: true, encoding: .utf16LittleEndian)

            defer { try? FileManager.default.removeItem(at: regFile) }

            _ = try? runWineRegistry(
                wineConfig: wineConfig,
                prefixPath: prefixPath,
                args: [regFile.path]
            )
        }
    }

    private func gameRegistryKey(for gameType: GameType) -> String? {
        let base = "HKEY_CURRENT_USER\\Software\\miHoYo"
        switch gameType {
        case .genshinImpact:
            return "\(base)\\Genshin Impact"
        case .starRail:
            return "\(base)\\Star Rail"
        case .zenlessZoneZero:
            return "\(base)\\ZenlessZoneZero"
        }
    }

    // MARK: - Wine 注册表工具

    private func runWineRegistry(wineConfig: WineConfig, prefixPath: URL, args: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "\(wineConfig.localPath)/bin/wine64")
        process.arguments = ["reg", "add"] + args + ["/f"]
        var env = ProcessInfo.processInfo.environment
        env["WINEPREFIX"] = prefixPath.path
        env["WINEARCH"] = "win64"
        process.environment = env
        try process.run()
        process.waitUntilExit()
    }

    // MARK: - 配置构建

    private func buildConfiguration(
        for gameType: GameType,
        gameDir: String,
        settings: AppSettings
    ) -> LaunchConfiguration {
        var config = LaunchConfiguration.default(for: gameType, gameDir: gameDir)
        config.wineVersion = settings.selectedWineVersion.isEmpty ? "8.26" : settings.selectedWineVersion
        config.winePrefix = settings.selectedWinePrefix
        config.enableMetalHUD = settings.enableMetalHUD
        config.useRetinaMode = settings.enableRetinaMode
        config.enableTimeoutFix = true

        if let width = settings.customResolutionWidth, let height = settings.customResolutionHeight {
            config.resolution = CGSize(width: width, height: height)
        }

        return config
    }
}
