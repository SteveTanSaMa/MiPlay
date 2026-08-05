//
//  SettingsWineView.swift
//  MiPlay
//

import SwiftUI

// Source: P2-014 -> Settings Sidebar 对齐 ADR 020

/// Wine 环境设置。
struct WineSettingsView: View {
    let settingsViewModel: SettingsViewModel

    var body: some View {
        Form {
            Section("当前运行时") {
                LabeledContent("安装与就绪", value: settingsViewModel.wineStatus.label)
                LabeledContent("托管来源", value: "官方 GitHub")
                Button("重新检测") {
                    Task { await settingsViewModel.refreshWineState() }
                }
            }

            Section("当前任务") {
                WineDownloadStatusView(settingsViewModel: settingsViewModel)
            }

            Section("已安装版本") {
                InstalledWineVersionList(settingsViewModel: settingsViewModel)
            }

            Section("可用版本") {
                AvailableWineVersionList(settingsViewModel: settingsViewModel)
            }
        }
        .formStyle(.grouped)
    }
}

private struct WineDownloadStatusView: View {
    let settingsViewModel: SettingsViewModel
    private let statusHeight: CGFloat = 122

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let task = settingsViewModel.wineDownloadTask {
                taskHeader(task)
                if task.state == .pending || task.state == .running {
                    activeTaskContent(task)
                } else {
                    terminalTaskContent(task)
                }
            } else if let recovery = settingsViewModel.wineRecoveryRequired {
                terminalMessage(recovery)
            } else {
                Text("暂无 Wine 下载或安装任务")
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, minHeight: statusHeight, maxHeight: statusHeight, alignment: .topLeading)
        .transaction { transaction in
            transaction.animation = nil
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Wine 当前任务")
        .accessibilityValue(taskAccessibilityValue)
        .accessibilityHint("阶段或终态变化时更新；进行中的任务可以取消")
    }

    @ViewBuilder
    private func taskHeader(_ task: ScheduledTask) -> some View {
        HStack(spacing: 8) {
            Text("目标：\(taskTarget(task))")
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(taskStateLabel(task))
                .frame(width: 72, alignment: .trailing)
        }
        .frame(height: 20)
    }

    @ViewBuilder
    private func activeTaskContent(_ task: ScheduledTask) -> some View {
        let progress = settingsViewModel.downloadProgress
        HStack(spacing: 8) {
            Group {
                if let value = progress?.progress {
                    ProgressView(value: min(max(value, 0), 1))
                        .accessibilityLabel("下载进度")
                        .accessibilityValue("\(Int(min(max(value, 0), 1) * 100))%")
                } else {
                    ProgressView()
                        .accessibilityLabel("下载进度")
                        .accessibilityValue("进度未知")
                }
            }
            .frame(width: 220, height: 16)

            Text(progress?.phase ?? task.phaseDescription)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: 22)

        HStack(spacing: 8) {
            Text(transferSummary(progress))
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(speedSummary(progress))
                .frame(width: 84, alignment: .trailing)
        }
        .font(.caption2.monospacedDigit())
        .foregroundStyle(.secondary)
        .frame(height: 18)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("下载传输信息")
        .accessibilityValue("\(transferSummary(progress))，\(speedSummary(progress))")

        Button("取消下载") {
            Task { await settingsViewModel.cancelWineDownload() }
        }
        .controlSize(.small)
        .frame(height: 24)
        .accessibilityLabel("取消 Wine 下载")
        .accessibilityHint("停止当前下载并清理临时资源")
    }

    @ViewBuilder
    private func terminalTaskContent(_ task: ScheduledTask) -> some View {
        terminalMessage(taskDetail(task))
    }

