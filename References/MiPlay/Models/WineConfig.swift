//
//  WineConfig.swift
//  MiPlay
//
//  Created by Steve Tan on 2026/6/20.
//

import Foundation

struct WineConfig: Codable, Identifiable {
    var id: String { version }

    var version: String
    var name: String
    var localPath: String
    var dxmtVersion: String?
    var isDefault: Bool = false

    static let defaultConfig = WineConfig(
        version: "8.26",
        name: "anime-game-wine",
        localPath: "",
        dxmtVersion: nil,
        isDefault: true
    )
}

struct WinePrefix: Codable, Identifiable {
    var id: String { name }

    var name: String
    var path: String
    var arch: WineArch = .win64
    var windowsVersion: WineWindowsVersion = .win11
    var environmentVariables: [String: String] = [:]
    var overrides: [String: String] = [:]

    static func defaultPrefix(name: String = "default") -> WinePrefix {
        WinePrefix(name: name, path: "", arch: .win64, windowsVersion: .win11)
    }
}

enum WineArch: String, Codable, CaseIterable {
    case win32 = "win32"
    case win64 = "win64"

    var displayName: String {
        switch self {
        case .win32: return "32-bit"
        case .win64: return "64-bit"
        }
    }
}

enum WineWindowsVersion: String, Codable, CaseIterable {
    case win7 = "win7"
    case win10 = "win10"
    case win11 = "win11"

    var displayName: String {
        switch self {
        case .win7: return "Windows 7"
        case .win10: return "Windows 10"
        case .win11: return "Windows 11"
        }
    }
}
