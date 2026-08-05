//
//  View+Extensions.swift
//  MiPlay
//
//  Created by Steve Tan on 2026/6/20.
//

import SwiftUI

extension View {
    func cardStyle() -> some View {
        self
            .background(Color(nsColor: .windowBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 12))
            .shadow(color: .black.opacity(0.1), radius: 4, x: 0, y: 2)
    }

    /// 底层毛玻璃实现（内部 API，业务层请使用 buttonGlass / panelGlass）
    func glassBackground(
        material: Material = .ultraThinMaterial,
        cornerRadius: CGFloat = 12,
        border: (color: Color, width: CGFloat)? = nil
    ) -> some View {
        self
            .background(material, in: RoundedRectangle(cornerRadius: cornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: cornerRadius)
                    .strokeBorder(border?.color ?? .clear, lineWidth: border?.width ?? 0)
            )
    }

    /// 按钮级毛玻璃（Button Glass）
    /// 语义：紧凑型操作按钮，ultraThin 材质 + 11pt 圆角 + 白色薄边框
    func buttonGlass() -> some View {
        self
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 11))
            .overlay(
                RoundedRectangle(cornerRadius: 11)
                    .strokeBorder(.white.opacity(0.15), lineWidth: 0.5)
            )
    }

    /// 面板级毛玻璃（Panel Glass）
    /// 语义：容器面板，regular 材质 + 18pt 圆角，无边
    func panelGlass() -> some View {
        self
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18))
    }

    func sectionHeaderStyle() -> some View {
        self
            .font(.headline)
            .foregroundStyle(.secondary)
            .padding(.horizontal)
            .padding(.vertical, 8)
    }
}

