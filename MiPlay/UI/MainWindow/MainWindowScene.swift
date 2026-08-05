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

    var body: some Scene {
        WindowGroup(id: "main") {
            MainWindowContentView(
                libraryViewModel: libraryViewModel
            )
            .frame(width: 1280, height: 688)
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
    @Environment(\.openWindow) private var openWindow
    /// 游戏库为空时默认选中的占位游戏类型
    // Source: UI Design → UI-11/UI-12 — 材质按钮 + hover 效果
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
            Color.clear
                .ignoresSafeArea()
            // 沉浸式背景
            // Source: UI/UX Review → UX-16 — 视图切换动画
            BackgroundView(
                gameType: effectiveGameType,
                media: libraryViewModel.backgroundMedia
            )
            .accessibilityHidden(true)
            .transition(.opacity)
            .animation(.easeInOut(duration: 0.4), value: effectiveGameType)

            if libraryViewModel.backgroundGroups.count > 1 {
                VStack(spacing: 6) {
                    HStack(spacing: 10) {
                        ForEach(libraryViewModel.backgroundGroups) { group in
                            BackgroundGroupButton(
                                groupID: group.groupID,
                                isSelected: group.groupID == libraryViewModel.selectedBackgroundGroupID
                            ) {
                                Task { await libraryViewModel.selectBackgroundGroup(id: group.groupID) }
                            }
                        }
                    }
                    if let error = libraryViewModel.backgroundGroupError {
                        Text(error)
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityLabel("背景组切换失败")
                            .accessibilityValue(error)
                    }
                }
                .padding(.top, 18)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                .accessibilityElement(children: .contain)
                .accessibilityLabel("背景组选择")
            }

            // 前景内容
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
                        onRemoveGame: { gameId in Task { await libraryViewModel.removeGame(id: gameId) } },
                        onLocateGame: { gameType in locateGame(type: gameType) },
                        onPreload: { gameType in
                            Task { await libraryViewModel.preloadMedia(for: gameType.rawValue) }
                        }
                    )
                    .frame(width: 76)

                    Spacer()

                    // Source: 用户反馈 — 底部布局修正
                    VStack(alignment: .trailing, spacing: 10) {
                        MainTaskFeedbackView(
                            game: libraryViewModel.selectedGame,
                            progress: libraryViewModel.launchProgress,
                            recovery: libraryViewModel.recoveryRecords.first
                        ) { recordID in
                            Task { await libraryViewModel.retryProcessExitRecovery(recordID: recordID) }
                        }

                        PrimaryActionButton(
                            state: libraryViewModel.primaryButtonState,
                            action: {
                                guard let game = libraryViewModel.selectedGame else { return }
                                if case .enabled(_, let action) = libraryViewModel.primaryButtonState, action == .locate {
                                    locateGame(type: game.type)
                                } else if case .enabled(_, let action) = libraryViewModel.primaryButtonState, action == .viewFix {
                                    // Source: P1-011 — LaunchFailed 修复方案入口
                                    openWindow(id: "game-detail", value: game.id)
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

            // Loading 覆盖层（初始化中或素材加载中，阻断交互）
            // Source: 用户反馈 — 遮罩层不可见：initialize() 中 loading 状态持续过短
            if libraryViewModel.shouldShowMediaLoadingOverlay {
                MediaLoadingOverlay()
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

    /// 定位游戏：直接弹 NSOpenPanel 选择 .exe，跳过类型选择界面
    private func locateGame(type: GameType) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "选择 \(type.displayName) 的游戏可执行文件或安装目录"

        // Source: 用户反馈 — NSOpenPanel 居中于主窗口
        if let mainWindow = NSApp.mainWindow {
            let center = CGPoint(x: mainWindow.frame.midX - 320, y: mainWindow.frame.midY - 120)
            panel.setFrameOrigin(center)
        }

        guard panel.runModal() == .OK, let url = panel.url else { return }

        Task {
            await libraryViewModel.locateGame(type: type, selectedURL: url)
        }
    }

}

private struct BackgroundGroupButton: View {
    let groupID: String
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(isSelected ? Color.primary : Color.secondary.opacity(0.55))
                .frame(width: 10, height: 10)
        }
        .buttonStyle(.plain)
        .frame(width: 24, height: 24)
        .contentShape(Rectangle())
        .accessibilityLabel("背景组 \(groupID)")
        .accessibilityValue(isSelected ? "当前选中" : "未选中")
        .accessibilityHint("切换到此背景组")
        .help("切换背景组 \(groupID)")
    }
}

// Source: UI Design -> Accessibility Tree -> TaskFeedbackView
private struct MainTaskFeedbackView: View {
    let game: Game?
    let progress: LibraryViewModel.LaunchProgress?
    let recovery: RecoveryRecord?
    let retry: (String) -> Void

    var body: some View {
        VStack(alignment: .trailing, spacing: 6) {
            if let progress {
                HStack(spacing: 8) {
                    if let value = progress.progress {
                        ProgressView(value: value)
                            .frame(width: 90)
                    } else {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(progress.phase)
                        .font(.caption)
                        .foregroundStyle(.primary)
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(game?.type.displayName ?? "游戏")启动任务：\(progress.phase)")
                .accessibilityValue(progress.progress.map { "\(Int($0 * 100))%" } ?? "进行中")
            }

            if let recovery, recovery.resolvedAt == nil {
                HStack(spacing: 8) {
                    Label("状态需要恢复", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Button("重试恢复") {
                        retry(recovery.id)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)
                }
                .accessibilityElement(children: .contain)
                .accessibilityLabel("\(game?.type.displayName ?? "游戏")状态恢复失败")
                .accessibilityValue(recovery.detail)
            }
        }
        .accessibilityElement(children: .contain)
    }
}
