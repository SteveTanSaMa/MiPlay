//
//  SettingsGameView.swift
//  MiPlay
//

import SwiftUI

// Source: UI Design -> Settings per-game panel
// 用户指令：三款游戏各自独立；内容尽量精简；游戏功能设置对齐 YAAGL。

/// 单款游戏设置（原神 / 星穹铁道 / 绝区零各自独立）。
struct GameSettingsView: View {
    let settingsViewModel: SettingsViewModel
    let gameType: GameType

    private var game: Game? {
        settingsViewModel.managedGames.first { $0.type == gameType }
    }

    private var gameID: String {
        game?.id ?? gameType.rawValue
    }

    var body: some View {
        Form {
            gameSection
            actionsSection
            gameOptionsSection
        }
        .formStyle(.grouped)
    }

    // MARK: - 游戏

    @ViewBuilder
    private var gameSection: some View {
        Section("游戏") {
            LabeledContent("状态") {
                Text(gameStatusLabel)
                    .foregroundStyle(gameStatusColor)
            }

            if let path = game?.installPath, !path.isEmpty {
                LabeledContent("安装目录") {
                    HStack(spacing: 8) {
                        Text(path)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                            .help(path)
                        Button {
                            settingsViewModel.openGameDirectory(for: gameID)
                        } label: {
                            Image(systemName: "folder")
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("在访达中打开游戏目录")
                        .help("在访达中打开游戏目录")
                    }
                }
            }

            if let version = localVersion {
                LabeledContent("版本", value: version)
            }
        }
    }

    // MARK: - 操作

    @ViewBuilder
    private var actionsSection: some View {
        Section("操作") {
            HStack(spacing: 8) {
                Button {
                    Task { await settingsViewModel.checkVersion(for: gameID) }
                } label: {
                    Label(
                        settingsViewModel.isCheckingVersion(for: gameID) ? "检查中…" : "检查更新",
                        systemImage: "arrow.clockwise"
                    )
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(game == nil || settingsViewModel.isCheckingVersion(for: gameID))

                Button {
                    Task { await settingsViewModel.verifyGameFiles(for: gameID) }
                } label: {
                    Label(
                        settingsViewModel.isVerifyingFiles(for: gameID) ? "校验中…" : "校验文件完整性",
                        systemImage: "checkmark.shield"
                    )
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(game == nil || settingsViewModel.isVerifyingFiles(for: gameID))

                if settingsViewModel.isVerifyingFiles(for: gameID) {
                    ProgressView().controlSize(.small)
                }
            }

            integrityResultView

            if game == nil {
                Text("请在主窗口选择此游戏并定位安装目录。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// 最近一次「校验文件完整性」的结果（通过 / 不一致条目）。
    @ViewBuilder
    private var integrityResultView: some View {
        if let metadata = game?.lastMetadata,
           metadata.localEvidence.fileVerificationPerformed == true {
            let mismatches = metadata.localEvidence.pkgVersionValidationErrors
            if mismatches.isEmpty {
                Label(
                    "完整校验通过：\(metadata.localEvidence.pkgVersionEntryCount) 个文件全部一致",
                    systemImage: "checkmark.seal"
                )
                .font(.caption)
                .foregroundStyle(.green)
            } else {
                DisclosureGroup {
                    ForEach(Array(mismatches.enumerated()), id: \.offset) { _, detail in
                        Text(detail)
                            .font(.caption2.monospaced())
                            .textSelection(.enabled)
                    }
                } label: {
                    Label("完整校验发现 \(mismatches.count) 项不一致", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            }
        } else if let failure = game?.metadataFailure {
            Label(failure, systemImage: "exclamationmark.triangle")
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }

    // MARK: - 游戏设置（每游戏独立）

    @ViewBuilder
    private var gameOptionsSection: some View {
        // 搁置的选项（`isSuspended`，目前是 MetalFX 空间缩放）不展示开关：
        // 选项代码与参数输入保留在 `PerformanceOptionRow`/`PerformanceParameterField`
        // 中，恢复该功能时只需让领域层不再标记搁置，这里会自动重新出现。
        // 搁置原因见 `PerformanceOptionManager.defaultOptions` 与
        // `Docs/01-research/research-dxmt-metalfx-2026-10-05.md`。
        let options = settingsViewModel.options(for: gameID).filter { !$0.isSuspended }
        if !options.isEmpty {
            Section("游戏设置") {
                ForEach(options) { option in
                    PerformanceOptionRow(
                        option: option,
                        gameID: gameID,
                        settingsViewModel: settingsViewModel
                    )
                }
            }
        }
    }

    // MARK: - Presentation

    private var localVersion: String? {
        if let version = game?.lastMetadata?.localEvidence.gameVersion, !version.isEmpty {
            return version
        }
        return game?.version
    }

    private var gameStatusLabel: String {
        switch game?.state {
        case .notInstalled, .none: return "未定位"
        case .installed: return "已就绪"
        case .updateAvailable: return "有可用更新"
        case .gameUpdating: return "更新中"
        case .launching: return "启动中"
        case .running: return "正在运行"
        case .launchFailed: return "启动失败"
        }
    }

    private var gameStatusColor: Color {
        switch game?.state {
        case .installed, .running: return .green
        case .updateAvailable, .gameUpdating, .launching: return .orange
        case .launchFailed: return .red
        case .notInstalled, .none: return .secondary
        }
    }
}

// MARK: - 性能选项行

/// 一个性能选项：开关 + （可选）参数输入。
/// 带 `{value}` 模板的选项（目前是 MetalFX 空间缩放系数）在开启后展开参数输入。
private struct PerformanceOptionRow: View {
    let option: PerformanceOption
    let gameID: String
    let settingsViewModel: SettingsViewModel

    /// 当前生效的选项（以 ViewModel 为准，避免使用构造期快照）。
    private var current: PerformanceOption {
        settingsViewModel.performanceOption(gameID: gameID, optionID: option.id) ?? option
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(isOn: Binding(
                // 从 ViewModel 读取当前值，而不是读构造时捕获的快照：
                // 快照在异步持久化完成后可能与模型不一致，导致开关回弹。
                get: { current.isEnabled },
                set: { enabled in
                    // 同步应用（避免开关因异步持久化而回弹），持久化在后台进行。
                    settingsViewModel.applyPerformanceOptionChange(
                        gameID: gameID,
                        optionID: option.id,
                        enabled: enabled
                    )
                }
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.displayName)
                    Text(option.optionDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.small)
            .accessibilityLabel(option.displayName)
            .accessibilityHint(option.optionDescription)

            if current.requiresValue, current.isEnabled {
                HStack(spacing: 6) {
                    Text("系数")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    PerformanceParameterField(
                        option: current,
                        gameID: gameID,
                        settingsViewModel: settingsViewModel
                    )
                }
                .padding(.leading, 2)

                Text("系数 = 屏幕分辨率 ÷ 游戏内渲染分辨率（如游戏内 720p 输出到 1440p 用 2.0）")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, 2)
            }
        }
        .padding(.vertical, 2)
    }
}

/// 数值参数输入框：本地草稿 + 失焦/回车时提交；
/// 领域层负责区间校验与归一化，非法输入回落到已保存值。
private struct PerformanceParameterField: View {
    let option: PerformanceOption
    let gameID: String
    let settingsViewModel: SettingsViewModel

    @State private var draft: String
    @FocusState private var isEditing: Bool

    init(option: PerformanceOption, gameID: String, settingsViewModel: SettingsViewModel) {
        self.option = option
        self.gameID = gameID
        self.settingsViewModel = settingsViewModel
        _draft = State(initialValue: option.displayValue)
    }

    var body: some View {
        TextField("", text: $draft)
            .labelsHidden()
            .textFieldStyle(.roundedBorder)
            .multilineTextAlignment(.center)
            .frame(width: 64)
            .focused($isEditing)
            .onSubmit(commit)
            .onChange(of: isEditing) { _, editing in
                if !editing { commit() }
            }
            .onChange(of: option.value) { _, _ in
                // 保存被拒绝或选项值被其它路径改写时回到真实值。
                if !isEditing { draft = option.displayValue }
            }
            .accessibilityLabel("\(option.displayName)系数")
    }

    private func commit() {
        let trimmed = draft.trimmingCharacters(in: .whitespaces)
        guard let normalized = PerformanceOption.normalizedValue(trimmed) else {
            reportInvalidParameter(trimmed)
            return
        }
        // 只有真正越界的输入才提示"已按实际值生效"（`1,33` 这类合法小数不算）。
        let wasClamped = PerformanceOption.parsedValue(trimmed).map {
            !PerformanceOption.valueRange.contains($0)
        } ?? false
        draft = normalized
        guard normalized != option.displayValue else { return }
        Task {
            await settingsViewModel.setPerformanceOptionValue(
                gameID: gameID,
                optionID: option.id,
                value: normalized
            )
            draft = option.displayValue
            if wasClamped {
                settingsViewModel.reportParameterClamped(
                    optionName: option.displayName,
                    appliedValue: option.displayValue
                )
            }
        }
    }

    private func reportInvalidParameter(_ raw: String) {
        settingsViewModel.reportInvalidPerformanceParameter(
            optionName: option.displayName,
            rawValue: raw
        )
        draft = option.displayValue
    }
}
