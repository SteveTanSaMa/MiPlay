//
//  MediaLoadingOverlay.swift
//  MiPlay
//
//  Created by Steve Tan on 2026/7/7.
//

import SwiftUI

/// 媒体素材加载覆盖层。背景素材下载/转码时显示半透明遮罩 + 进度指示。
/// 全屏阻断触控，直至素材就绪。
struct MediaLoadingOverlay: View {
    // Source: UI-8 — 素材加载时隐藏所有按钮
    var body: some View {
        Rectangle()
            // Source: 用户反馈 — 遮罩背景改为不透明白色
            .fill(Color.white)
            .ignoresSafeArea()
            .overlay {
                ProgressView("正在准备背景素材…")
            }
    }
}

#Preview {
    MediaLoadingOverlay()
        .frame(width: 400, height: 300)
}
