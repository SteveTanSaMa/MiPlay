//
//  MainWindowScene.swift
//  MiPlay
//
//  Created by Steve Tan on 2026/7/7.
//

import SwiftUI

// Source: UI Design → Screen Inventory → 主界面
// Source: ADR 020 — 主窗口简化（移除 GameInformationView、设置 overlay、详情 sheet）

/// 主窗口场景。MiPlay 的核心交互场景。
struct MainWindowScene: Scene {
    let libraryViewModel: LibraryViewModel
    let newsProvider: HoYoPlayNewsProvider
    let newsImageCache: NewsBannerImageCache
    let registerWindow: (NSWindow) -> Void

    var body: some Scene {
        WindowGroup(id: "main") {
            MainWindowContentView(
                libraryViewModel: libraryViewModel,
                newsProvider: newsProvider,
                newsImageCache: newsImageCache
            )
            .frame(width: 1280, height: 688)
            .background(WindowRegistrar(registerWindow: registerWindow))
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1280, height: 688)
        // Source: UI-9 — 窗口固定不可缩放
        .windowResizability(.contentSize)

    }
}

/// 主窗口内容视图
struct MainWindowContentView: View {
    // Source: Code Review → CR-3 — @State 语义误用
    let libraryViewModel: LibraryViewModel
    let newsProvider: HoYoPlayNewsProvider
    let newsImageCache: NewsBannerImageCache
    /// 游戏库为空时默认选中的占位游戏类型
    // Source: UI Design → UI-11/UI-12 — 材质按钮 + hover 效果
    @AppStorage("showGameNews") private var showGameNews = true
    @State private var selectedPlaceholderType: GameType? = .genshinImpact

    /// 当前有效的游戏类型（真实游戏优先，否则用占位选择）
    private var effectiveGameType: GameType? {
        if let game = libraryViewModel.selectedGame {
            return game.type
        }
        return selectedPlaceholderType
    }

    var body: some View {
        mainContent
            .task { await libraryViewModel.initialize() }
            .onChange(of: selectedPlaceholderType) { _, newType in
                guard let type = newType, libraryViewModel.selectedGame == nil else { return }
                Task { await libraryViewModel.loadMediaForPlaceholder(type: type) }
            }
    }

    // MARK: - Main Layout

    /// 主内容区域：导航栏在左下角，内容居中
    private var mainContent: some View {
        ZStack {
            // 沉浸式背景
            // Source: UI/UX Review → UX-16 — 视图切换动画
            BackgroundView(
                gameType: effectiveGameType,
                media: libraryViewModel.backgroundMedia
            )
            .accessibilityHidden(true)

            // 前景内容
            GeometryReader { geometry in
                VStack(spacing: 0) {
                    Spacer()

                    // 底部区域：左侧导航栏 + 中央操作按钮
                    HStack(alignment: .bottom) {
                        // 左下角：游戏选择栏
                        GameSelectionRailView(
                            games: libraryViewModel.games,
                            selectedId: Binding(
                                get: { libraryViewModel.selectedGameId },
                                set: { newId in if let id = newId { libraryViewModel.selectGame(id: id) } }
                            ),
                            selectedPlaceholderType: $selectedPlaceholderType,
                            onLocateGame: { gameType in locateGame(type: gameType) },
                            onPreload: { gameType in
                                Task { await libraryViewModel.preloadMedia(for: gameType.rawValue) }
                            },
                            iconURLs: libraryViewModel.gameIconURLs
                        )
                        .frame(width: 76)

                        if showGameNews, let game = effectiveGameType {
                            GameNewsPanel(game: game, provider: newsProvider, imageCache: newsImageCache)
                                .frame(width: min(340, geometry.size.width * 0.27))
                                .padding(.leading, 18)
                        }

                        Spacer()

                        // Source: 用户反馈 — 底部布局修正
                        VStack(alignment: .trailing, spacing: 10) {
                            MainTaskFeedbackView(
                                game: libraryViewModel.selectedGame,
                                progress: libraryViewModel.launchProgress,
                                recovery: libraryViewModel.recoveryRecords.first {
                                    $0.resolvedAt == nil && $0.gameID == libraryViewModel.selectedGameId
                                }
                            ) { recordID in
                                Task { await libraryViewModel.retryProcessExitRecovery(recordID: recordID) }
                            }

                            PrimaryActionButton(
                                state: libraryViewModel.primaryButtonState,
                                action: {
                                    guard let game = libraryViewModel.selectedGame else { return }
                                    if case .enabled(_, let action) = libraryViewModel.primaryButtonState, action == .locate {
                                        locateGame(type: game.type)
                                    } else {
                                        Task { await libraryViewModel.performPrimaryAction() }
                                    }
                                }
                            )
                        }
                    }
                    .padding(.horizontal, 30)
                    .padding(.bottom, 48)
                }
            }
            .disabled(libraryViewModel.isStartupPreparationVisible)
            .accessibilityHidden(libraryViewModel.isStartupPreparationVisible)

            // 启动准备全屏遮罩（Wine 环境 → 背景素材，阻断交互）
            // Source: 用户指令 — 遮罩由 startupPhase 驱动，从首帧起覆盖主页
            // （修复冷启动时遮罩不显示、需切换游戏才出现的问题）
            if libraryViewModel.isStartupPreparationVisible {
                StartupPreparationOverlay(
                    phase: libraryViewModel.startupPhase,
                    detail: libraryViewModel.startupDetail,
                    progress: libraryViewModel.startupProgress,
                    failure: libraryViewModel.startupFailure
                ) {
                    Task { await libraryViewModel.retryStartupPreparation() }
                }
            }
        }
        .alert("错误", isPresented: .init(
            get: { libraryViewModel.errorMessage != nil },
            set: { if !$0 { libraryViewModel.clearError() } }
        )) {
            Button("确定") { libraryViewModel.clearError() }
        } message: {
            Text(libraryViewModel.errorMessage ?? "")
        }
    }

    /// 定位游戏：弹 NSOpenPanel 选择游戏安装目录，跳过类型选择界面。
    private func locateGame(type: GameType) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "选择 \(type.displayName) 的游戏安装目录"

        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            Task { await libraryViewModel.locateGame(type: type, selectedURL: url) }
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }
}
