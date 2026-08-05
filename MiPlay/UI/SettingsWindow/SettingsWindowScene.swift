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
    @State private var selectedSidebarItem: SettingsSidebarItem = .general

    var body: some View {
        NavigationSplitView {
            List(SettingsSidebarItem.allCases, id: \.self, selection: $selectedSidebarItem) { item in
                Label(item.rawValue, systemImage: item.icon)
                    .tag(item)
            }
            .listStyle(.sidebar)
            .frame(width: 240)
            .navigationSplitViewColumnWidth(min: 240, ideal: 240, max: 240)
        } detail: {
            SettingsDetailView(
                settingsViewModel: settingsViewModel,
                selectedItem: selectedSidebarItem
            )
            .frame(width: 560, alignment: .topLeading)
            .frame(maxHeight: .infinity, alignment: .topLeading)
            .navigationSplitViewColumnWidth(min: 560, ideal: 560, max: 560)
        }
        .navigationSplitViewStyle(.balanced)
        .toolbar(.hidden)
        .task { await settingsViewModel.loadSettings() }
        .frame(width: 800, height: 448)
        .background(SettingsWindowPositioner())
        .alert("无法完成操作", isPresented: .init(
            get: { settingsViewModel.errorMessage != nil },
            set: { if !$0 { settingsViewModel.clearError() } }
        )) {
            Button("好") { settingsViewModel.clearError() }
        } message: {
            Text(settingsViewModel.errorMessage ?? "")
        }
    }
}

// MARK: - Sidebar

enum SettingsSidebarItem: String, CaseIterable, Hashable {
    // Source: P2-014 — Settings Sidebar 对齐 ADR 020（6 Pane / 240pt）
    case general = "通用"
    case gameGenshin = "原神"
    case gameStarRail = "星穹铁道"
    case gameZZZ = "绝区零"
    case wineEnvironment = "Wine 环境"
    case about = "关于"

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .gameGenshin: return "wind"
        case .gameStarRail: return "star"
        case .gameZZZ: return "bolt.fill"
        case .wineEnvironment: return "wineglass"
        case .about: return "info.circle"
        }
    }

    var gameType: GameType? {
        switch self {
        case .gameGenshin: return .genshinImpact
        case .gameStarRail: return .honkaiStarRail
        case .gameZZZ: return .zenlessZoneZero
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
        Group {
            switch selectedItem {
            case .general:
                GeneralSettingsView(settingsViewModel: settingsViewModel)
            case .gameGenshin, .gameStarRail, .gameZZZ:
                if let gameType = selectedItem.gameType {
                    GameSettingsView(
                        settingsViewModel: settingsViewModel,
                        gameType: gameType
                    )
                }
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
