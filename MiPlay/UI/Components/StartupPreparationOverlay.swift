//
//  StartupPreparationOverlay.swift
//  MiPlay
//

import SwiftUI

// Source: 用户指令（2026-10-09）— 素材准备与 Wine 下载/配置并行，
// Wine 先完成时继续显示剩余素材进度。
//
// 全屏阻断触控：遮罩由 `LibraryViewModel.startupPhase` 驱动，从第一帧起覆盖主页，
// 直到 Wine 就绪与素材任务结束；Wine 阶段失败时停在遮罩上并提供重试。

/// 启动准备全屏遮罩（并行准备，等待剩余素材）。
struct StartupPreparationOverlay: View {
    let phase: LibraryViewModel.StartupPhase
    let detail: String?
    let progress: Double?
    /// 准备失败原因（非 nil 时展示重试入口）。
    let failure: String?
    let retry: () -> Void

    @AccessibilityFocusState private var isTitleFocused: Bool

    var body: some View {
        Rectangle()
            // Source: 用户反馈 — 遮罩背景改为不透明白色
            .fill(Color.white)
            .ignoresSafeArea()
            .overlay { content }
            .environment(\.colorScheme, .light)
            .foregroundStyle(.primary)
            .onAppear { isTitleFocused = true }
            .accessibilityElement(children: .contain)
            .accessibilityLabel(title)
            .accessibilityValue(accessibilityValue)
    }

    // MARK: - Content

    private var content: some View {
        VStack(spacing: 16) {
            Text(title)
                .font(.title2.weight(.medium))
                .accessibilityAddTraits(.isHeader)
                .accessibilityFocused($isTitleFocused)

            if failure == nil {
                progressIndicator
            }

            if let message = messageText {
                messageView(message)
            }

            if failure != nil {
                Button("重试") { retry() }
                    .controlSize(.small)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(32)
    }

    @ViewBuilder
    private var progressIndicator: some View {
        if let value = clampedProgress {
            VStack(spacing: 6) {
                ProgressView(value: value)
                    .frame(width: 260)
                Text("\(Int(value * 100))%")
                    .font(.body.monospacedDigit())
                    .foregroundStyle(Color.secondary)
            }
        } else {
            ProgressView()
                .controlSize(.small)
        }
    }

    private func messageView(_ message: String) -> some View {
        Text(message)
            .font(.body)
            .foregroundStyle(failure == nil ? Color.secondary : Color.red)
            .multilineTextAlignment(.center)
            .frame(maxWidth: 460)
    }

    // MARK: - Presentation facts

    private var title: String {
        switch phase {
        case .preparingWine:
            return failure == nil ? "正在准备 Wine 运行环境…" : "Wine 环境准备失败"
        case .preparingMedia:
            return failure == nil ? "正在准备背景素材…" : "背景素材准备失败"
        case .ready:
            return ""
        }
    }

    private var clampedProgress: Double? {
        progress.map { min(max($0, 0), 1) }
    }

    private var messageText: String? {
        guard let message = failure ?? detail, !message.isEmpty, message != title else { return nil }
        return message
    }

    private var accessibilityValue: String {
        if let failure { return failure }
        if let value = clampedProgress {
            return "\(Int(value * 100))%，\(detail ?? "")"
        }
        return detail ?? "进行中"
    }
}
