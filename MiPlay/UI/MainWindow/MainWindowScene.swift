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
    let isUnitTestHost: Bool
    let registerWindow: (NSWindow) -> Void

    var body: some Scene {
        WindowGroup(id: "main") {
            Group {
                if isUnitTestHost {
                    Color.clear
                } else {
                    MainWindowContentView(
                        libraryViewModel: libraryViewModel,
                        newsProvider: newsProvider,
                        newsImageCache: newsImageCache
                    )
                }
            }
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
    @State private var isMainlandConfirmationPresented = false
    @State private var mainlandUpdateGame: Game?
    @State private var isConfirmingDownloadResume = false
    @State private var isConfirmingPredownload = false

    /// 当前有效的游戏类型（真实游戏优先，否则用占位选择）
    private var effectiveGameType: GameType? {
        if let game = libraryViewModel.selectedGame {
            return game.type
        }
        if let id = libraryViewModel.selectedGameId, let type = GameType(rawValue: id) {
            return type
        }
        return selectedPlaceholderType
    }

    private var effectivePrimaryButtonState: LibraryViewModel.PrimaryButtonState {
        if libraryViewModel.selectedGame == nil, effectiveGameType != nil {
            return .enabled(label: "定位游戏", action: .locate)
        }
        return libraryViewModel.primaryButtonState
    }

    var body: some View {
        mainContent
            .task { await libraryViewModel.initialize() }
            .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
                Task { await libraryViewModel.refreshUpdatesOnActivation() }
            }
            .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)) { _ in
                guard NSApp.isActive else { return }
                Task { await libraryViewModel.refreshUpdatesOnActivation() }
            }
            .onChange(of: selectedPlaceholderType) { _, newType in
                guard let type = newType, libraryViewModel.selectedGame == nil, libraryViewModel.selectedGameId == nil else { return }
                Task { await libraryViewModel.loadMediaForPlaceholder(type: type) }
            }
            .onChange(of: libraryViewModel.selectedGameId) { _, id in
                guard libraryViewModel.selectedGame == nil, let id, let type = GameType(rawValue: id) else { return }
                Task { await libraryViewModel.loadMediaForPlaceholder(type: type) }
            }
            .confirmationDialog(
                "确认国服客户端", isPresented: $isMainlandConfirmationPresented,
                titleVisibility: .visible, presenting: mainlandUpdateGame
            ) { game in
                Button(isConfirmingPredownload ? "确认是国服，继续预下载" : "确认是国服，继续更新") {
                    Task {
                        if isConfirmingDownloadResume {
                            await libraryViewModel.resumeGameDownload(for: game.id, confirmedMainland: true,
                                                                     confirmedLocationBookmark: game.location?.bookmarkData)
                        } else if isConfirmingPredownload {
                            await libraryViewModel.startPredownload(for: game.id, confirmedMainland: true,
                                                                   confirmedLocationBookmark: game.location?.bookmarkData)
                        } else {
                            await libraryViewModel.updateGame(game: game, confirmedMainland: true,
                                                              confirmedLocationBookmark: game.location?.bookmarkData)
                        }
                    }
                }
                Button("取消", role: .cancel) {}
            } message: { target in
                if isConfirmingPredownload {
                    Text("目标目录：\(target.installPath ?? "路径未知")\n\n此游戏目录的区服尚未确认。预下载会使用国服资源并写入独立缓存，请仅在确认这是国服官方客户端时继续。")
                } else {
                    Text("目标目录：\(target.installPath ?? "路径未知")\n\n此游戏目录的区服尚未确认。继续将使用国服官方资源更新；如果此目录属于国际服，可能覆盖为国服文件。请仅在确认这是国服官方客户端时继续。")
                }
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
                    GlassEffectContainer(spacing: 8) {
                        HStack(alignment: .bottom) {
                            // 左下角：游戏选择栏
                            GameSelectionRailView(
                                games: libraryViewModel.games,
                                selectedId: Binding(
                                    get: { libraryViewModel.selectedGameId },
                                    set: { newId in if let id = newId { libraryViewModel.selectGame(id: id) } }
                                ),
                                selectedPlaceholderType: $selectedPlaceholderType,
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
                                if let game = libraryViewModel.selectedGame,
                                   let task = libraryViewModel.gameDownloadTasks[game.id],
                                   GameDownloadPresentation.isActive(task) || libraryViewModel.canResumeGameDownload(for: game.id)
                                    || (task.type == .gamePredownload && task.state == .completed
                                        && task.context["predownloadVersion"] == libraryViewModel.gamePredownloadVersions[game.id]) {
                                    GameDownloadTaskView(
                                        task: task,
                                        download: libraryViewModel.gameDownloadProgress[game.id],
                                        resultConfirmed: GameDownloadPresentation.resultConfirmed(for: task, game: game),
                                        resume: libraryViewModel.canResumeGameDownload(for: game.id) ? { requestDownloadResume(for: game) } : nil
                                    ) {
                                        Task { await libraryViewModel.cancelGameDownload(for: game.id) }
                                    }
                                    .padding(12)
                                    .frame(width: 280)
                                    .modifier(DarkGlassSurface(interactive: false))
                                }

                                MainTaskFeedbackView(
                                    game: libraryViewModel.selectedGame,
                                    progress: libraryViewModel.launchProgress,
                                    recovery: libraryViewModel.recoveryRecords.first {
                                        $0.resolvedAt == nil && $0.gameID == libraryViewModel.selectedGameId
                                    }
                                ) { recordID in
                                    Task { await libraryViewModel.retryProcessExitRecovery(recordID: recordID) }
                                }

                                HStack(spacing: 10) {
                                    if let game = libraryViewModel.selectedGame,
                                       let version = libraryViewModel.availablePredownloadVersion(for: game.id),
                                       game.state != .notInstalled, game.state != .gameUpdating {
                                        Button {
                                            requestPredownload(for: game)
                                        } label: {
                                            Label("预下载 \(version)", systemImage: "arrow.down.circle")
                                                .font(.headline)
                                                .frame(width: 168, height: 64)
                                        }
                                        .buttonStyle(.borderless)
                                        .focusable()
                                        .foregroundStyle(libraryViewModel.canStartPredownload(for: game.id) ? .white : .white.opacity(0.7))
                                        .modifier(DarkGlassSurface(interactive: libraryViewModel.canStartPredownload(for: game.id)))
                                        .disabled(!libraryViewModel.canStartPredownload(for: game.id))
                                        .help("将未来版本缓存到游戏目录，不改变当前游戏。优先使用官方差分，必要时会回退到完整资源。")
                                    }
                                    if let type = effectiveGameType,
                                       libraryViewModel.selectedGame == nil || libraryViewModel.selectedGame?.state == .notInstalled {
                                        Button {
                                            chooseInstallationDirectory(for: type)
                                        } label: {
                                            Label(libraryViewModel.canResumeGameDownload(for: type.rawValue) ? "选择其他目录" : "下载国服", systemImage: "arrow.down.circle")
                                                .font(.headline)
                                                .frame(width: 152, height: 64)
                                        }
                                        .buttonStyle(.borderless)
                                        .focusable()
                                        .foregroundStyle(libraryViewModel.canInstallGame(for: type.rawValue) ? .white : .white.opacity(0.7))
                                        .modifier(DarkGlassSurface(interactive: libraryViewModel.canInstallGame(for: type.rawValue)))
                                        .disabled(!libraryViewModel.canInstallGame(for: type.rawValue))
                                        .help("选择目录下载并安装国服")
                                    }

                                    PrimaryActionButton(
                                        state: effectivePrimaryButtonState,
                                        action: {
                                            guard let game = libraryViewModel.selectedGame else {
                                                if let type = effectiveGameType { locateGame(type: type) }
                                                return
                                            }
                                            if case .enabled(_, let action) = libraryViewModel.primaryButtonState, action == .locate {
                                                locateGame(type: game.type)
                                            } else if case .enabled(_, let action) = libraryViewModel.primaryButtonState,
                                                      action == .update || action == .resumeDownload,
                                                      GameDownloadPresentation.mainlandEligibility(for: game) == .requiresConfirmation {
                                                mainlandUpdateGame = game
                                                isConfirmingDownloadResume = action == .resumeDownload
                                                isConfirmingPredownload = libraryViewModel.gameDownloadTasks[game.id]?.type == .gamePredownload && isConfirmingDownloadResume
                                                isMainlandConfirmationPresented = true
                                            } else {
                                                Task { await libraryViewModel.performPrimaryAction() }
                                            }
                                        }
                                    )
                                }
                            }
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

    private func requestDownloadResume(for game: Game) {
        let type = libraryViewModel.gameDownloadTasks[game.id]?.type
        if (type == .gameUpdate || type == .gamePredownload),
           GameDownloadPresentation.mainlandEligibility(for: game) == .requiresConfirmation {
            mainlandUpdateGame = game
            isConfirmingDownloadResume = true
            isConfirmingPredownload = type == .gamePredownload
            isMainlandConfirmationPresented = true
        } else {
            Task { await libraryViewModel.resumeGameDownload(for: game.id) }
        }
    }

    private func requestPredownload(for game: Game) {
        if GameDownloadPresentation.mainlandEligibility(for: game) == .requiresConfirmation {
            mainlandUpdateGame = game
            isConfirmingDownloadResume = false
            isConfirmingPredownload = true
            isMainlandConfirmationPresented = true
        } else {
            Task { await libraryViewModel.startPredownload(for: game.id) }
        }
    }

    private func chooseInstallationDirectory(for type: GameType) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "选择安装目录"
        panel.message = "选择用于安装「\(type.displayName)」国服的专用空文件夹，或此前中断下载的目录。"
        let completion: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return }
            Task { await libraryViewModel.installGame(type: type, selectedURL: url) }
        }
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
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
