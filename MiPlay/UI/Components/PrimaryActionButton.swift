//
//  PrimaryActionButton.swift
//  MiPlay
//
//  Created by Steve Tan on 2026/7/7.
//

import SwiftUI

// Source: UI Design → 组件树 → PrimaryActionButton
// Source: UI Design → 底部操作区状态映射

/// 主操作按钮组件。
/// 根据游戏状态显示不同的按钮样式和文字。
// Source: UI Design → UI-11/UI-12 — 材质按钮 + hover 效果
struct PrimaryActionButton: View {
    let state: LibraryViewModel.PrimaryButtonState
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if case .disabled = state {
                    ProgressView()
                        .scaleEffect(0.8)
                        .controlSize(.small)
                }

                Text(state.label)
                    .font(.title3)
                    .fontWeight(.semibold)
            }
            .frame(width: 220, height: 64)
        }
        // Source: Liquid Glass — P0 .buttonStyle(.glass)
        // Source: UI-4 — 圆角对齐游戏图标 16pt；interactive 为 Glass 实例方法，非静态成员
        .buttonStyle(.plain)
        .glassEffect(Glass.regular.interactive(true), in: RoundedRectangle(cornerRadius: 16))
        .foregroundStyle(.white)
        .disabled(!state.isEnabled)
        .opacity(state.isEnabled ? 1.0 : 0.35)
        .accessibilityLabel(state.label)
        .accessibilityValue(state.isEnabled ? "可执行" : "不可用，\(state.label)")
        .accessibilityHint(state.isEnabled ? "执行当前选中游戏的操作" : "当前操作不可用")
        .help(state.label)
    }
}

#Preview {
    HStack(spacing: 20) {
        PrimaryActionButton(state: .enabled(label: "启动", action: .launch)) {}
        PrimaryActionButton(state: .disabled("启动中…")) {}
    }
    .padding()
}
