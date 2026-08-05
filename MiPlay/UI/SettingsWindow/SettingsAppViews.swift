//
//  SettingsAppViews.swift
//  MiPlay
//

import SwiftUI

// Source: UI Design -> Settings panels

/// 通用设置。
struct GeneralSettingsView: View {
    let settingsViewModel: SettingsViewModel

    var body: some View {
        Form {
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

            Section("更新与版本") {
                Toggle("游戏客户端更新可用通知", isOn: Binding(
                    get: { settingsViewModel.isGameUpdateNotificationEnabled },
                    set: { settingsViewModel.setGameUpdateNotificationEnabled($0) }
                ))
            }

            Section("此 Mac") {
                LabeledContent("机型标识", value: deviceValue(settingsViewModel.chipModel))
                LabeledContent("macOS 版本", value: deviceValue(settingsViewModel.systemVersion))
                LabeledContent("磁盘空间", value: diskSpaceValue(settingsViewModel.diskSpaceText))
            }

            Section("游戏库") {
                ForEach(settingsViewModel.managedGames) { game in
                    HStack {
                        Text(game.type.displayName)
                        Spacer()
                        Text(game.state == .installed ? "已定位" : "未定位")
                            .foregroundStyle(game.state == .installed ? .green : .secondary)
                    }
                }
            }

            Section("日志") {
                Button("查看日志") {
                    Task { await settingsViewModel.exportLogs() }
                }
                if let logContent = settingsViewModel.logContent {
                    if logContent.isEmpty {
                        Text("暂无日志")
                            .foregroundStyle(.secondary)
                    } else {
                        ScrollView {
                            Text(logContent)
                                .font(.caption.monospaced())
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .frame(height: 160)
                        .textSelection(.enabled)
                    }
                }
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

/// 关于信息。
struct AboutView: View {
    let settingsViewModel: SettingsViewModel

    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "gamecontroller.fill")
                .font(.system(size: 64))
                .foregroundStyle(Color.accentColor)

            Text("MiPlay")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("版本 \(settingsViewModel.aboutInfo.appVersion) (\(settingsViewModel.aboutInfo.buildNumber))")
                .font(.body)
                .foregroundStyle(.secondary)

            Text(settingsViewModel.aboutInfo.license)
                .font(.caption)
                .foregroundStyle(.tertiary)

            Divider()

            Text("一款面向 Mac 玩家的米哈游游戏启动器")
                .font(.body)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
