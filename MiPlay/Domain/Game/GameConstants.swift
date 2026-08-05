//
//  GameConstants.swift
//  MiPlay
//
//  Created by Steve Tan on 2026/7/7.
//

import Foundation

// Source: Architecture Design → Domain Model → Game
// Source: Product Definition → Feature List → Must: 游戏发现与添加

/// 游戏类型标识。米哈游指定三款游戏。
public enum GameType: String, Codable, CaseIterable, Sendable {
    case genshinImpact = "GenshinImpact"
    case honkaiStarRail = "HonkaiStarRail"
    case zenlessZoneZero = "ZenlessZoneZero"

    nonisolated public var displayName: String {
        switch self {
        case .genshinImpact: return "原神"
        case .honkaiStarRail: return "崩坏：星穹铁道"
        case .zenlessZoneZero: return "绝区零"
        }
    }

    nonisolated public var englishName: String {
        switch self {
        case .genshinImpact: return "Genshin Impact"
        case .honkaiStarRail: return "Honkai: Star Rail"
        case .zenlessZoneZero: return "Zenless Zone Zero"
        }
    }

    /// 官方下载页面 URL
    public var officialDownloadURL: URL? {
        switch self {
        case .genshinImpact:
            return URL(string: "https://sg-hk4e-api.hoyoverse.com/common/download")
        case .honkaiStarRail:
            return URL(string: "https://sg-hkrpg-api.hoyoverse.com/common/download")
        case .zenlessZoneZero:
            return URL(string: "https://sg-nap-api.hoyoverse.com/common/download")
        }
    }

    /// 游戏可执行文件名称（在安装目录中）。支持国际服/国服双命名。
    nonisolated public var executableNames: [String] {
        switch self {
        case .genshinImpact: return ["GenshinImpact.exe", "YuanShen.exe"]
        case .honkaiStarRail: return ["StarRail.exe"]
        case .zenlessZoneZero: return ["ZenlessZoneZero.exe"]
        }
    }

    /// 游戏在安装目录中的可识别子路径（多个候选项）。Genshin 国际服在子目录中。
    nonisolated public var executableRelativePaths: [String] {
        switch self {
        case .genshinImpact: return [
            "Genshin Impact Game/GenshinImpact.exe",
            "YuanShen.exe",
        ]
        case .honkaiStarRail: return ["StarRail.exe"]
        case .zenlessZoneZero: return ["ZenlessZoneZero.exe"]
        }
    }

    /// 游戏版本文件相对路径
    nonisolated public var versionFileRelativePath: String {
        switch self {
        case .genshinImpact: return "config.ini"
        case .honkaiStarRail: return "config.ini"
        case .zenlessZoneZero: return "config.ini"
        }
    }

    /// 在指定安装目录中查找第一个存在的可执行文件路径
    /// - Parameter installPath: 游戏安装目录
    /// - Returns: 找到的第一个可执行文件完整路径，均不存在则返回 nil
    internal func firstExistingExecutable(at installPath: String) -> String? {
        let baseURL = URL(fileURLWithPath: installPath)
        for relativePath in executableRelativePaths {
            let fullPath = baseURL.appendingPathComponent(relativePath).path
            if FileManager.default.fileExists(atPath: fullPath) {
                return fullPath
            }
        }
        return nil
    }

    /// 最小磁盘空间要求（字节）- 估算值
    nonisolated public var minimumDiskSpaceRequired: UInt64 {
        switch self {
        case .genshinImpact: return 150 * 1024 * 1024 * 1024 // 150GB
        case .honkaiStarRail: return 100 * 1024 * 1024 * 1024 // 100GB
        case .zenlessZoneZero: return 120 * 1024 * 1024 * 1024 // 120GB
        }
    }
}

/// 游戏业务状态。遵循 Product/UX 定义的状态转换图。
public enum GameBusinessState: String, Codable, Sendable, CaseIterable {
    case notInstalled = "NotInstalled"
    case installed = "Installed"
    case updateAvailable = "UpdateAvailable"
    case gameUpdating = "GameUpdating"
    case launching = "Launching"
    case running = "Running"
    case launchFailed = "LaunchFailed"

    public var isUserActionable: Bool {
        switch self {
        case .notInstalled, .installed, .updateAvailable, .launchFailed:
            return true
        case .gameUpdating, .launching, .running:
            return false
        }
    }

    public var isTransitionState: Bool {
        switch self {
        case .gameUpdating, .launching:
            return true
        default:
            return false
        }
    }
}

/// 兼容方案状态
public enum SolutionApplicationState: String, Codable, Sendable {
    case applying = "Applying"
    case applied = "Applied"
    case failed = "Failed"
    case rolledBack = "RolledBack"
}

/// 兼容方案风险等级
public enum SolutionRiskLevel: String, Codable, Sendable, CaseIterable {
    case low = "Low"
    case medium = "Medium"
    case high = "High"

    public var displayName: String {
        switch self {
        case .low: return "低风险"
        case .medium: return "中风险"
        case .high: return "高风险"
        }
    }
}

/// 性能选项类型
public enum PerformanceOptionType: String, Codable, Sendable, CaseIterable {
    case metalHUD = "MetalHUD"
    case retinaMode = "RetinaMode"
    case gameResolution = "GameResolution"
    case fpsUnlock = "FpsUnlock"

    public var displayName: String {
        switch self {
        case .metalHUD: return "Metal HUD"
        case .retinaMode: return "Retina 模式"
        case .gameResolution: return "游戏运行分辨率"
        case .fpsUnlock: return "帧率解锁"
        }
    }

    public var description: String {
        switch self {
        case .metalHUD: return "显示 Metal 性能 HUD（FPS 和 GPU 信息）"
        case .retinaMode: return "启用 Retina 分辨率渲染"
        case .gameResolution: return "设置游戏运行时的屏幕分辨率"
        case .fpsUnlock: return "解除游戏帧率上限（需游戏支持）"
        }
    }
}
