//
//  GameSelectionRailView.swift
//  MiPlay
//
//  Created by Steve Tan on 2026/7/7.
//

import SwiftUI

// Source: UI Design → 组件树 → GameSelectionView → GameSelectionRail
// Source: UI Design → UI-11/UI-12 — 材质按钮 + hover 效果

/// 游戏选择栏视图（垂直布局）。固定在窗口左下角。
struct GameSelectionRailView: View {
    let games: [Game]
    @Binding var selectedId: String?
    @Binding var selectedPlaceholderType: GameType?
    let onRemoveGame: ((String) -> Void)?
    let onLocateGame: ((GameType) -> Void)?
    let onPreload: ((GameType) -> Void)?

    init(
        games: [Game],
        selectedId: Binding<String?>,
        selectedPlaceholderType: Binding<GameType?> = .constant(nil),
        onRemoveGame: ((String) -> Void)? = nil,
        onLocateGame: ((GameType) -> Void)? = nil,
        onPreload: ((GameType) -> Void)? = nil
    ) {
        self.games = games
        self._selectedId = selectedId
        self._selectedPlaceholderType = selectedPlaceholderType
        self.onRemoveGame = onRemoveGame
        self.onLocateGame = onLocateGame
        self.onPreload = onPreload
    }

    /// 根据 GameType 查找是否已在库中
    private func game(for type: GameType) -> Game? {
        games.first { $0.type == type }
    }

    /// 获取某款游戏的业务状态（未入库则返回 nil）
    private func state(for type: GameType) -> GameBusinessState? {
        game(for: type)?.state
    }

    @Environment(\.openSettings) private var openSettings

    var body: some View {
            GlassEffectContainer {
            VStack(alignment: .center, spacing: 0) {
                VStack(spacing: 12) {
                    ForEach(GameType.allCases, id: \.rawValue) { type in
                        Button {
                            handleTap(type: type)
                        } label: {
                            iconView(for: type)
                                .frame(width: 56, height: 56)
                        }
                        .buttonStyle(.plain)
                        .frame(width: 64, height: 64)
                        .contentShape(Rectangle())
                        .accessibilityElement(children: .ignore)
                        .accessibilityAddTraits(.isButton)
                        .onKeyPress(.return) {
                            handleTap(type: type)
                            return .handled
                        }
                        .accessibilityLabel("切换到\(type.displayName)")
                        .accessibilityValue(accessibilityValue(for: type))
                        .accessibilityHint("选择后显示\(type.displayName)的背景和可用操作")
                        .help("切换到\(type.displayName)")
                    }
                }

                // 设置入口不参与游戏图标的垂直节奏。
                settingsIconView
                    .padding(.top, 16)
            }
            .padding(.vertical, 10)
        }
    }

    /// 单图标视图（SF Symbol 48×48 + 右下角状态点）
    private func iconView(for type: GameType) -> some View {
        let isActive: Bool = {
            if let g = game(for: type) { return selectedId == g.id }
            return selectedPlaceholderType == type
        }()

        return GameIconContent(
            type: type,
            isActive: isActive,
            state: self.state(for: type),
            statusColor: statusColor,
            gameIcon: gameIcon(for:),
            onPreload: onPreload
        )
    }

    private func handleTap(type: GameType) {
        if let g = game(for: type) {
            selectedId = g.id
        } else {
            selectedPlaceholderType = type
            onLocateGame?(type)
        }
    }

    private func accessibilityValue(for type: GameType) -> String {
        let selected: String
        if let game = game(for: type) {
            selected = selectedId == game.id ? "当前选中" : "未选中"
        } else {
            selected = selectedPlaceholderType == type ? "当前选中" : "未选中"
        }
        let businessState = state(for: type).map(businessStateLabel) ?? "未定位"
        return "\(selected)，\(businessState)"
    }

    private func businessStateLabel(_ state: GameBusinessState) -> String {
        switch state {
        case .notInstalled: return "未定位"
        case .installed: return "已就绪"
        case .updateAvailable: return "有可用更新"
        case .gameUpdating: return "更新中"
        case .launching: return "启动中"
        case .running: return "正在运行"
        case .launchFailed: return "启动失败"
        }
    }

