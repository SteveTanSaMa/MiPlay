//
//  SettingsAppViews.swift
//  MiPlay
//

import SwiftUI

// Source: UI Design -> Settings panels
// 用户指令：设置界面尽可能精简；诊断信息移入「关于」。

/// 通用设置：只保留常用项。
struct GeneralSettingsView: View {
    let settingsViewModel: SettingsViewModel
    @AppStorage("showGameNews") private var showGameNews = true

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
                .toggleStyle(.switch)
                .controlSize(.small)
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
                .toggleStyle(.switch)
                .controlSize(.small)
                .accessibilityLabel("解锁帧率上限")
                .accessibilityHint("适用于原神和崩坏：星穹铁道。")

                Toggle(isOn: Binding(
                    get: { settingsViewModel.gameEnvironmentSettings.dlssCompatibility },
                    set: { settingsViewModel.applyDLSSCompatibility($0) }
                )) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("DLSS 兼容（实验性）")
                        Text("支持的 DirectX 11 游戏可使用 MetalFX 时间缩放。开启后，在游戏内选择 DLSS 质量档位；不支持帧生成。可能影响兼容性，建议仅在需要时开启。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(.switch)
                .controlSize(.small)
                .disabled(!GameEnvironmentSettings.supportsDLSSCompatibility)
                .accessibilityHint("需要 Apple Silicon 和游戏原生 DLSS 支持。下次启动生效。")

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
                .toggleStyle(.switch)
                .controlSize(.small)
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
                .toggleStyle(.switch)
                .controlSize(.small)
                .accessibilityLabel("左 Command 键用作 Control")
                .accessibilityHint("使用左 Command 执行游戏内 Control 快捷键。")

            } header: {
                Text("游戏运行")
            } footer: {
                Text("更改将在下次启动游戏时生效。")
            }

            Section("主窗口") {
                Toggle("在主窗口显示游戏新闻", isOn: $showGameNews)
                    .toggleStyle(.switch)
                    .controlSize(.small)
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
            }

            Section("更新") {
                Toggle("游戏客户端更新可用通知", isOn: Binding(
                    get: { settingsViewModel.isGameUpdateNotificationEnabled },
                    set: { settingsViewModel.setGameUpdateNotificationEnabled($0) }
                ))
            }

            Section("目录") {
                Button("打开应用数据目录") {
                    Task { await settingsViewModel.openDataDirectory() }
                }
                Button("打开日志目录") {
                    Task { await settingsViewModel.openLogsDirectory() }
                }
            }
        }
        .formStyle(.grouped)
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
                LabeledContent("机型", value: deviceValue(settingsViewModel.machineName))
                LabeledContent("芯片", value: deviceValue(settingsViewModel.chipName))
                LabeledContent("内存", value: deviceValue(settingsViewModel.physicalMemoryText))
                LabeledContent("macOS 版本", value: deviceValue(settingsViewModel.systemVersion))
                LabeledContent("Wine 目标磁盘空间", value: diskSpaceValue(settingsViewModel.diskSpaceText))
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
