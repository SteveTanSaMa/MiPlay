//
//  BackgroundImageView.swift
//  MiPlay
//
//  Created by Steve Tan on 2026/6/21.
//
//  背景图容器：支持 API 图片和用户自定义图片两种方案，
//  以及 fill / fit 两种填充模式。
//

import SwiftUI

/// 背景图容器
struct BackgroundImageView: View {
    /// API 获取的背景图（按 GameType）
    let apiImage: NSImage?
    /// 用户自定义图片
    let customImage: NSImage?
    /// 是否启用自定义图片
    let useCustomImage: Bool
    /// 填充模式
    let fillMode: BackgroundFillMode

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                // 无图片时的默认背景（作为底层）
                defaultBackground

                // 有图片时显示，始终 fill 填满容器
                if let image = displayImage {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        }
    }

    /// 当前实际显示的图片
    private var displayImage: NSImage? {
        if useCustomImage, let custom = customImage {
            return custom
        }
        return apiImage
    }

    /// 默认背景（无图片时显示深色渐变）
    private var defaultBackground: some View {
        DefaultGradientBackground()
    }
}

#Preview {
    BackgroundImageView(
        apiImage: nil,
        customImage: nil,
        useCustomImage: false,
        fillMode: .fill
    )
    .ignoresSafeArea()
    .frame(width: 900, height: 562)
}
