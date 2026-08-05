//
//  StarRail.swift
//  MiPlay
//
//  Created by Steve Tan on 2026/6/20.
//

import Foundation

struct StarRail {
    static let type = GameType.starRail
    static let executableName = "StarRail.exe"
    static let gameDataDir = "StarRail_Data"
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
