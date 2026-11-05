//
//  SettingsWindowScene.swift
//  MiPlay
//
//  Created by Steve Tan on 2026/7/7.
//

import SwiftUI
import AppKit

// Source: ADR 020 — 设置独立窗口
// Source: UI Design → Screen Inventory → 设置
// Source: UI Design → 组件树 → SettingsWindow

/// 设置窗口场景。由 WindowGroup("settings") 承载为独立窗口。
struct SettingsWindowScene: View {
    let settingsViewModel: SettingsViewModel
    let registerWindow: (NSWindow) -> Void
    @State private var selectedSidebarItem: SettingsSidebarItem = .general

    var body: some View {
        NavigationSplitView {
            List(selection: $selectedSidebarItem) {
                Section("应用") {
                    sidebarRow(.general)
                    sidebarRow(.wineEnvironment)
                }
                Section("游戏") {
                    ForEach(SettingsSidebarItem.gameItems, id: \.self) { item in
                        sidebarRow(item)
                    }
                }
                sidebarRow(.about)
            }
            .accessibilityLabel("设置分类")
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 240, ideal: 240, max: 240)
        } detail: {
            SettingsDetailView(
                settingsViewModel: settingsViewModel,
                selectedItem: selectedSidebarItem
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .navigationSplitViewColumnWidth(min: 560, ideal: 560, max: 560)
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar(.hidden)
        .task { await settingsViewModel.loadSettings() }
        .frame(width: 800, height: 448)
        .background(SettingsWindowPositioner())
        // 用户指令：点击主窗口时要能关闭设置窗口 —— 这里把本窗口注册给 AppDelegate。
        .background(WindowRegistrar(registerWindow: registerWindow))
        .alert("无法完成操作", isPresented: .init(
            get: { settingsViewModel.errorMessage != nil },
            set: { if !$0 { settingsViewModel.clearError() } }
        )) {
            Button("好") { settingsViewModel.clearError() }
        } message: {
            Text(settingsViewModel.errorMessage ?? "")
        }
    }

    private func sidebarRow(_ item: SettingsSidebarItem) -> some View {
        Label(item.sidebarTitle, systemImage: item.icon)
            .tag(item)
    }
}

// MARK: - Sidebar

enum SettingsSidebarItem: Hashable {
    case general
    case game(GameType)
    case wineEnvironment
    case about

    /// Only games explicitly included in the built-in catalog appear here.
    static var gameItems: [SettingsSidebarItem] { GameType.allCases.map(Self.game) }

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .game(let game): return game.definition.symbolName
        case .wineEnvironment: return "wineglass"
        case .about: return "info.circle"
        }
    }

    var title: String {
        switch self {
        case .general: return "通用"
        case .game(let game): return game.displayName
        case .wineEnvironment: return "Wine 环境"
        case .about: return "关于"
        }
    }

    var sidebarTitle: String {
        if case .game(let game) = self { return game.definition.settingsSidebarTitle }
        return title
    }

    var gameType: GameType? {
        switch self {
        case .game(let game): return game
        default: return nil
        }
    }
}

// MARK: - Detail

/// 设置内容详情视图
struct SettingsDetailView: View {
    let settingsViewModel: SettingsViewModel
    let selectedItem: SettingsSidebarItem

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(selectedItem.title)
                .font(.title2.weight(.semibold))
                .accessibilityAddTraits(.isHeader)
            .padding(.horizontal, 24)
            .padding(.top, 16)
            .padding(.bottom, 8)

            detailContent
                .id(selectedItem)
        }
    }

    private var detailContent: some View {
        Group {
            switch selectedItem {
            case .general:
                GeneralSettingsView(settingsViewModel: settingsViewModel)
            case .game(let gameType):
                GameSettingsView(
                    settingsViewModel: settingsViewModel,
                    gameType: gameType
                )
            case .wineEnvironment:
                WineSettingsView(settingsViewModel: settingsViewModel)
            case .about:
                AboutView(settingsViewModel: settingsViewModel)
            }
        }
    }
}

/// Positions the Settings window when it is presented and keeps it within the
/// current screen's visible frame. This is a window-lifecycle concern, not
/// business state.
private struct SettingsWindowPositioner: NSViewRepresentable {
    func makeNSView(context: Context) -> PositioningView { PositioningView() }

    func updateNSView(_ nsView: PositioningView, context: Context) {
        nsView.centerWindowIfNeededAsync()
    }

    final class PositioningView: NSView {
        private var windowObservers: [NSObjectProtocol] = []
        private var needsCentering = true

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            windowObservers.forEach(NotificationCenter.default.removeObserver)
            windowObservers.removeAll()
            guard let window else { return }
            windowObservers.append(NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.centerWindowIfNeededAsync()
                }
            })
            windowObservers.append(NotificationCenter.default.addObserver(
                forName: NSWindow.willCloseNotification,
                object: window,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.needsCentering = true
                }
            })
            centerWindowIfNeededAsync()
        }

        override func viewWillMove(toWindow newWindow: NSWindow?) {
            if newWindow == nil {
                windowObservers.forEach(NotificationCenter.default.removeObserver)
                windowObservers.removeAll()
            }
            super.viewWillMove(toWindow: newWindow)
        }

        func centerWindowIfNeededAsync() {
            guard needsCentering else { return }
            DispatchQueue.main.async { [weak self] in
                guard let self, self.needsCentering else { return }
                self.centerWindow()
                self.needsCentering = false
            }
        }

        func centerWindow() {
            guard let window else { return }
            let mainWindow = NSApp.windows.first(where: {
                $0 !== window &&
                !($0 is NSPanel) &&
                $0.frame.size == NSSize(width: 1280, height: 688)
            }) ?? NSApp.windows.first(where: {
                $0 !== window && !($0 is NSPanel) && $0.contentView != nil
            })
            let mainFrame = mainWindow?.frame
            let screen = mainWindow?.screen ?? window.screen ?? NSScreen.main
            guard let screen else { return }

            let size = window.frame.size
            let reference = mainFrame ?? screen.visibleFrame
            let desiredOrigin = CGPoint(
                x: reference.midX - size.width / 2,
                y: reference.midY - size.height / 2
            )
            let visible = screen.visibleFrame
            let clampedOrigin = CGPoint(
                x: min(max(desiredOrigin.x, visible.minX), visible.maxX - size.width),
                y: min(max(desiredOrigin.y, visible.minY), visible.maxY - size.height)
            )
            window.setFrameOrigin(clampedOrigin)
        }
    }
}
