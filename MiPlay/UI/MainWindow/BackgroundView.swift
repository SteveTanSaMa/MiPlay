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

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            ForEach(GameType.allCases, id: \.rawValue) { type in
                if let m = media[type] {
                    BackgroundScene(media: m, gameId: type.rawValue)
                        .opacity(gameType == type ? 1 : 0)
                }
            }
        }
        .animation(.easeInOut(duration: 0.3), value: gameType)
        .frame(width: 1280, height: 688)
    }
}

#Preview {
    BackgroundView(gameType: .genshinImpact, media: [:])
        .frame(width: 800, height: 500)
}
