import SwiftUI

/// 设置页与主窗口共享的下载任务反馈。任务进度与业务完成结果分别展示。
struct GameDownloadTaskView: View {
    let task: ScheduledTask
    let download: TaskDownloadProgress?
    let resultConfirmed: Bool
    let resume: (() -> Void)?
    let cancel: () -> Void

    init(task: ScheduledTask, download: TaskDownloadProgress?, resultConfirmed: Bool,
         resume: (() -> Void)? = nil, cancel: @escaping () -> Void) {
        self.task = task
        self.download = download
        self.resultConfirmed = resultConfirmed
        self.resume = resume
        self.cancel = cancel
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            switch task.state {
            case .pending, .running:
                HStack {
                    Text(task.phaseDescription)
                        .font(.callout)
                    Spacer(minLength: 8)
                    if let progress = task.progress {
                        Text(min(max(progress, 0), 1), format: .percent.precision(.fractionLength(0)))
                            .font(.caption.monospacedDigit())
                    }
                    if task.cancellationPolicy != .notCancellable {
                        Button(GameDownloadPresentation.pauseButtonLabel(for: task), action: cancel)
                            .controlSize(.small)
                    }
                }
                ProgressView(value: task.progress.map { min(max($0, 0), 1) })
                    .progressViewStyle(.linear)
                if let download, task.phaseDescription != ScheduledTask.sophonCommitPhaseDescription {
                    HStack {
                        Text(bytes(download.bytesReceived) + (download.totalBytes > 0 ? " / " + bytes(download.totalBytes) : ""))
                        Spacer()
                        if download.speed.isFinite, download.speed > 0 {
                            Text(bytes(Int64(min(download.speed, Double(Int64.max / 2)))) + "/秒")
                        }
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
            case .completed:
                Label(
                    resultConfirmed ? (task.type == .gamePredownload ? "上次预下载完成（\(task.context["predownloadVersion"] ?? "")）" : (task.context["recoveryOnly"] == "true" ? task.phaseDescription : (task.type == .gameInstall ? "游戏安装完成" : "游戏更新完成"))) : "任务已结束，结果尚未确认",
                    systemImage: resultConfirmed ? "checkmark.circle" : "exclamationmark.triangle"
                )
                .font(.caption)
                .foregroundStyle(resultConfirmed ? Color.green : Color.orange)
            case .failed:
                Label(task.error ?? (task.type == .gameUpdate ? "游戏更新未完成，可继续更新" : "游戏下载未完成"), systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .textSelection(.enabled)
            case .cancelled:
                Text(GameDownloadPresentation.pausedMessage(for: task))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            if let recovery = task.recovery, task.state != .completed {
                Text(recovery)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let resume, task.state == .failed || task.state == .cancelled {
                Button(GameDownloadPresentation.resumeButtonLabel(for: task), action: resume)
                    .controlSize(.small)
                    .help("校验已保存的资源和安装进度后继续")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(task.context["recoveryOnly"] == "true" ? "游戏更新恢复任务" : (task.type == .gamePredownload ? "游戏预下载任务" : (task.type == .gameInstall ? "游戏安装任务" : "游戏更新任务")))
    }

    private func bytes(_ value: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: max(0, value), countStyle: .file)
    }
}
