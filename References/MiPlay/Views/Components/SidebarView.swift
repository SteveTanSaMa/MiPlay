//
//  SidebarView.swift
//  MiPlay
//
//  Created by Steve Tan on 2026/6/20.
//
//  ⚠️ Experimental / Deprecated (not currently used)
//  该组件当前未接入 UI，但可能用于 Sprint 4A NavigationSplitView 实验阶段。
//  请勿删除。接入前需先执行导航架构评估（参见 refactor-roadmap.md）。
//

import SwiftUI

enum AppScreen: String, CaseIterable {
    case library = "游戏库"
    case settings = "设置"

    var icon: String {
        switch self {
        case .library: return "square.grid.2x2"
        case .settings: return "gearshape"
        }
    }
}

struct SidebarView: View {
    @Binding var selectedScreen: AppScreen?

    var body: some View {
        List(selection: $selectedScreen) {
            Section("MiPlay") {
                ForEach(AppScreen.allCases, id: \.rawValue) { screen in
                    Label(screen.rawValue, systemImage: screen.icon)
                        .tag(screen)
                }
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 180)
    }
}

