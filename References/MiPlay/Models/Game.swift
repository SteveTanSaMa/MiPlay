//
//  Game.swift
//  MiPlay
//
//  Created by Steve Tan on 2026/6/20.
//

import Foundation

enum GameType: String, Codable, CaseIterable, Identifiable {
    case genshinImpact = "GenshinImpact"
    case starRail = "StarRail"
    case zenlessZoneZero = "ZenlessZoneZero"

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .genshinImpact: return "原神"
        case .starRail: return "崩坏：星穹铁道"
        case .zenlessZoneZero: return "绝区零"
        }
    }

    var englishName: String {
        switch self {
        case .genshinImpact: return "Genshin Impact"
        case .starRail: return "Honkai: Star Rail"
        case .zenlessZoneZero: return "Zenless Zone Zero"
        }
    }

    var bundleName: String {
        switch self {
        case .genshinImpact: return "GenshinImpact"
        case .starRail: return "StarRail"
        case .zenlessZoneZero: return "ZZZ"
        }
    }
}

enum GameInstallStatus: String, Codable {
    case notInstalled
    case downloading
    case installed
    case needsUpdate
    case broken
}

struct Game: Codable, Identifiable {
    var id: String { type.rawValue }
    let type: GameType
    var installPath: String?
    var installStatus: GameInstallStatus = .notInstalled
    var version: String?
    var lastPlayed: Date?
    var launchArguments: [String] = []
    var customDXMTConfig: DXMTConfiguration?

    static func empty(for type: GameType) -> Game {
        Game(type: type)
    }
}

struct DXMTConfiguration: Codable {
    var enableMetalHUD: Bool = false
    var enableRetinaMode: Bool = true
    var resolutionWidth: Int?
    var resolutionHeight: Int?
    var customConfigPath: String?
}
