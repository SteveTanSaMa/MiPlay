//
//  GameSelectionRailView.swift
//  MiPlay
//
//  Created by Steve Tan on 2026/7/7.
//

import SwiftUI
import AppKit

// Source: UI Design → 组件树 → GameSelectionView → GameSelectionRail
// Source: UI Design → UI-11/UI-12 — 材质按钮 + hover 效果
// Source: 用户指令（2026-10-08）— 侧栏改用获取到的官方游戏 icon，替代简单符号

/// 游戏选择栏视图（垂直布局）。固定在窗口左下角。
struct GameSelectionRailView: View {
    let games: [Game]
    @Binding var selectedId: String?
    @Binding var selectedPlaceholderType: GameType?
    let onPreload: ((GameType) -> Void)?
    /// 官方游戏图标缓存路径（由 `LibraryViewModel.gameIconURLs` 提供）。
    let iconURLs: [GameType: URL]

    init(
        games: [Game],
        selectedId: Binding<String?>,
        selectedPlaceholderType: Binding<GameType?> = .constant(nil),
        onPreload: ((GameType) -> Void)? = nil,
        iconURLs: [GameType: URL] = [:]
    ) {
        self.games = games
        self._selectedId = selectedId
        self._selectedPlaceholderType = selectedPlaceholderType
        self.onPreload = onPreload
        self.iconURLs = iconURLs
    }

    /// 根据 GameType 查找是否已在库中
    private func game(for type: GameType) -> Game? {
        games.first { $0.type == type }
    }

    /// 获取某款游戏的业务状态（未入库则返回 nil）
    private func state(for type: GameType) -> GameBusinessState? {
        game(for: type)?.state
    }

    private func isSelected(_ type: GameType) -> Bool {
        if let game = game(for: type) { return selectedId == game.id }
        return selectedId == type.rawValue || (selectedId == nil && selectedPlaceholderType == type)
    }

    @Environment(\.openSettings) private var openSettings
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        GlassEffectContainer(spacing: 8) {
            VStack(alignment: .center, spacing: 0) {
                VStack(spacing: 12) {
                    ForEach(GameType.allCases, id: \.rawValue) { type in
                        gameIconButton(for: type)
                    }
                }

                // 设置入口不参与游戏图标的垂直节奏。
                settingsIconView
                    .padding(.top, 16)
            }
            // 底部不留容器内边距，让设置按钮可见下沿参与主窗口的 bottom 对齐。
            .padding(.top, 10)
        }
        // 状态描边放在玻璃容器外，避免被合成覆盖；固定几何无需缩放同步。
        .overlay(alignment: .top) {
            statusOutlines
                .allowsHitTesting(false)
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("游戏选择与设置")
    }

