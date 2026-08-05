//
//  ButtonLaunchingStateView.swift
//  MiPlay
//
//  Created by Steve Tan on 2026/6/21.
//

import SwiftUI

/// 按钮级启动状态视图（Button-Level Launching）
/// 替换按钮内部内容，小尺寸 ProgressView + "启动中..."
/// 语义：局部状态（inline state），不遮挡背景
struct ButtonLaunchingStateView: View {
    var body: some View {
        HStack(spacing: 10) {
            ProgressView()
                .scaleEffect(1.0)
                .controlSize(.small)
            Text("启动中...")
                .font(.body)
                .fontWeight(.semibold)
        }
        .frame(width: 160)
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
        .background(.white.opacity(0.15), in: RoundedRectangle(cornerRadius: 14))
        .foregroundStyle(.white)
    }
}

#Preview {
    ButtonLaunchingStateView()
        .padding()
        .background(Color.black)
}
