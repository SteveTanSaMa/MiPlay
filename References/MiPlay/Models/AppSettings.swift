//
//  AppSettings.swift
//  MiPlay
//
//  Created by Steve Tan on 2026/6/20.
//

import Foundation

struct AppSettings: Codable {
    // General
    var enableMetalHUD: Bool = false
    var enableRetinaMode: Bool = true
    var mapLeftControlToCommand: Bool = false
    var language: AppLanguage = .system

    // Game - Global
    var customResolutionWidth: Int?
    var customResolutionHeight: Int?
    var hostsBlockLaunch: Bool = false

    // Game - Per-Game
    var usePerGameResolution: Bool = false
    var perGameResolution: [GameType: ResolutionConfig] = [:]

    // Wine
    var selectedWineVersion: String = ""
    var selectedWinePrefix: String = "default"

    // Background
    var useCustomBackground: Bool = false
    var customBackgroundPath: String = ""
    var backgroundFillMode: BackgroundFillMode = .fill
    var perGameBackgroundMode: [GameType: BackgroundMode] = [:]
    var perGameCustomBackgroundPath: [GameType: String] = [:]

    // App
    var appVersion: String = ""
    var lastUpdateCheck: Date?

    static let `default` = AppSettings()
}

struct ResolutionConfig: Codable, Equatable {
    var width: Int
    var height: Int

    static let defaultHD = ResolutionConfig(width: 1920, height: 1080)
}

enum AppLanguage: String, Codable, CaseIterable {
    case system = "system"
    case zhCN = "zh-CN"
    case enUS = "en-US"

    var displayName: String {
        switch self {
        case .system: return "跟随系统"
        case .zhCN: return "简体中文"
        case .enUS: return "English"
        }
    }
}

enum BackgroundMode: String, Codable, CaseIterable {
    case defaultStatic = "defaultStatic"
    case defaultDynamic = "defaultDynamic"
    case customImage = "customImage"

    var displayName: String {
        switch self {
        case .defaultStatic: return "默认（静态）"
        case .defaultDynamic: return "默认（动态）"
        case .customImage: return "自定义图片"
        }
    }
}