    /// 单个游戏图标按钮；状态描边在容器外的叠加层。
    private func gameIconButton(for type: GameType) -> some View {
        Button {
            handleTap(type: type)
        } label: {
            iconView(for: type)
                .frame(width: 56, height: 56)
        }
        .buttonStyle(.borderless)
        .focusable()
        .frame(width: 64, height: 64)
        .contentShape(Rectangle())
        .onHover { hovering in
            if hovering { onPreload?(type) }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityAddTraits(isSelected(type) ? [.isButton, .isSelected] : [.isButton])
        .onKeyPress(keys: [.return, .space], phases: .down) { _ in
            handleTap(type: type)
            return .handled
        }
        .accessibilityLabel("切换到\(type.displayName)")
        .accessibilityValue(accessibilityValue(for: type))
        .accessibilityHint("选择后显示\(type.displayName)的背景和可用操作")
        .help("切换到\(type.displayName)")
    }

    /// 镜像固定图标布局，状态描边在玻璃容器之外，命中区域保持 64pt。
    private var statusOutlines: some View {
        VStack(spacing: 12) {
            ForEach(GameType.allCases, id: \.rawValue) { type in
                Color.clear
                    .frame(width: 64, height: 64)
                    .overlay {
                        RoundedRectangle(cornerRadius: 16)
                            .strokeBorder(
                                statusColor(state(for: type) ?? .notInstalled),
                                lineWidth: contrast == .increased ? 3 : 2
                            )
                            .frame(width: 56, height: 56)
                            .shadow(color: .black.opacity(0.65), radius: 1)
                            .accessibilityHidden(true)
                    }
                    .overlay(alignment: .leading) {
                        if isSelected(type) {
                            Capsule()
                                .fill(.white)
                                .frame(width: 3, height: 20)
                                .shadow(color: .black.opacity(0.6), radius: 2)
                                .offset(x: -5)
                                .accessibilityHidden(true)
                        }
                    }
            }
            Color.clear
                .frame(width: 64, height: 64)
                .overlay(alignment: .bottom) { glassOutline(selected: false) }
                // 本层 VStack 已有 12pt spacing；补 4pt 对齐设置入口的 16pt 顶距。
                .padding(.top, 4)
        }
        .padding(.top, 10)
    }

    private func glassOutline(selected: Bool) -> some View {
        RoundedRectangle(cornerRadius: 16)
            .strokeBorder(
                .white.opacity(selected ? 0.9 : (contrast == .increased ? 0.55 : 0.2)),
                lineWidth: selected ? 1.5 : 0.75
            )
            .frame(width: 56, height: 56)
            .accessibilityHidden(true)
    }

    /// 单图标视图（官方 icon 或 SF Symbol 回退）
    private func iconView(for type: GameType) -> some View {
        return GameIconContent(
            type: type,
            iconURL: iconURLs[type],
            gameIcon: gameIconFallback(for:)
        )
    }

    private func handleTap(type: GameType) {
        if let g = game(for: type) {
            selectedPlaceholderType = nil
            selectedId = g.id
        } else {
            // Missing library entries are still selectable. The main window
            // offers both location and installation for the selected game.
            selectedId = type.rawValue
            selectedPlaceholderType = type
        }
    }

    private func accessibilityValue(for type: GameType) -> String {
        let selected = isSelected(type) ? "当前选中" : "未选中"
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

    /// 单游戏图标：优先官方 icon，缺失时回退到 SF Symbol + 玻璃面板。
    private func gameIconFallback(for type: GameType) -> Image {
        Image(systemName: type.definition.symbolName)
    }

    private var settingsIconView: some View {
        Button {
            openSettings()
        } label: {
            Image(systemName: "gearshape")
                .font(.title)
                .foregroundStyle(.white)
                .frame(width: 56, height: 56)
                .modifier(DarkGlassSurface())
        }
        .buttonStyle(.borderless)
        .focusable()
        .frame(width: 64, height: 64, alignment: .bottom)
        .contentShape(Rectangle())
        .onKeyPress(keys: [.return, .space], phases: .down) { _ in
            openSettings()
            return .handled
        }
        .accessibilityLabel("设置")
        .accessibilityHint("打开设置窗口")
        .help("设置（⌘,）")
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

/// 官方图标读取随 URL 生命周期执行，body 不进行文件 I/O。
private struct GameIconContent: View {
    let type: GameType
    /// 官方图标缓存路径；nil（或读取失败）时回退到 SF Symbol。
    let iconURL: URL?
    let gameIcon: (GameType) -> Image
    @State private var iconImage: NSImage?

    private var shape: RoundedRectangle { RoundedRectangle(cornerRadius: 16) }

    var body: some View {
        ZStack {
            if let iconImage {
                // 用户指令：侧栏显示官方游戏 icon（圆角方块，与玻璃面板同形）。
                Image(nsImage: iconImage)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
                    .frame(width: 56, height: 56)
                    .clipShape(shape)
                    .shadow(color: .black.opacity(0.25), radius: 6, y: 2)
            } else {
                gameIcon(type)
                    .font(.title)
                    .foregroundStyle(.white)
                    .shadow(color: .black.opacity(0.45), radius: 1, y: 1)
                    .frame(width: 56, height: 56)
                    // Source: Liquid Glass — P0 .glassEffect()
                    // Source: macOS 26 规范 §7.9 — 圆角标准化
                    .modifier(DarkGlassSurface())
            }
        }
        .frame(width: 56, height: 56)
        .contentShape(Rectangle())
        // 图标由启动流程异步补齐：先按缓存渲染，缓存稍后出现时再补上。
        .task(id: iconURL) {
            guard let iconURL else { iconImage = nil; return }
            let data = await Task.detached(priority: .utility) {
                try? Data(contentsOf: iconURL)
            }.value
            guard !Task.isCancelled else { return }
            iconImage = data.flatMap { NSImage(data: $0) }
        }
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
