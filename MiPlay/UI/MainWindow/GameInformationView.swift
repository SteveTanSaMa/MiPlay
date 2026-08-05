//
//  GameInformationView.swift
//  MiPlay
//
//  Created by Steve Tan on 2026/7/7.
//

import SwiftUI

// Source: UX Design → ux-game-information-view.md §2.1 — 三层信息架构
// Source: UX Design → ux-game-information-view.md §3.2 — 5 种核心状态映射
// Deprecated: UX-32 — 游戏信息展示已移除

/// 游戏信息展示视图。位于主窗口垂直居中位置。
/// 三层信息架构：Layer 1 Logo → Layer 2 状态/进度 → Layer 3 元信息。
/// 注意：UX-32 已移除该视图引用，当前保留为编译兼容存根。
struct GameInformationView: View {
    let game: Game?
    let launchProgress: LibraryViewModel.LaunchProgress?

    var body: some View {
        Color.clear.frame(height: 0)
    }
}
