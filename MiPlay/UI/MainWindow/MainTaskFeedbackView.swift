import SwiftUI

// Source: UI revision 2026-10-08 — keep task facts legible over theme artwork.
struct MainTaskFeedbackView: View {
    let game: Game?
    let progress: LibraryViewModel.LaunchProgress?
    let recovery: RecoveryRecord?
    let retry: (String) -> Void

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.colorSchemeContrast) private var contrast

    private var hasUnresolvedRecovery: Bool {
        guard let recovery else { return false }
        return recovery.resolvedAt == nil
    }

    var body: some View {
        if progress != nil || hasUnresolvedRecovery {
            VStack(alignment: .leading, spacing: 12) {
                if let progress {
                    VStack(alignment: .leading, spacing: 8) {
                        HStack(spacing: 8) {
                            if progress.progress == nil {
                                ProgressView().controlSize(.small)
                            }
                            Text(progress.phase)
                                .font(.system(size: 14, weight: .medium))
                                .fixedSize(horizontal: false, vertical: true)
                            Spacer(minLength: 8)
                            if let value = progress.progress {
                                Text(value, format: .percent.precision(.fractionLength(0)))
                                    .font(.body.monospacedDigit())
                                    .foregroundStyle(.secondary)
                            }
                        }
                        if let value = progress.progress {
                            ProgressView(value: value).tint(.white)
                        }
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("\(game?.type.displayName ?? "游戏")启动任务：\(progress.phase)")
                    .accessibilityValue(progress.progress.map { "\(Int($0 * 100))%" } ?? "进行中")
                }

                if let recovery, recovery.resolvedAt == nil {
                    if progress != nil { Divider() }
                    VStack(alignment: .leading, spacing: 8) {
                        Label("状态需要恢复", systemImage: "exclamationmark.triangle.fill")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundStyle(.orange)
                        Text(recovery.detail)
                            .font(.body)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                            .lineLimit(3)
                            .help(recovery.detail)
                        Button("重试恢复") { retry(recovery.id) }
                            .buttonStyle(.bordered)
                            .controlSize(.regular)
                            .font(.body)
                    }
                    .accessibilityElement(children: .contain)
                    .accessibilityLabel("\(game?.type.displayName ?? "游戏")状态恢复失败")
                    .accessibilityValue(recovery.detail)
                }
            }
            .padding(12)
            .frame(width: 280, alignment: .leading)
            .foregroundStyle(.primary)
            .background {
                let shape = RoundedRectangle(cornerRadius: 16)
                if reduceTransparency || contrast == .increased {
                    shape.fill(Color(white: 0.08))
                } else {
                    shape.fill(.regularMaterial)
                }
            }
            .environment(\.colorScheme, .dark)
            .accessibilityElement(children: .contain)
        }
    }
}
