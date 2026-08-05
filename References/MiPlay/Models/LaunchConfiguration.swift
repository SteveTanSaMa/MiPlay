//
//  LaunchConfiguration.swift
//  MiPlay
//
//  Created by Steve Tan on 2026/6/20.
//

import Foundation

struct LaunchConfiguration: Codable {
    var game: GameType
    var wineVersion: String
    var winePrefix: String
    var gameDir: String                    // 游戏安装目录（用户指定）
    var dxmtEnabled: Bool = true
    var environmentVariables: [String: String] = [:]
    var launchArguments: [String] = []
    var workingDirectory: String?
    var useRetinaMode: Bool = true
    var resolution: CGSize?
    var enableMetalHUD: Bool = false
    var enableShaderCache: Bool = true
    var enableTimeoutFix: Bool = true
    var proxyEnabled: Bool = false
    var proxyHost: String?

    // DXMT 配置
    var dxmtLogLevel: DXMTLogLevel = .error
    var dxmtCaptureEnabled: Bool = false
    var dxmtShaderCachePath: String?

    static func `default`(for game: GameType, gameDir: String) -> LaunchConfiguration {
        LaunchConfiguration(
            game: game,
            wineVersion: "8.26",
            winePrefix: "default",
            gameDir: gameDir,
            dxmtLogLevel: .error
        )
    }
}

enum DXMTLogLevel: String, Codable, CaseIterable {
    case none = "none"
    case error = "error"
    case warn = "warn"
    case info = "info"
    case debug = "debug"

    var displayName: String {
        switch self {
        case .none: return "无"
        case .error: return "错误"
        case .warn: return "警告"
        case .info: return "信息"
        case .debug: return "调试"
        }
    }
}
