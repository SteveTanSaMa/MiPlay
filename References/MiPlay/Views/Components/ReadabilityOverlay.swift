//
//  ReadabilityOverlay.swift
//  MiPlay
//
//  Created by Steve Tan on 2026/6/21.
//
//  参考 Landmarks (Apple Liquid Glass Demo) 的 ReadabilityRoundedRectangle。
//  为背景图片底部添加渐变色，提高前景文字/图标的可读性。
//

import SwiftUI

/// 背景底部的黑色渐变叠加层，确保左下角游戏栏和右下角按钮有更好的可读性
struct ReadabilityOverlay: View {
    var body: some View {
        LinearGradient(
            colors: [
                .black.opacity(0.6),
                .black.opacity(0.2),
                .clear
            ],
            startPoint: .bottom,
            endPoint: .center
        )
    }
}

#Preview {
    ReadabilityOverlay()
        .frame(height: 300)
}
