//
//  CardLaunchingOverlay.swift
//  MiPlay
//
//  Created by Steve Tan on 2026/6/21.
//

import SwiftUI

/// 卡片级启动覆盖层（Card-Level Launching）
/// 全卡片 overlay，黑色半透明遮罩 + ProgressView + "启动中..."
/// 语义：阻断式状态（blocking overlay）
struct CardLaunchingOverlay: View {
    var body: some View {
        ZStack {
            Color.black.opacity(0.3)
                .clipShape(RoundedRectangle(cornerRadius: 12))
            VStack(spacing: 8) {
                ProgressView()
                    .scaleEffect(1.2)
                Text("启动中...")
                    .font(.caption)
                    .foregroundStyle(.white)
            }
        }
    }
}

#Preview {
    CardLaunchingOverlay()
        .frame(width: 300, height: 200)
}

