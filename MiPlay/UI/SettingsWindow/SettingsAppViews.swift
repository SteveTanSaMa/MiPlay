//
//  SettingsAppViews.swift
//  MiPlay
//

import SwiftUI

/// A shared minimum row height keeps controls aligned while allowing longer
/// labels to grow naturally instead of being clipped.
extension View {
    func settingsRowLayout() -> some View {
        frame(minHeight: 44, alignment: .center)
    }
}

/// The system switch style aligns with a multiline label's first baseline in a
/// Form. Lay out the label and native switch explicitly so their centers match.
struct CenteredSettingsToggleStyle: ToggleStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(alignment: .center, spacing: 12) {
            configuration.label
                .frame(maxWidth: .infinity, alignment: .leading)
            Toggle("", isOn: configuration.$isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
        .frame(minHeight: 44)
        .accessibilityRepresentation {
            Toggle(isOn: configuration.$isOn) { configuration.label }
                .toggleStyle(.switch)
        }
    }
}

// Source: UI Design -> Settings panels
// 用户指令：设置界面尽可能精简；诊断信息移入「关于」。

/// 通用设置：只保留常用项。
struct GeneralSettingsView: View {
    let settingsViewModel: SettingsViewModel
    @AppStorage("showGameNews") private var showGameNews = true
    @AppStorage(BackgroundMediaService.retainOutdatedBackgroundsKey) private var retainOutdatedBackgrounds = BackgroundMediaService.retainOutdatedBackgroundsDefault