    private func gameIcon(for type: GameType) -> Image {
        switch type {
        case .genshinImpact:  return Image(systemName: "wind")
        case .honkaiStarRail: return Image(systemName: "star")
        case .zenlessZoneZero: return Image(systemName: "bolt.fill")
        }
    }

    @State private var isSettingsHovered = false

    private var settingsIconView: some View {
        Button {
            openSettings()
        } label: {
            ZStack {
                Image(systemName: "gearshape")
                    .font(.title)
                    .foregroundStyle(.primary)
                    .scaleEffect(isSettingsHovered ? 1.04 : 1.0)
                    .brightness(isSettingsHovered ? 0.1 : 0)
                    .animation(.easeOut(duration: 0.15), value: isSettingsHovered)
            }
            .frame(width: 56, height: 56)
            .glassEffect(in: RoundedRectangle(cornerRadius: 16))
            .onHover { isSettingsHovered = $0 }
        }
        .buttonStyle(.plain)
        .frame(width: 64, height: 64)
        .contentShape(Rectangle())
        .onKeyPress(.return) {
            openSettings()
            return .handled
        }
        .accessibilityLabel("设置")
        .accessibilityValue("设置窗口未打开")
        .accessibilityHint("打开设置窗口")
        .help("设置")
    }

    private func statusColor(_ state: GameBusinessState) -> Color {
        switch state {
        case .notInstalled:                   return .gray
        case .installed, .running:            return .green
        case .updateAvailable, .launchFailed: return .orange
        case .gameUpdating, .launching:       return .blue
        }
    }
}

// Source: UI Design → UI-11/UI-12 — 材质按钮 + hover 效果
private struct GameIconContent: View {
    let type: GameType
    let isActive: Bool
    let state: GameBusinessState?
    let statusColor: (GameBusinessState) -> Color
    let gameIcon: (GameType) -> Image
    let onPreload: ((GameType) -> Void)?
    @State private var isHovered = false

    var body: some View {
        ZStack(alignment: .bottomTrailing) {
            ZStack {
                gameIcon(type)
                    .font(.title)
                    .foregroundStyle(isActive ? Color.accentColor : .primary)
                    // Source: UI-6 — 只缩放 glyph，保持玻璃面板和命中框稳定
                    .scaleEffect(isActive ? 1.08 : (isHovered ? 1.04 : 1.0))
                    .brightness(isHovered ? 0.1 : 0)
                    .animation(.spring(response: 0.3, dampingFraction: 0.6), value: isActive)
                    .animation(.easeOut(duration: 0.15), value: isHovered)
            }
            .frame(width: 56, height: 56)
            // Source: Liquid Glass — P0 .glassEffect()
            // Source: macOS 26 规范 §7.9 — 圆角标准化
            .glassEffect(in: RoundedRectangle(cornerRadius: 16))

                // Source: UI-7 — 圆点置于 ZStack 顶层，脱离 glass 合成层
                if let state = state {
                    Circle()
                        .fill(statusColor(state))
                        .frame(width: 10, height: 10)
                        .overlay(Circle().stroke(.quaternary, lineWidth: 1.5))
                        .offset(x: 3, y: 3)
                }
        }
        .frame(width: 56, height: 56)
        .onHover { hovering in
            isHovered = hovering
            if hovering { onPreload?(type) }
        }
        .contentShape(Rectangle())
    }
}

#if DEBUG
#Preview {
    HStack {
        GameSelectionRailView(
            games: [
                Game(id: "1", type: .genshinImpact, installPath: nil, state: .installed, version: nil, lastLaunchDate: nil, solutionApplications: []),
                Game(id: "2", type: .honkaiStarRail, installPath: nil, state: .running, version: nil, lastLaunchDate: nil, solutionApplications: []),
            ],
            selectedId: .constant("1"),
            selectedPlaceholderType: .constant(nil)
        )
        .frame(width: 70)
        Spacer()
    }
    .frame(width: 300, height: 400)
    .background(Color(white: 0.1))
}
#endif
