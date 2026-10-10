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

    private var actionSymbol: String? {
        switch state.action {
        case .locate: return "folder.badge.plus"
        case .launch: return "play.fill"
        case .update: return "arrow.down.circle"
        case .none: return nil
        }
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if case .disabled(let label) = state, label.hasSuffix("…") {
                    ProgressView()
                        .controlSize(.small)
                        .tint(.white)
                }

                if let symbol = actionSymbol {
                    Image(systemName: symbol)
                        .font(.title3.weight(.semibold))
                        .accessibilityHidden(true)
                }

                Text(state.label)
                    .font(.title2)
                    .fontWeight(.semibold)
            }
            .shadow(color: .black.opacity(0.45), radius: 1, y: 1)
            .frame(width: 220, height: 64)
        }
        // Source: Liquid Glass — P0 .buttonStyle(.glass)
        // Source: UI-4 — 圆角对齐游戏图标 16pt；interactive 为 Glass 实例方法，非静态成员
        .buttonStyle(.borderless)
        .focusable()
        .foregroundStyle(state.isEnabled ? .white : .white.opacity(0.7))
        .modifier(DarkGlassSurface(interactive: state.isEnabled))
        .disabled(!state.isEnabled)
        .onKeyPress(keys: [.return, .space], phases: .down) { _ in
            guard state.isEnabled else { return .ignored }
            action()
            return .handled
        }
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
