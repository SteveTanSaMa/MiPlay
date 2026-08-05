//
//  SettingsGameView.swift
//  MiPlay
//

import SwiftUI

// Source: UI Design -> Settings per-game metadata panel

/// 单款游戏设置。
struct GameSettingsView: View {
    let settingsViewModel: SettingsViewModel
    let gameType: GameType

    /// 当前游戏中在 managedGames 中的信息。
    private var game: Game? {
        settingsViewModel.managedGames.first { $0.type == gameType }
    }

    var body: some View {
        Form {
            Section("基本信息") {
                LabeledContent("名称", value: gameType.displayName)
                LabeledContent("英文名", value: gameType.englishName)
            }

            Section("安装状态") {
                LabeledContent("状态") {
                    Text(gameStatusLabel)
                        .foregroundStyle(gameStatusColor)
                }
                if let path = game?.installPath {
                    LabeledContent("安装路径") {
                        Text(path)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .textSelection(.enabled)
                    }
                }
                if let date = game?.lastLaunchDate {
                    LabeledContent("上次启动", value: date.formatted(date: .abbreviated, time: .shortened))
                }
            }

            Section("Metadata") {
                Toggle("显示本游戏 metadata", isOn: Binding(
                    get: { settingsViewModel.metadataDisplayEnabled(for: game?.id ?? gameType.rawValue) },
                    set: { enabled in
                        Task {
                            await settingsViewModel.setMetadataDisplayEnabled(
                                for: game?.id ?? gameType.rawValue,
                                enabled: enabled
                            )
                        }
                    }
                ))

                if settingsViewModel.metadataDisplayEnabled(for: game?.id ?? gameType.rawValue) {
                    metadataEvidence
                }
            }

            Section("游戏配置") {
                Text("性能选项和兼容方案可在游戏详情窗口中管理。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder
    private var metadataEvidence: some View {
        if let metadata = game?.lastMetadata {
            LabeledContent("状态", value: metadata.outcome.rawValue)
            LabeledContent("读取时间", value: metadata.readAt.formatted(date: .abbreviated, time: .shortened))
            LabeledContent("来源", value: metadata.localEvidence.sourceSummary.joined(separator: ", "))
            LabeledContent("解析", value: metadata.localEvidence.parseStatus.rawValue)
            LabeledContent("本地版本", value: metadata.localEvidence.gameVersion)
            LabeledContent("远程版本", value: metadata.latestVersion ?? "未取得")
            if let channel = metadata.localEvidence.channel {
                LabeledContent("channel", value: channel)
            }
            if let subChannel = metadata.localEvidence.subChannel {
                LabeledContent("sub_channel", value: subChannel)
            }
            if let cps = metadata.localEvidence.cps {
                LabeledContent("cps", value: cps)
            }
            if let sdkVersion = metadata.localEvidence.sdkVersion {
                LabeledContent("sdk_version", value: sdkVersion)
            }

            DisclosureGroup("config.ini 原始字段") {
                ForEach(Array(metadata.localEvidence.configFields.enumerated()), id: \.offset) { _, field in
                    LabeledContent("[\(field.section)] \(field.key)", value: field.value)
                }
            }

            DisclosureGroup("pkg_version 条目") {
                LabeledContent("映射", value: metadata.localEvidence.pkgVersionMapping.rawValue)
                ForEach(Array(metadata.localEvidence.pkgVersionEntries.enumerated()), id: \.offset) { _, entry in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(entry.remoteName)
                        Text("size=\(entry.fileSize), md5=\(entry.md5)")
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if !metadata.conflictDetails.isEmpty {
                Label(metadata.conflictDetails.joined(separator: "; "), systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        } else if let failure = game?.metadataFailure {
            Label(failure, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            Text("尚未读取本游戏 metadata")
                .foregroundStyle(.secondary)
        }
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
