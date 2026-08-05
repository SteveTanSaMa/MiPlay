//
//  DefaultGradientBackground.swift
//  MiPlay
//
//  Created by Steve Tan on 2026/6/21.
//

import SwiftUI

/// 深色渐变背景（深蓝→深黑），作为无内容时的默认背景
struct DefaultGradientBackground: View {
    var body: some View {
        LinearGradient(
            colors: [
                Color(red: 0.08, green: 0.1, blue: 0.18),
                Color(red: 0.05, green: 0.06, blue: 0.12)
            ],
            startPoint: .top,
            endPoint: .bottom
        )
    }
}

#Preview {
    DefaultGradientBackground()
        .ignoresSafeArea()
        .frame(width: 900, height: 562)
}
