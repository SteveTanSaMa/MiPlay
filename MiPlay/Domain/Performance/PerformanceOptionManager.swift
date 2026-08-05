//
//  PerformanceOptionManager.swift
//  MiPlay
//
//  Created by Steve Tan on 2026/7/7.
//

import Foundation

// Source: Architecture Design → Service Contract → PerformanceOptionManager
// Source: Product Definition → Feature List → Should: 性能辅助选项

/// 性能选项定义
public struct PerformanceOption: Codable, Sendable, Identifiable, Equatable {
    public let id: String
    public let type: PerformanceOptionType
    public let displayName: String
    public let optionDescription: String
    public let applicableGames: [GameType]
    public var isEnabled: Bool
    public var value: String? // 额外参数值（如分辨率）
    /// 启动时需传递的命令行参数
    public let launchArguments: [String]?
    /// 启动时需设置的环境变量
    public let environmentVariables: [String: String]?

    public init(
        id: String,
        type: PerformanceOptionType,
        displayName: String,
        optionDescription: String,
        applicableGames: [GameType],
        isEnabled: Bool = false,
        value: String? = nil,
        launchArguments: [String]? = nil,
        environmentVariables: [String: String]? = nil
    ) {
        self.id = id
        self.type = type
        self.displayName = displayName
        self.optionDescription = optionDescription
        self.applicableGames = applicableGames
        self.isEnabled = isEnabled
        self.value = value
        self.launchArguments = launchArguments
        self.environmentVariables = environmentVariables
    }

    public static func == (lhs: PerformanceOption, rhs: PerformanceOption) -> Bool {
        lhs.id == rhs.id
    }
}

/// 性能选项管理器。管理性能辅助选项的定义、查询、启用/禁用。
@Observable
public final class PerformanceOptionManager {
    public enum OptionError: Error, LocalizedError {
        case optionNotApplicable(gameId: String, optionId: String)
        case optionNotFound(String)
        case deferred(String)
        case persistenceFailed(String)

        public var errorDescription: String? {
            switch self {
            case .optionNotApplicable(let gameId, let optionId):
                return "选项 \(optionId) 不适用于游戏 \(gameId)"
            case .optionNotFound(let id):
                return "选项未找到: \(id)"
            case .deferred(let id):
                return "高级配置当前延期实现: \(id)"
            case .persistenceFailed(let detail):
                return "持久化失败: \(detail)"
            }
        }
    }

    private let persistenceStore: PersistenceStore
    private let logWriter: LogWriter

    /// 所有游戏-选项映射表的持久化缓存
    private var gameOptions: [String: [PerformanceOption]] = [:]

    public init(
        persistenceStore: PersistenceStore,
        logWriter: LogWriter
    ) {
        self.persistenceStore = persistenceStore
        self.logWriter = logWriter
    }

    // MARK: - Initialization

    /// 加载已保存的性能选项状态（从 AppData）
    public func loadOptions() async {
        do {
            let appData = try await persistenceStore.readAppData()
            let saved = appData.performanceOptions
            if !saved.isEmpty {
                // Convert DTOs to PerformanceOptions
                for (gameId, dtos) in saved {
                    var options = builtInOptions(for: gameId)
                    for dto in dtos {
                        if let index = options.firstIndex(where: { $0.id == dto.id }) {
                            options[index].isEnabled = dto.isEnabled
                            if let value = dto.value {
                                options[index].value = value
                            }
                        }
                    }
                    gameOptions[gameId] = options
                }
            }
        } catch {
            await logWriter.warning("加载性能选项失败: \(error.localizedDescription)", module: "PerformanceOptionManager")
        }

        // 初始化默认选项
        initializeDefaultOptions()
    }

    // MARK: - Query

    /// 获取指定游戏可用的性能选项
    public func getOptions(for gameId: String) -> [PerformanceOption] {
        // A-01..A-06 are read-only Deferred capabilities in this release.
        return []
    }