    var body: some View {
        Form {
            // 用户指令：把影响游戏运行的设置（Metal HUD、超帧率、Retina、按键映射）
            // 统一放在通用设置里（原先分散在每款游戏与 Wine 页），并置顶；
            // 「语言」「更新」下移到其后。
            Section {
                Toggle(isOn: Binding(
                    get: { settingsViewModel.gameEnvironmentSettings.metalHUD },
                    set: { settingsViewModel.applyMetalHUD($0) }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Metal HUD")
                        Text("显示帧率、GPU 时间与渲染分辨率。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(CenteredSettingsToggleStyle())
                .controlSize(.small)
                .settingsRowLayout()
                .accessibilityLabel("Metal HUD")
                .accessibilityHint("显示帧率、GPU 时间与渲染分辨率。")

                Toggle(isOn: Binding(
                    get: { settingsViewModel.gameEnvironmentSettings.fpsUnlock },
                    set: { settingsViewModel.applyFPSUnlock($0) }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("解锁帧率上限")
                        // 游戏名统一走 `GameType.displayName`（「原神」「崩坏：星穹铁道」），
                        // 避免手写出现冒号/点号不一致。
                        Text("解锁「\(GameType.genshinImpact.displayName)」与「\(GameType.honkaiStarRail.displayName)」的帧率上限")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(CenteredSettingsToggleStyle())
                .controlSize(.small)
                .settingsRowLayout()
                .accessibilityLabel("解锁帧率上限")
                .accessibilityHint("适用于原神和崩坏：星穹铁道。")

                Toggle(isOn: Binding(
                    get: { settingsViewModel.gameEnvironmentSettings.dlssCompatibility },
                    set: { settingsViewModel.applyDLSSCompatibility($0) }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("DLSS 兼容（实验性）")
                        Text("支持的 DirectX 11 游戏可使用 MetalFX 时间缩放；不支持帧生成。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(CenteredSettingsToggleStyle())
                .controlSize(.small)
                .settingsRowLayout()
                .help("需要游戏原生支持 DLSS。在游戏内选择 DLSS 质量档位；可能影响兼容性，建议仅在需要时开启。")
                .accessibilityLabel("DLSS 兼容（实验性）")
                .accessibilityHint("需要游戏原生支持 DLSS。在游戏内选择质量档位，可能影响兼容性。下次启动生效。")

                Toggle(isOn: Binding(
                    get: { settingsViewModel.gameEnvironmentSettings.retinaMode },
                    set: { settingsViewModel.applyRetinaMode($0) }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Retina 模式")
                        // 文案随开关切换：开 = Retina 渲染；关 = macOS 逻辑分辨率渲染。
                        Text(settingsViewModel.gameEnvironmentSettings.retinaMode
                             ? "以 Retina 模式渲染"
                             : "以 macOS 逻辑分辨率渲染")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(CenteredSettingsToggleStyle())
                .controlSize(.small)
                .settingsRowLayout()
                .accessibilityLabel("Retina 模式")
                .accessibilityHint("使用 Retina 分辨率渲染。")

                Toggle(isOn: Binding(
                    get: { settingsViewModel.gameEnvironmentSettings.leftCommandIsCtrl },
                    set: { settingsViewModel.applyLeftCommandIsCtrl($0) }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("左 Command 键用作 Control")
                        Text("使用左 ⌘ 执行游戏内 Ctrl 快捷键。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(CenteredSettingsToggleStyle())
                .controlSize(.small)
                .settingsRowLayout()
                .accessibilityLabel("左 Command 键用作 Control")
                .accessibilityHint("使用左 Command 执行游戏内 Control 快捷键。")

            } header: {
                Text("游戏运行")
            } footer: {
                Text("更改将在下次启动游戏时生效。")
            }

            Section("主窗口") {
                Toggle(isOn: $showGameNews) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("游戏新闻")
                        Text("在主窗口显示当前游戏的新闻。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(CenteredSettingsToggleStyle())
                .controlSize(.small)
                .settingsRowLayout()
                .accessibilityLabel("游戏新闻")
            }

            Section("背景缓存") {
                Toggle(isOn: $retainOutdatedBackgrounds) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("保留过时背景素材")
                        Text("开启后可为每款游戏选择是否缓存全部背景并保留过时素材。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(CenteredSettingsToggleStyle())
                .controlSize(.small)
                .settingsRowLayout()
                .accessibilityLabel("保留过时背景素材")
                .accessibilityHint("关闭后将在下次加载背景时自动清理旧背景。")
                .onChange(of: retainOutdatedBackgrounds) { _, _ in
                    settingsViewModel.backgroundRetentionSettingDidChange()
                }

                ForEach(GameType.allCases, id: \.rawValue) { game in
                    GameBackgroundRetentionToggle(
                        game: game,
                        isAvailable: retainOutdatedBackgrounds,
                        settingsViewModel: settingsViewModel
                    )
                }
            }

            Section("语言") {
                Picker("界面语言", selection: Binding(
                    get: { settingsViewModel.currentLanguage },
                    set: { settingsViewModel.setLanguage($0) }
                )) {
                    ForEach(settingsViewModel.availableLanguages, id: \.code) { lang in
                        Text(lang.name).tag(lang.code)
                    }
                }
                .settingsRowLayout()
            }

            Section("目录") {
                HStack {
                    Text("应用数据目录")
                    Spacer()
                    Button {
                        Task { await settingsViewModel.openDataDirectory() }
                    } label: {
                        Text("打开").frame(width: 54)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .accessibilityLabel("打开应用数据目录")
                }
                .settingsRowLayout()
                HStack {
                    Text("日志目录")
                    Spacer()
                    Button {
                        Task { await settingsViewModel.openLogsDirectory() }
                    } label: {
                        Text("打开").frame(width: 54)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.regular)
                    .accessibilityLabel("打开日志目录")
                }
                .settingsRowLayout()
            }
        }
        .formStyle(.grouped)
    }
}

/// Each game keeps its own preference even while the shared switch is off.
private struct GameBackgroundRetentionToggle: View {
    let game: GameType
    let isAvailable: Bool
    let settingsViewModel: SettingsViewModel
    @AppStorage private var retainForGame: Bool

    init(game: GameType, isAvailable: Bool, settingsViewModel: SettingsViewModel) {
        self.game = game
        self.isAvailable = isAvailable
        self.settingsViewModel = settingsViewModel
        self._retainForGame = AppStorage(
            wrappedValue: BackgroundMediaService.retainOutdatedBackgroundsForGameDefault,
            BackgroundMediaService.retentionPreferenceKey(forGameID: game.rawValue)
        )
    }

    var body: some View {
        Toggle(isOn: $retainForGame) {
            Text(game.displayName)
        }
        .toggleStyle(CenteredSettingsToggleStyle())
        .controlSize(.small)
        .settingsRowLayout()
        .disabled(!isAvailable)
        .accessibilityLabel("保留\(game.displayName)的过时背景素材")
        .accessibilityHint("关闭后将在下次加载此游戏背景时清理过时素材。")
        .onChange(of: retainForGame) { _, _ in
            settingsViewModel.backgroundRetentionSettingDidChange(forGameID: game.rawValue)
        }
    }
}

/// 关于：版本信息 + 本机诊断信息（由「通用」移入）。
struct AboutView: View {
    let settingsViewModel: SettingsViewModel

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    Image(systemName: "gamecontroller.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(Color.accentColor)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("MiPlay")
                            .font(.title2)
                            .fontWeight(.bold)
                        Text("版本 \(settingsViewModel.aboutInfo.appVersion) (\(settingsViewModel.aboutInfo.buildNumber))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(settingsViewModel.aboutInfo.license)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                }
                .padding(.vertical, 4)
            }

            Section("此 Mac") {
                LabeledContent("机型", value: deviceValue(settingsViewModel.machineName)).settingsRowLayout()
                LabeledContent("芯片", value: deviceValue(settingsViewModel.chipName)).settingsRowLayout()
                LabeledContent("内存", value: deviceValue(settingsViewModel.physicalMemoryText)).settingsRowLayout()
                LabeledContent("macOS 版本", value: deviceValue(settingsViewModel.systemVersion)).settingsRowLayout()
                LabeledContent("Wine 目标磁盘空间", value: diskSpaceValue(settingsViewModel.diskSpaceText)).settingsRowLayout()
            }
        }
        .formStyle(.grouped)
    }

    private func deviceValue(_ value: String) -> String {
        value.isEmpty ? "未知" : value
    }

    private func diskSpaceValue(_ value: String) -> String {
        value == "检测失败" || value.isEmpty ? "无法读取目标磁盘空间" : value
    }
}