    private func terminalMessage(_ message: String) -> some View {
        Label {
            Text(message)
                .lineLimit(2)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, minHeight: 36, maxHeight: 36, alignment: .topLeading)
        } icon: {
            Image(systemName: "exclamationmark.triangle")
        }
        .foregroundStyle(.orange)
        .help(message)
        .accessibilityValue(message)
    }

    private func taskDetail(_ task: ScheduledTask) -> String {
        if let detail = task.error ?? task.recovery ?? settingsViewModel.wineRecoveryRequired {
            return detail
        }
        switch task.state {
        case .completed:
            return task.outcome == "wineInstalled"
                ? "安装结果已确认；当前运行时就绪状态单独显示。"
                : "任务已完成，但安装结果未确认。"
        case .cancelled:
            return task.outcome == "cleanupVerified"
                ? "下载已取消，临时资源清理已确认。"
                : "下载已取消，但清理状态尚未确认。"
        case .failed:
            return "任务失败；此前有效的已安装版本保持不变。"
        case .pending, .running:
            return task.phaseDescription
        }
    }

    private var taskAccessibilityValue: String {
        guard let task = settingsViewModel.wineDownloadTask else {
            if let recovery = settingsViewModel.wineRecoveryRequired {
                return "需要恢复：\(recovery)"
            }
            return "当前没有 Wine 下载或安装任务"
        }

        let target = taskTarget(task)
        if task.state == .pending || task.state == .running {
            let progress = settingsViewModel.downloadProgress?.progress.map {
                "\(Int(min(max($0, 0), 1) * 100))%"
            } ?? "进度未知"
            let phase = settingsViewModel.downloadProgress?.phase ?? task.phaseDescription
            return "目标 \(target)，\(taskStateLabel(task))，阶段：\(phase)，进度：\(progress)，\(transferSummary(settingsViewModel.downloadProgress))，\(speedSummary(settingsViewModel.downloadProgress))"
        }
        return "目标 \(target)，\(taskStateLabel(task))，\(taskDetail(task))"
    }

    private func taskTarget(_ task: ScheduledTask) -> String {
        task.context["tagName"] ?? "托管 Wine"
    }

    private func transferSummary(_ progress: SettingsViewModel.WineDownloadProgress?) -> String {
        guard let received = progress?.bytesReceived,
              let total = progress?.totalBytes,
              total > 0 else {
            return "大小未知"
        }
        return "\(formatBytes(received)) / \(formatBytes(total))"
    }

    private func speedSummary(_ progress: SettingsViewModel.WineDownloadProgress?) -> String {
        guard let speed = progress?.speed else { return "速度未知" }
        return "\(formatBytes(Int64(max(speed, 0))))/s"
    }

    private func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(bytes, 0), countStyle: .file)
    }

    private func taskStateLabel(_ task: ScheduledTask) -> String {
        switch task.state {
        case .pending: return "等待中"
        case .running: return "进行中"
        case .completed: return "已完成"
        case .failed: return task.recovery == nil ? "失败" : "需要恢复"
        case .cancelled: return "已取消"
        }
    }
}

private struct InstalledWineVersionList: View {
    let settingsViewModel: SettingsViewModel

    var body: some View {
        if settingsViewModel.installedWineVersions.isEmpty {
            Text("尚未安装托管 Wine 版本")
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
        } else {
            ForEach(settingsViewModel.installedWineVersions) { version in
                WineVersionRow(
                    version: version,
                    isDownloading: false,
                    settingsViewModel: settingsViewModel
                )
            }
        }
    }
}

private struct AvailableWineVersionList: View {
    let settingsViewModel: SettingsViewModel

    var body: some View {
        Group {
            if settingsViewModel.isRefreshingWineVersions {
                HStack(spacing: 8) {
                    ProgressView()
                        .controlSize(.small)
                    Text("正在获取版本")
                        .foregroundStyle(.secondary)
                }
            } else if let message = settingsViewModel.wineCatalogMessage {
                Label(message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityValue("版本目录不可用")
            } else if settingsViewModel.availableWineVersions.isEmpty {
                Text("没有可用托管 Wine 版本")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(settingsViewModel.availableWineVersions) { version in
                    WineVersionRow(
                        version: version,
                        isDownloading: settingsViewModel.activeWineDownloadTag == version.tagName,
                        settingsViewModel: settingsViewModel
                    )
                }
            }

            Button("刷新版本列表") {
                Task { await settingsViewModel.refreshWineVersions() }
            }
            .disabled(
                settingsViewModel.activeWineDownloadTag != nil
                    || settingsViewModel.isRefreshingWineVersions
            )
        }
    }
}

private struct WineVersionRow: View {
    let version: WineVersionInfo
    let isDownloading: Bool
    let settingsViewModel: SettingsViewModel
    @State private var showDeleteConfirmation = false

    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(version.name)
                    .lineLimit(1)
                Text(version.tagName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            versionAction
                .frame(width: 136, alignment: .trailing)
        }
        .frame(height: 48)
        .confirmationDialog(
            "删除 Wine 版本？",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("删除", role: .destructive) {
                Task { await settingsViewModel.deleteWineVersion(tagName: version.tagName) }
            }
        } message: {
            Text("将删除 \(version.name) 及其本地文件。")
        }
    }

    @ViewBuilder
    private var versionAction: some View {
        if version.isSelected {
            Label("当前使用", systemImage: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(.green)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("当前使用 \(version.name)")
                .accessibilityValue("已选中")
        } else if version.isDownloaded {
            HStack(spacing: 8) {
                Button("使用") {
                    Task { await settingsViewModel.selectWineVersion(tagName: version.tagName) }
                }
                .controlSize(.small)
                .accessibilityLabel("使用 \(version.name)")
                .accessibilityHint("将此已安装版本设为托管 Wine")

                Button(role: .destructive) {
                    showDeleteConfirmation = true
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("删除 \(version.name)")
                .help("删除此 Wine 版本")
            }
        } else if isDownloading {
            ProgressView()
                .controlSize(.small)
                .frame(maxWidth: .infinity, alignment: .trailing)
                .accessibilityLabel("正在下载 \(version.name)")
        } else {
            Button("下载") {
                Task { await settingsViewModel.downloadWineVersion(version) }
            }
            .controlSize(.small)
            .accessibilityLabel("下载 \(version.name)")
            .accessibilityHint("获取此托管 Wine 版本；下载完成不代表已选中或游戏已就绪")
        }
    }
}
