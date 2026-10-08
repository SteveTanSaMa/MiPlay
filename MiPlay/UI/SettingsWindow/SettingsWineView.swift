//
//  SettingsWineView.swift
//  MiPlay
//

import SwiftUI

// Source: Architecture Design -> ADR 037-042 -> fixed runtime/shared prefix
// Source: 用户指令（2026-10-07）— 精简 Wine 设置页；下载/解压/配置由启动流程
// 自动完成（带全屏进度），此页只保留状态与 Wine "Mac Driver" 开关。

/// Wine 环境设置。产品只提供一个固定 runtime 和一个共享 prefix。
struct WineSettingsView: View {
    let settingsViewModel: SettingsViewModel

    var body: some View {
        Form {
            runtimeSection
        }
        .formStyle(.grouped)
    }

    // MARK: - 运行时状态

    @ViewBuilder
    private var runtimeSection: some View {
        Section("Wine 运行时") {
            LabeledContent("版本", value: settingsViewModel.fixedRuntimeTag)
            // 用户指令：来源显示为 GitHub 上该仓库的地址（可点击打开）。
            LabeledContent("来源") {
                Link(destination: settingsViewModel.wineSourceRepositoryURL) {
                    Text(settingsViewModel.wineSourceRepositoryURL.absoluteString)
                }
                .help("在浏览器中打开 Wine 运行时仓库")
            }
            LabeledContent("运行状态", value: settingsViewModel.wineStatus.label)
                .accessibilityRepresentation {
                    Text("运行状态：\(settingsViewModel.wineStatus.label)")
                }
            LabeledContent(
                "共享游戏环境",
                value: settingsViewModel.sharedPrefixReady ? "已就绪" : "未就绪"
            )
            .accessibilityRepresentation {
                Text("共享游戏环境：\(settingsViewModel.sharedPrefixReady ? "已就绪" : "未就绪")")
            }

            Text("运行环境会在打开 MiPlay 时自动准备。")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let recovery = settingsViewModel.wineRecoveryRequired {
                Label(recovery, systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)

                Button("重试环境准备") {
                    Task { await settingsViewModel.setupWineRuntime() }
                }
                .controlSize(.small)
                .disabled(settingsViewModel.activeWineDownloadTag != nil)
            }
        }
    }

}
