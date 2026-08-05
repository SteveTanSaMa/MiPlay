//
//  BottomActionView.swift
//  MiPlay
//
//  Created by Steve Tan on 2026/7/7.
//

import SwiftUI

// Source: UI Design → 组件树 → BottomActionView
// Source: UI Design → View Responsibility → BottomActionView
// Source: ADR 020 — 主窗口简化（移除次要按钮，仅保留 PrimaryActionButton）

/// 底部操作区视图。包含主操作按钮。无选中游戏时占位零高度。
struct BottomActionView: View {
    let game: Game?
    let buttonState: LibraryViewModel.PrimaryButtonState
    let onPrimaryAction: () -> Void

    var body: some View {
        // 固定高度 70pt，无论是否有选中游戏，保证布局稳定
        Group {
            if game != nil {
                // Source: 用户反馈 → UX-28 — 主操作按钮居中
                HStack {
                    Spacer()
                }
                // Source: Liquid Glass — 按钮位置 + tint 增强暗色背景可读性
                .overlay(alignment: .trailing) {
                    PrimaryActionButton(state: buttonState, action: onPrimaryAction)
                }
            } else {
                Color.clear
            }
        }
        .frame(height: 70)
        .padding(.horizontal, 30)
    }
}

#if DEBUG
#Preview {
    let game = Game(id: "1", type: .genshinImpact, installPath: nil, state: .installed, version: nil, lastLaunchDate: nil, solutionApplications: [])

    BottomActionView(
        game: game,
        buttonState: .enabled(label: "启动", action: .launch),
        onPrimaryAction: {}
    )
    .padding()
    .background(Color(white: 0.1))
}
#endif
