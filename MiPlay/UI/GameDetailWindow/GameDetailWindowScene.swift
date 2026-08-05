//
//  GameDetailWindowScene.swift
//  MiPlay
//
//  Created by Steve Tan on 2026/7/7.
//

import SwiftUI

// Source: UI Design → Screen Inventory → 游戏详情
// Source: UI Design → 组件树 → GameDetailWindow
// Source: Code Review → CR-5 — 移除死代码 GameDetailWindowScene

/// 游戏详情窗口视图
struct GameDetailWindowView: View {
    @State private var viewModel: GameDetailViewModel
    @State private var selectedTab: DetailTab = .solutions
    let initialGameId: String?

    enum DetailTab: String, CaseIterable {
        case solutions = "兼容方案"
        case performance = "性能选项"
        case info = "游戏信息"

        var icon: String {
            switch self {
            case .solutions: return "wrench.and.screwdriver"
            case .performance: return "slider.horizontal.3"
            case .info: return "info.circle"
            }
        }
    }

    init(
        gameRegistry: GameRegistry,
        solutionEngine: SolutionEngine,
        performanceOptionManager: PerformanceOptionManager,
        taskScheduler: TaskScheduler,
        initialGameId: String?,
        initialTab: String? = nil
    ) {
        self._viewModel = State(initialValue: GameDetailViewModel(
            gameRegistry: gameRegistry,
            solutionEngine: solutionEngine,
            performanceOptionManager: performanceOptionManager,
            taskScheduler: taskScheduler
        ))
        self.initialGameId = initialGameId
        if let tab = initialTab, let parsed = DetailTab(rawValue: tab) {
            self._selectedTab = State(initialValue: parsed)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let game = viewModel.game {
                GameInfoHeaderView(game: game)
            }

            Picker("", selection: $selectedTab) {
                ForEach(DetailTab.allCases, id: \.self) { tab in
                    Label(tab.rawValue, systemImage: tab.icon).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, 20)
            .padding(.vertical, 12)

            // Source: P2-01 — 删除冗余 TabView 双重导航，仅保留 Segmented Picker
            Group {
                if selectedTab == .solutions {
                    CompatibilitySolutionView(detailViewModel: viewModel)
                }
            }
            Group {
                if selectedTab == .performance {
                    PerformanceOptionView(detailViewModel: viewModel)
                }
            }
            Group {
                if selectedTab == .info {
                    LogAndActionView(detailViewModel: viewModel)
                }
            }
        }
        .frame(width: 550, height: 700)
        .task {
            if let gameId = initialGameId {
                await viewModel.loadGame(id: gameId)
            }
        }
    }
}

// MARK: - Game Info Header

struct GameInfoHeaderView: View {
    let game: Game

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(game.type.displayName)
                    .font(.title2)
                    .fontWeight(.bold)
                Text(game.type.englishName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.top, 20)
        .padding(.bottom, 8)
    }
}
