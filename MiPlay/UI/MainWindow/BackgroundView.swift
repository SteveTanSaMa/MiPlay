//
//  BackgroundView.swift
//  MiPlay
//
//  Created by Steve Tan on 2026/7/7.
//

import SwiftUI
import AVFoundation

// Source: Architecture Design → BackgroundScene 组件化重构

/// 简化背景视图。通过 ZStack + opacity 切换三款游戏的自包含 BackgroundScene。
struct BackgroundView: View {
    let gameType: GameType?
    let media: [GameType: BackgroundMedia]

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            ForEach(GameType.allCases, id: \.rawValue) { type in
                if let m = media[type] {
                    BackgroundScene(media: m, gameId: type.rawValue, isSelected: gameType == type)
                        .opacity(gameType == type ? 1 : 0)
                }
            }
        }
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.3), value: gameType)
        // 用户像素测量：720pt 总高度包含约 32pt 的隐藏 titlebar 与 688pt 内容区。
        // 保留固定背景布局和 BackgroundScene 的 -16pt 居中补偿，不能在这里裁切安全区外背景。
        .frame(width: 1280, height: 688)
        .allowsHitTesting(false)
    }
}

#Preview {
    BackgroundView(gameType: .genshinImpact, media: [:])
        .frame(width: 800, height: 500)
}
