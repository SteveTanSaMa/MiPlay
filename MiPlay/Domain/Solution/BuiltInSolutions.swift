//
//  BuiltInSolutions.swift
//  MiPlay
//
//  Created by Steve Tan on 2026/7/7.
//

import Foundation

// Source: Architecture Design → Domain Model → CompatibilitySolution
// Source: Product Definition → Feature List → Must: 内置兼容方案应用

/// 内置兼容方案定义。
/// 方案来源于社区经验，随程序版本内置发布，不依赖外部信息源。
public struct BuiltInSolutions {
    /// Solutions visible in the current release manifest. Historical definitions
    /// remain below for migration/read-only diagnostics and are never applicative.
    nonisolated public static func publishedSolutions() -> [CompatibilitySolution] {
        // No signed system-modification helper is registered in this target.
        // Do not advertise actions that would only fail after confirmation.
        []
    }

    /// 获取所有内置兼容方案
    nonisolated public static func allSolutions() -> [CompatibilitySolution] {
        return [
            // 反作弊相关
            replaceOldAntiCheat,
            // Hostname 相关
            modifyHostname,
            // 网络相关
            blockNetworkForAntiCheat,
            // Steam 白名单
            steamWhitelist,
            // 旧版补丁
            useLegacyPatch,
        ]
    }

    /// 获取适用于特定游戏的兼容方案
    nonisolated public static func solutions(for gameType: GameType) -> [CompatibilitySolution] {
        return publishedSolutions().filter { $0.applicableGames.contains(gameType) }
    }

    // MARK: - Solution Definitions

    /// 替换旧版反作弊
    nonisolated static let replaceOldAntiCheat = CompatibilitySolution(
        id: "replace_old_anticheat",
        name: "替换旧版反作弊",
        description: "将当前反作弊程序替换为已知可兼容的旧版本，解决反作弊与 macOS Wine 环境的冲突问题。",
        riskLevel: .medium,
        applicableGames: [.genshinImpact, .honkaiStarRail, .zenlessZoneZero],
        details: "此操作会将游戏的反作弊程序（mhyprot2.sys等）替换为兼容性更好的旧版本。替换后反作弊功能正常运行，但可能无法检测最新的作弊手段。如游戏版本更新恢复反作弊文件，需重新应用此方案。"
    )

    /// 修改 Hostname
    nonisolated static let modifyHostname = CompatibilitySolution(
        id: "modify_hostname",
        name: "修改 Hostname",
        description: "将系统 Hostname 修改为兼容格式，解决部分游戏反作弊对特殊 Hostname 字符的兼容问题。",
        riskLevel: .low,
        applicableGames: [.genshinImpact, .honkaiStarRail, .zenlessZoneZero],
        details: "部分米哈游游戏反作弊程序对包含中文字符或特殊字符的 Hostname 存在兼容问题。将此修改为纯英文格式可解决此问题。此修改对其他应用无影响。"
    )

    /// 屏蔽反作弊网络连接
    nonisolated static let blockNetworkForAntiCheat = CompatibilitySolution(
        id: "block_network_anticheat",
        name: "屏蔽反作弊网络直连",
        description: "通过 hosts 文件屏蔽反作弊程序的特定网络连接，解决反作弊超时导致的启动失败。",
        riskLevel: .low,
        applicableGames: [.genshinImpact, .honkaiStarRail, .zenlessZoneZero],
        details: "部分反作弊程序在特定网络环境下会出现连接超时导致启动被阻断。通过屏蔽特定域名可跳过此检测环节。游戏正常运行不需要反作弊的网络连接。"
    )

    /// Steam 白名单启动
    nonisolated static let steamWhitelist = CompatibilitySolution(
        id: "steam_whitelist",
        name: "Steam 白名单启动",
        description: "通过 Steam 的 Proton 兼容层白名单机制绕过反作弊的环境检测。",
        riskLevel: .low,
        applicableGames: [.genshinImpact],
        details: "将游戏添加到 Steam 白名单后启动，利用 Steam Proton 的环境兼容处理机制绕过反作弊对非 Windows 环境的检测。需要系统安装 Steam。"
    )

    /// 使用旧版补丁
    nonisolated static let useLegacyPatch = CompatibilitySolution(
        id: "use_legacy_patch",
        name: "使用旧版兼容补丁",
        description: "应用已知可用的旧版兼容补丁，解决游戏更新后新补丁不兼容的问题。",
        riskLevel: .high,
        applicableGames: [.zenlessZoneZero],
        details: "此操作会替换游戏的部分动态链接库（DLL）文件为旧版已知兼容的版本。风险较高，因为文件替换可能触发反作弊的文件完整性检测。如应用后出现问题，请及时回滚。"
    )
}

/// 兼容方案模型
public struct CompatibilitySolution: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let name: String
    public let description: String
    public let riskLevel: SolutionRiskLevel
    public let applicableGames: [GameType]
    public let details: String

    nonisolated public init(
        id: String,
        name: String,
        description: String,
        riskLevel: SolutionRiskLevel,
        applicableGames: [GameType],
        details: String
    ) {
        self.id = id
        self.name = name
        self.description = description
        self.riskLevel = riskLevel
        self.applicableGames = applicableGames
        self.details = details
    }

    nonisolated public static func == (lhs: CompatibilitySolution, rhs: CompatibilitySolution) -> Bool {
        lhs.id == rhs.id
    }
}
