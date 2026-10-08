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
            "Genshin Impact Game/YuanShen.exe",
            "YuanShen.exe",
            "GenshinImpact.exe",
        ]
        case .honkaiStarRail: return ["StarRail.exe"]
        case .zenlessZoneZero: return [
            "ZenlessZoneZero Game/ZenlessZoneZero.exe",
            "ZenlessZoneZero.exe",
        ]
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

    /// 在指定安装目录中查找第一个存在的可执行文件路径。
    /// 支持用户选择直接游戏目录或包含游戏子目录的安装根目录。
    /// - Parameter installPath: 游戏安装目录
    /// - Returns: 找到的第一个可执行文件完整路径，均不存在则返回 nil
    nonisolated internal func firstExistingExecutable(at installPath: String) -> String? {
        let baseURL = URL(fileURLWithPath: installPath)
        for relativePath in executableRelativePaths {
            let fullPath = baseURL.appendingPathComponent(relativePath).path
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: fullPath, isDirectory: &isDirectory),
               !isDirectory.boolValue {
                return fullPath
            }
        }
        let expectedNames = Set(executableNames.map { $0.lowercased() })
        guard FileManager.default.fileExists(atPath: baseURL.path) else { return nil }
        guard let enumerator = FileManager.default.enumerator(
            at: baseURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isDirectoryKey],
            options: [.skipsHiddenFiles, .skipsPackageDescendants]
        ) else { return nil }
        let baseDepth = baseURL.pathComponents.count
        for case let candidate as URL in enumerator {
            let depth = candidate.pathComponents.count - baseDepth
            if depth > 3 {
                enumerator.skipDescendants()
                continue
            }
            let values = try? candidate.resourceValues(forKeys: [.isRegularFileKey])
            if values?.isRegularFile == true,
               candidate.pathExtension.caseInsensitiveCompare("exe") == .orderedSame,
               expectedNames.contains(candidate.lastPathComponent.lowercased()) {
                return candidate.path
            }
        }
        return nil
    }

    /// Normalizes either a selected executable or an installation root to the
    /// directory that directly contains the game executable.
    nonisolated internal func resolvedInstallationDirectory(at url: URL) -> URL? {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory) else {
            return nil
        }
        let baseURL = isDirectory.boolValue ? url : url.deletingLastPathComponent()
        guard let executablePath = firstExistingExecutable(at: baseURL.path) else {
            return nil
        }
        return URL(fileURLWithPath: executablePath, isDirectory: false)
            .deletingLastPathComponent()
            .standardizedFileURL
    }

    /// 最小磁盘空间要求（字节）- 估算值
    nonisolated public var minimumDiskSpaceRequired: UInt64 {
        switch self {
        case .genshinImpact: return 150 * 1024 * 1024 * 1024 // 150GB
        case .honkaiStarRail: return 100 * 1024 * 1024 * 1024 // 100GB
        case .zenlessZoneZero: return 120 * 1024 * 1024 * 1024 // 120GB
        }
    }

    /// Launching an already-installed game does not require the free space
    /// needed to download or patch the game itself. This smaller guard covers
    /// Wine prefix growth, shader caches, logs and normal launcher writes.
    nonisolated public var launchDiskSpaceRequired: UInt64 {
        4 * 1024 * 1024 * 1024
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
    case fpsUnlock = "FpsUnlock"
    case metalFXUpscale = "MetalFXUpscale"

    public var displayName: String {
        switch self {
        case .metalHUD: return "Metal HUD"
        case .fpsUnlock: return "解锁帧率"
        case .metalFXUpscale: return "MetalFX 空间缩放"
        }
    }

    public var description: String {
        switch self {
        case .metalHUD: return "在画面上显示帧率（纯 FPS、最小缩放）"
        case .fpsUnlock: return "解除帧率上限（等待解锁工具接入后生效）"
        case .metalFXUpscale: return "以较低分辨率渲染并由 MetalFX 放大"
        }
    }
}