    /// 获取指定游戏的某个选项
    public func getOption(gameId: String, optionId: String) -> PerformanceOption? {
        return getOptions(for: gameId).first { $0.id == optionId }
    }

    /// 获取所有有选项的游戏 ID
    public func getAllGameIds() -> [String] {
        return Array(gameOptions.keys)
    }

    /// 获取启动时需要应用的选项
    public func getOptionsForLaunch(gameId: String) -> [PerformanceOption] {
        return getOptions(for: gameId).filter { $0.isEnabled }
    }

    // MARK: - Enable/Disable

    /// 启用/禁用性能选项
    public func setOption(gameId: String, optionId: String, enabled: Bool) async throws {
        throw OptionError.deferred(optionId)
    }

    /// 设置选项值（如分辨率）
    public func setOptionValue(gameId: String, optionId: String, value: String) async throws {
        throw OptionError.deferred(optionId)
    }

    // MARK: - Private

    /// 持久化选项到 AppData
    private func persistOptions() async throws {
        var dtoMap: [String: [PerformanceOptionDTO]] = [:]
        for (gameId, options) in gameOptions {
            dtoMap[gameId] = options.map { option in
                PerformanceOptionDTO(id: option.id, isEnabled: option.isEnabled, value: option.value)
            }
        }
        var appData = try await persistenceStore.readAppData()
        appData.performanceOptions = dtoMap
        try await persistenceStore.writeAppData(appData)
    }

    /// 为指定游戏获取内置选项
    private func builtInOptions(for gameId: String) -> [PerformanceOption] {
        guard let gameType = GameType(rawValue: gameId) else { return [] }

        return PerformanceOptionManager.defaultOptions.filter { $0.applicableGames.contains(gameType) }
    }

    /// 初始化默认选项
    private func initializeDefaultOptions() {
        for gameType in GameType.allCases {
            if gameOptions[gameType.rawValue] == nil {
                gameOptions[gameType.rawValue] = builtInOptions(for: gameType.rawValue)
            }
        }
    }

    /// 默认选项定义
    static let defaultOptions: [PerformanceOption] = [
        PerformanceOption(
            id: "metal_hud",
            type: .metalHUD,
            displayName: "Metal HUD",
            optionDescription: "显示 Metal 性能 HUD（FPS 和 GPU 信息）",
            applicableGames: GameType.allCases,
            launchArguments: [],
            environmentVariables: ["MTL_HUD_ENABLED": "1"]
        ),
        PerformanceOption(
            id: "retina_mode",
            type: .retinaMode,
            displayName: "Retina 模式",
            optionDescription: "启用 Retina 分辨率渲染，获得更清晰的画面",
            applicableGames: GameType.allCases,
            launchArguments: [],
            environmentVariables: ["RETINA_MODE": "1"]
        ),
        PerformanceOption(
            id: "fps_unlock",
            type: .fpsUnlock,
            displayName: "帧率解锁",
            optionDescription: "解除游戏帧率上限（需游戏支持）",
            applicableGames: [.genshinImpact, .honkaiStarRail],
            launchArguments: [],
            environmentVariables: ["FPS_UNLOCK": "1"]
        ),
        PerformanceOption(
            id: "game_resolution",
            type: .gameResolution,
            displayName: "游戏运行分辨率",
            optionDescription: "设置游戏运行时的屏幕分辨率",
            applicableGames: GameType.allCases,
            value: "1920x1080",
            launchArguments: ["-screen-width", "1920", "-screen-height", "1080"]
        ),
    ]
}

// MARK: - DTO for Persistence

public struct PerformanceOptionDTO: Codable, Sendable {
    public let id: String
    public let isEnabled: Bool
    public let value: String?

    public init(id: String, isEnabled: Bool, value: String?) {
        self.id = id
        self.isEnabled = isEnabled
        self.value = value
    }
}
