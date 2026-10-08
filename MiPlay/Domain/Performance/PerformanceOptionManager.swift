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
    /// 选项值参数的合法区间（MetalFX 空间缩放系数，DXMT 取值 1.0–2.0）。
    public nonisolated static let valueRange: ClosedRange<Double> = 1.0...2.0
    /// 选项值缺省值（DXMT 的官方默认系数）。
    public nonisolated static let defaultValue = "2"

    public let id: String
    public let type: PerformanceOptionType
    public let displayName: String
    public let optionDescription: String
    public let applicableGames: [GameType]
    public var isEnabled: Bool
    public var value: String? // 额外参数值（如分辨率）
    /// 搁置状态：`true` 时该选项**不参与启动**（`getOptionsForLaunch` 过滤），
    /// 设置界面也不展示，但选项定义、参数校验、环境模板等代码全部保留。
    /// 用于"实现已落地但暂不暴露"的功能（目前是 MetalFX 空间缩放，原因见其定义处注释）。
    public let isSuspended: Bool
    /// 启动时需传递的命令行参数
    public let launchArguments: [String]?
    /// 启动时需设置的环境变量
    public let environmentVariables: [String: String]?
    /// 需要携带 `value` 的环境变量模板（`{value}` 在启动时被替换为选项值）
    public let valueEnvironmentVariables: [String: String]?

    public init(
        id: String,
        type: PerformanceOptionType,
        displayName: String,
        optionDescription: String,
        applicableGames: [GameType],
        isEnabled: Bool = false,
        value: String? = nil,
        isSuspended: Bool = false,
        launchArguments: [String]? = nil,
        environmentVariables: [String: String]? = nil,
        valueEnvironmentVariables: [String: String]? = nil
    ) {
        self.id = id
        self.type = type
        self.displayName = displayName
        self.optionDescription = optionDescription
        self.applicableGames = applicableGames
        self.isEnabled = isEnabled
        self.value = value
        self.isSuspended = isSuspended
        self.launchArguments = launchArguments
        self.environmentVariables = environmentVariables
        self.valueEnvironmentVariables = valueEnvironmentVariables
    }

    /// 启动时需要设置的环境变量（含 `{value}` 模板展开）。
    /// 模板永远用规范化后的值展开，保证下发到启动环境的值与界面显示一致；
    /// 是否启用由 `getOptionsForLaunch` 过滤，这里不判断 `isEnabled`。
    ///
    /// `nonisolated`：启动环境在 `LaunchOrchestrator`（actor）里装配，不属于
    /// MainActor；纯计算不得要求主线程调用，否则 Swift 6 语言模式下编排器无法调用。
    nonisolated public func launchEnvironment() -> [String: String] {
        var environment = environmentVariables ?? [:]
        if let template = valueEnvironmentVariables {
            for (key, pattern) in template {
                environment[key] = pattern.replacingOccurrences(of: "{value}", with: displayValue)
            }
        }
        return environment
    }

    /// 选项级参数是否需要在界面上由用户填写（即含 `{value}` 模板）。
    public var requiresValue: Bool {
        valueEnvironmentVariables?.values.contains { $0.contains("{value}") } ?? false
    }

    /// 合并多个选项的启动环境变量；同一变量以数组中靠后的选项为准。
    nonisolated public static func launchEnvironment(for options: [PerformanceOption]) -> [String: String] {
        var environment: [String: String] = [:]
        for option in options {
            for (key, value) in option.launchEnvironment() {
                environment[key] = value
            }
        }
        return environment
    }

    /// 解析选项值：空值与不可解析的输入返回 nil。
    nonisolated static func parsedValue(_ raw: String?) -> Double? {
        guard let raw else { return nil }
        let trimmed = raw.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        guard let number = Double(trimmed.replacingOccurrences(of: ",", with: ".")),
              number.isFinite else { return nil }
        return number
    }

    /// 把选项值规范化为合法形式。
    /// 当前参数的取值范围是 DXMT 的 `d3d11.metalSpatialUpscaleFactor`（1.0–2.0）；
    /// 返回 nil 表示输入不可用，调用方保留原值。
    nonisolated static func normalizedValue(_ raw: String) -> String? {
        guard let number = parsedValue(raw) else { return nil }
        return formattedValue(number)
    }

    /// 越界值夹取到合法区间后格式化：1.0 → "1"，1.333 → "1.33"。
    nonisolated static func formattedValue(_ number: Double) -> String {
        let clamped = min(max(number, valueRange.lowerBound), valueRange.upperBound)
        // 归一化到两位小数，避免 `1.9999999` 这类浮点残差进入环境变量。
        let rounded = (clamped * 100).rounded() / 100
        // `%g` 去掉无意义的尾随零：2.0 → "2"，1.33 → "1.33"。
        return String(format: "%g", rounded)
    }

    /// 参数的规范化显示形式；值缺失或不可用时回落到默认值。
    /// `nonisolated`：`launchEnvironment()` 在非主线程（启动装配）里也要读它。
    nonisolated public var displayValue: String {
        guard let number = Self.parsedValue(value) else { return Self.defaultValue }
        return Self.formattedValue(number)
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
        case invalidValue(optionId: String, value: String)
        case persistenceFailed(String)

        public var errorDescription: String? {
            switch self {
            case .optionNotApplicable(let gameId, let optionId):
                return "选项 \(optionId) 不适用于游戏 \(gameId)"
            case .optionNotFound(let id):
                return "选项未找到: \(id)"
            case .invalidValue(let optionId, let value):
                return "选项 \(optionId) 的参数「\(value)」不可用：请输入 1.0–2.0 之间的数字"
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
        if let options = gameOptions[gameId] {
            return options
        }
        let options = builtInOptions(for: gameId)
        gameOptions[gameId] = options
        return options
    }

    /// 获取指定游戏的某个选项
    public func getOption(gameId: String, optionId: String) -> PerformanceOption? {
        return getOptions(for: gameId).first { $0.id == optionId }
    }

    /// 获取所有有选项的游戏 ID
    public func getAllGameIds() -> [String] {
        return Array(gameOptions.keys)
    }

    /// 获取启动时需要应用的选项。
    ///
    /// 搁置（`isSuspended`）的选项永远不会进入启动清单：即使它在 AppData 里
    /// 仍留着 `isEnabled = true` 的历史状态，也不会再向启动环境注入任何变量
    /// （MetalFX 空间缩放就是这种状态，见 `defaultOptions` 中的说明）。
    public func getOptionsForLaunch(gameId: String) -> [PerformanceOption] {
        return getOptions(for: gameId).filter { $0.isEnabled && !$0.isSuspended }
    }

    // MARK: - Enable/Disable

    /// 启用/禁用性能选项（每游戏独立，持久化到 AppData）
    public func setOption(gameId: String, optionId: String, enabled: Bool) async throws {
        var options = getOptions(for: gameId)
        guard let index = options.firstIndex(where: { $0.id == optionId }) else {
            throw OptionError.optionNotFound(optionId)
        }
        options[index].isEnabled = enabled
        gameOptions[gameId] = options
        do {
            try await persistOptions()
        } catch {
            options[index].isEnabled = !enabled
            gameOptions[gameId] = options
            throw OptionError.persistenceFailed(error.localizedDescription)
        }
    }

    // MARK: - Value

    /// 更新选项的参数值（每游戏独立，持久化到 AppData）。
    /// 参数会先规范化到合法区间；不可解析的输入抛出 `.invalidValue` 并保留原值。
    public func setValue(gameId: String, optionId: String, value: String) async throws {
        var options = getOptions(for: gameId)
        guard let index = options.firstIndex(where: { $0.id == optionId }) else {
            throw OptionError.optionNotFound(optionId)
        }
        guard let normalized = PerformanceOption.normalizedValue(value) else {
            throw OptionError.invalidValue(optionId: optionId, value: value)
        }
        let previous = options[index].value
        options[index].value = normalized
        gameOptions[gameId] = options
        do {
            try await persistOptions()
        } catch {
            options[index].value = previous
            gameOptions[gameId] = options
            throw OptionError.persistenceFailed(error.localizedDescription)
        }
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
        let persistedOptions = dtoMap
        try await persistenceStore.updateAppData { appData in
            appData.performanceOptions = persistedOptions
        }
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

    /// 默认选项定义。
    ///
    /// 注意：影响游戏运行的三个开关（Metal HUD、解锁帧率、MetalFX 空间缩放）
    /// 现已全部**搁置**：
    /// - Metal HUD（`metal_hud`）与解锁帧率（`fps_unlock`）按用户指令移到
    ///   「通用设置」统一管理（`GameEnvironmentSettings`，应用级、三款游戏共享），
    ///   启动环境与注册表由 `LaunchOrchestrator` / `WineRuntimeProvider` 下发；
    /// - MetalFX 空间缩放（`metalfx_spatial_upscale`）因实现搁置（见其定义处注释）。
    /// 选项定义与装配代码保留，供将来恢复"每游戏独立选项"或在域层复用。
    static let defaultOptions: [PerformanceOption] = [
        PerformanceOption(
            id: "metal_hud",
            type: .metalHUD,
            displayName: "Metal HUD",
            optionDescription: "显示 Metal 性能面板（默认 Lite 布局）",
            applicableGames: GameType.allCases,
            isSuspended: true,
            launchArguments: nil,
            // 与 `GameEnvironmentSettings.environmentVariables` 保持一致：只开 HUD，
            // 使用系统默认面板（不再覆盖 ELEMENTS / SCALE）。
            environmentVariables: ["MTL_HUD_ENABLED": "1"]
        ),
        // 帧率解锁需要外部解锁工具接入后才能生效，当前仅保存每游戏开关。
        PerformanceOption(
            id: "fps_unlock",
            type: .fpsUnlock,
            displayName: "解锁帧率",
            optionDescription: "解除帧率上限（等待解锁工具接入后生效）",
            applicableGames: [.genshinImpact, .honkaiStarRail],
            isSuspended: true,
            launchArguments: nil,
            environmentVariables: nil
        ),
        // MetalFX 空间放大（方案 B：自定义系数）——**已搁置，不参与启动**。
        //
        // 搁置原因（2026-10-06 实测 + DXMT 源码复核，详见
        // `Docs/01-research/research-dxmt-metalfx-2026-10-05.md` 的"实测校正"节）：
        // 该系数只放大 Present 输出画布（`drawable = 交换链 × 系数`），
        // 既不改变窗口大小、也不改变游戏渲染分辨率。当前项目每次启动都写
        // `RetinaMode=y`（Win32 尺寸 = 屏幕设备像素），此时任何 >1 的系数都是
        // 超采样（画质微增、性能下降），与"低分辨率渲染 + 放大到全屏原生"的
        // 目标相反。要恢复该功能，需要同时把该次启动的 `RetinaMode` 写成 `n`
        // 并固定系数 2.0（Retina 屏上才是 1:1 放大到原生），见调研文档
        // "后续要落地的形态"。
        //
        // 代码保留（选项定义、`{value}` 模板、区间校验、环境装配），
        // 恢复方式：把 `isSuspended` 改回 false，并让设置界面重新展示。
        PerformanceOption(
            id: "metalfx_spatial_upscale",
            type: .metalFXUpscale,
            displayName: "MetalFX 空间缩放",
            optionDescription: "游戏按较低分辨率渲染，再由 MetalFX 放大到屏幕",
            applicableGames: GameType.allCases,
            value: PerformanceOption.defaultValue,
            isSuspended: true,
            launchArguments: nil,
            environmentVariables: ["DXMT_METALFX_SPATIAL_SWAPCHAIN": "1"],
            valueEnvironmentVariables: ["DXMT_CONFIG": "d3d11.metalSpatialUpscaleFactor={value};"]
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
