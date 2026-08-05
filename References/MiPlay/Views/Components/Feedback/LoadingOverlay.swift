//
//  LoadingOverlay.swift
//  MiPlay
//
//  Created by Steve Tan on 2026/6/21.
//

import SwiftUI

/// 全屏加载覆盖层，包含深色背景、进度指示器和消息文字
struct LoadingOverlay: View {
    let message: String

    var body: some View {
        ZStack {
            Color(red: 0.08, green: 0.1, blue: 0.18)
                .ignoresSafeArea()

            VStack(spacing: 16) {
                ProgressView()
                    .scaleEffect(1.2)
                    .controlSize(.large)
                Text(message)
                    .font(.headline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

#Preview {
    LoadingOverlay(message: "正在准备素材...")
}
