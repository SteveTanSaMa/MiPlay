import SwiftUI

// Source: 用户要求（2026-10-07）— 用黑色液态玻璃改善主题背景上的控件识别度。
// Source: 用户指令（2026-10-08）— 保留原生 `.glassEffect`；打开设置时由 AppDelegate
//   保留主窗口的 main 状态，设置窗口持有 key，避免主窗口玻璃降级。
//   相关测量见 QAArtifacts/WindowFocusGlass-20261008/README.md。
// 仅应用于主窗口的浮动控件；不改变设置窗口或系统弹窗的外观。
struct DarkGlassSurface: ViewModifier {
    var interactive = true

    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.colorSchemeContrast) private var contrast

    private let shape = RoundedRectangle(cornerRadius: 16)

    func body(content: Content) -> some View {
        surface(content)
            .overlay {
                shape.strokeBorder(
                    .white.opacity(contrast == .increased ? 0.55 : 0.2),
                    lineWidth: 0.75
                )
                .allowsHitTesting(false)
                .accessibilityHidden(true)
            }
            .shadow(color: .black.opacity(0.18), radius: 6, y: 2)
            .environment(\.colorScheme, .dark)
    }

    @ViewBuilder
    private func surface(_ content: Content) -> some View {
        if reduceTransparency || contrast == .increased {
            content.background(Color(white: 0.08), in: shape)
        } else {
            // 用户反馈：厚黑底遮住液态玻璃的通透感。去掉固定底色，
            // 使用 clear 玻璃与轻烟黑 tint，让背景透入并保留原生折射。
            content
                .glassEffect(
                    .clear.tint(.black.opacity(0.18)).interactive(interactive && !reduceMotion),
                    in: shape
                )
        }
    }
}
