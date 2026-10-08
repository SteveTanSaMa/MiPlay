//
//  StartupPreparationOverlay.swift
//  MiPlay
//

import SwiftUI

// Source: 用户指令（2026-10-07）— Wine 下载/解压/配置提到流程最前，配全屏界面与
// 进度条；随后才开始背景素材的下载与转化。
//
// 全屏阻断触控：遮罩由 `LibraryViewModel.startupPhase` 驱动，从第一帧起覆盖主页，
// 直到 Wine 环境与背景素材全部就绪；Wine 阶段失败时停在遮罩上并提供重试。

/// 启动准备全屏遮罩（Wine 环境 → 背景素材）。
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
                .font(.title3.weight(.medium))
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
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(Color.secondary)
            }
        } else {
            ProgressView()
                .controlSize(.small)
        }
    }

    private func messageView(_ message: String) -> some View {
        Text(message)
            .font(.caption)
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
