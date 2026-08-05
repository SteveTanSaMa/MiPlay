//
//  GenshinImpact.swift
//  MiPlay
//
//  Created by Steve Tan on 2026/6/20.
//

import Foundation

struct GenshinImpact {
    static let type = GameType.genshinImpact
    static let executableName = "GenshinImpact.exe"
    static let gameDataDir = "Genshin Impact Game"
    static let launcherExecutable = "launcher.exe"

    static let defaultLaunchArguments: [String] = [
        "-screen-width", "1920",
        "-screen-height", "1080"
    ]

    static func launchArguments(resolution: CGSize? = nil) -> [String] {
        guard let resolution = resolution else { return defaultLaunchArguments }
        return [
            "-screen-width", "\(Int(resolution.width))",
            "-screen-height", "\(Int(resolution.height))"
        ]
    }
}
