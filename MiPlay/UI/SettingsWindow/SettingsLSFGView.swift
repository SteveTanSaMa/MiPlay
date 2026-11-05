import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Per-game launch preferences. Resource import is shared across games.
struct LSFGSettingsSection: View {
    let settingsViewModel: SettingsViewModel
    let gameID: String

    private var settings: LSFGSettings { settingsViewModel.lsfgSettings(for: gameID) }
    private var resourcesAvailable: Bool {
        settingsViewModel.lsfgComponentInstalled && settingsViewModel.lsfgShaderImported
    }

    var body: some View {
        Section {
            Toggle(isOn: binding(\.enabled)) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("启用 LSFG 插帧")
                    Text("为当前游戏生成中间帧，下次启动游戏时生效。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .toggleStyle(CenteredSettingsToggleStyle())
            // A missing component must never prevent switching an existing request off.
            .disabled(!settings.enabled && !resourcesAvailable)

            LabeledContent("插帧资源") {
                HStack(spacing: 10) {
                    Text(settingsViewModel.lsfgShaderImported ? "已导入" : "尚未导入")
                        .foregroundStyle(.secondary)
                    Button(settingsViewModel.isImportingLSFGShader ? "检查中…" : "导入资源…", action: chooseShaderPackage)
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                        .frame(minWidth: 96)
                        .disabled(settingsViewModel.isImportingLSFGShader)
                }
            }
            .settingsRowLayout()

            if !settingsViewModel.lsfgComponentInstalled {
                Text("此版本缺少 LSFG 运行组件，暂时无法启用插帧。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if !settingsViewModel.lsfgShaderImported {
                Text("请导入你安装的 Lossless Scaling「lsfg-vk」测试分支中的 lsfg-vk.dll。所有游戏共用这份资源。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if settings.enabled {
                LabeledContent("插帧倍率上限") {
                    Picker("插帧倍率上限", selection: binding(\.multiplier)) {
                        ForEach(2...4, id: \.self) { Text("\($0)×").tag($0) }
                    }
                    .labelsHidden()
                    .pickerStyle(.segmented)
                    .frame(width: 160)
                }
                .settingsRowLayout()

                Picker("插帧目标帧率", selection: binding(\.targetFPS)) {
                    Text("自动").tag(Int?.none)
                    ForEach([60, 90, 120, 144, 165, 240], id: \.self) {
                        Text("\($0) FPS").tag(Optional($0))
                    }
                    if let target = settings.targetFPS, ![60, 90, 120, 144, 165, 240].contains(target) {
                        Text("\(target) FPS").tag(Optional(target))
                    }
                }
                .settingsRowLayout()
                .help("用于估算插帧数量，不更改显示器刷新率或强制限帧；自动按主屏最高刷新率估算。")

                Toggle(isOn: binding(\.performanceMode)) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("性能模式")
                        Text("减少插帧计算量，可能影响运动画面的细节。")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .toggleStyle(CenteredSettingsToggleStyle())

                Picker("光流分辨率", selection: binding(\.flowScale)) {
                    Text("100%（质量优先）").tag(1.0)
                    Text("75%").tag(0.75)
                    Text("50%").tag(0.5)
                    Text("25%（速度优先）").tag(0.25)
                    if ![1.0, 0.75, 0.5, 0.25].contains(settings.flowScale) {
                        Text(settings.flowScale, format: .percent.precision(.fractionLength(0)))
                            .tag(settings.flowScale)
                    }
                }
                .settingsRowLayout()
            }
        } header: {
            Text("LSFG 插帧（实验性）")
        } footer: {
            Text("倍率为上限，按目标帧率安排显示帧。插帧显示同步独立于游戏内垂直同步。建议先用 2×；插帧会占用 GPU 资源，不提升输入采样帧率。")
        }
    }

    private func binding<Value>(_ keyPath: WritableKeyPath<LSFGSettings, Value>) -> Binding<Value> {
        Binding(
            get: { settingsViewModel.lsfgSettings(for: gameID)[keyPath: keyPath] },
            set: { value in settingsViewModel.applyLSFGSettingsChange(for: gameID) { $0[keyPath: keyPath] = value } }
        )
    }

    private func chooseShaderPackage() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = false
        panel.canChooseFiles = true
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [UTType(filenameExtension: "dll") ?? .data]
        panel.prompt = "导入"
        panel.message = "选择 Lossless Scaling 的 lsfg-vk.dll；普通 Lossless.dll 不适用于此插帧组件。"
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            Task { await settingsViewModel.importLSFGShader(from: url) }
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }
}
