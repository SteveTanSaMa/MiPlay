//
//  LibraryView.swift
//  MiPlay
//
//  Created by Steve Tan on 2026/6/20.
//

import SwiftUI
import UniformTypeIdentifiers

/// 主页：沉浸式背景 + 左下角游戏栏 + 右下角操作按钮
struct LibraryView: View {
    @State private var viewModel: LibraryViewModel
    private let settingsViewModel: SettingsViewModel

    // MARK: - 主页状态

    @State private var selectedGame: GameType = .genshinImpact
    @State private var backgroundAssets: [GameType: GameBackgroundAssets] = [:]
    @State private var localVideoPaths: [GameType: URL] = [:]
    @State private var localThemePaths: [GameType: URL] = [:]
    @State private var backgroundService = BackgroundService()

    // 自定义背景
    @State private var useCustomBackground = false
    @State private var customBackgroundImage: NSImage?
    @State private var backgroundFillMode: BackgroundFillMode = .fill

    // 转码状态
    @State private var isPreparing = true
    @State private var preparingMessage = "正在准备素材..."

    // 设置页导航
    @State private var showSettings = false

    init(viewModel: LibraryViewModel, settingsViewModel: SettingsViewModel) {
        self.viewModel = viewModel
        self.settingsViewModel = settingsViewModel
    }

    var body: some View {
        ZStack {
            if isPreparing {
                // 准备阶段的过渡页
                preparingView
            } else {
                // 主界面
                mainContentView
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            await loadGameData()
            await prepareBackgrounds()
        }
        .onChange(of: selectedGame) { _, _ in
            updateSelectedGameInViewModel()
        }
        .alert("错误", isPresented: $viewModel.showError) {
            Button("确定", role: .cancel) {}
        } message: {
            Text(viewModel.errorMessage ?? "未知错误")
        }
        .fileImporter(
            isPresented: $viewModel.showFilePicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            Task {
                switch result {
                case .success(let urls):
                    if let url = urls.first {
                        await viewModel.didSelectGameDirectory(url)
                    }
                case .failure: break
                }
            }
        }
        .sheet(isPresented: $viewModel.showUnrecognizedGamePicker) {
            unrecognizedGameSheet
        }
        .sheet(isPresented: $showSettings) {
            SettingsView(viewModel: settingsViewModel)
                .frame(width: 800, height: 520)
        }
    }

    // MARK: - 过渡页

    private var preparingView: some View {
        LoadingOverlay(message: preparingMessage)
    }

    // MARK: - 主界面

    private var mainContentView: some View {
        ZStack {
            // 层1: 视频/图片背景
            backgroundLayer

            // 层2: 底部渐变
            ReadabilityOverlay()

            // 层3: 游戏栏
            GameRailView(
                selectedGame: $selectedGame,
                games: GameType.allCases
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
            .padding(.leading, 30)
            .padding(.bottom, 50)

            // 层4: 右上角按钮组
            topRightButtons
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                .padding(.top, 20)
                .padding(.trailing, 20)

            // 层5: 右下角主按钮
            mainActionButton
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                .padding(.trailing, 30)
                .padding(.bottom, 50)
        }
    }

    // MARK: - 背景图层

    private var backgroundLayer: some View {
        BackgroundVideoView(
            assets: backgroundAssets[selectedGame],
            useCustomImage: useCustomBackground,
            customImage: customBackgroundImage,
            fillMode: backgroundFillMode,
            localVideoURL: localVideoPaths[selectedGame],
            localThemeURL: localThemePaths[selectedGame]
        )
        .ignoresSafeArea()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .id(selectedGame)
        .animation(.easeInOut(duration: 0.5), value: selectedGame)
    }

    // MARK: - 右上角按钮

    private var topRightButtons: some View {
        settingsButton
    }

    private var settingsButton: some View {
        Button {
            showSettings = true
        } label: {
            Image(systemName: "gearshape")
                .font(.system(size: 20, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
                .frame(width: 44, height: 44)
        }
        .buttonStyle(.plain)
        .buttonGlass()
        .help("设置")
    }

    // MARK: - 右下角主按钮

    private var mainActionButton: some View {
        let game = viewModel.games.first(where: { $0.type == selectedGame })
        let status = game?.installStatus ?? .notInstalled
        let isLaunching = viewModel.isLaunching && viewModel.selectedGame?.type == selectedGame

        return Group {
            if isLaunching {
                ButtonLaunchingStateView()
            } else {
                Button {
                    handleMainAction(game: game)
                } label: {
                    Label(mainButtonText(for: status), systemImage: mainButtonIcon(for: status))
                        .font(.body)
                        .fontWeight(.semibold)
                        .frame(width: 160)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .tint(.white.opacity(0.2))
                .foregroundStyle(.white)
            }
        }
    }

    private func mainButtonText(for status: GameInstallStatus) -> String {
        switch status {
        case .notInstalled, .broken: return "安装游戏"
        case .downloading: return "下载中"
        case .installed: return "开始游戏"
        case .needsUpdate: return "更新游戏"
        }
    }

    private func mainButtonIcon(for status: GameInstallStatus) -> String {
        switch status {
        case .notInstalled, .broken: return "arrow.down.circle"
        case .downloading: return "arrow.triangle.2.circlepath"
        case .installed: return "play.fill"
        case .needsUpdate: return "arrow.up.circle"
        }
    }

    private func handleMainAction(game: Game?) {
        guard let game = game else { viewModel.showGameDirPicker(); return }
        switch game.installStatus {
        case .installed:
            Task {
                let settings = await settingsViewModel.toAppSettings()
                await viewModel.launchGame(game, settings: settings)
            }
        case .notInstalled, .downloading, .needsUpdate, .broken:
            viewModel.showGameDirPicker()
        }
    }

    // MARK: - 数据加载

    private func loadGameData() async {
        await viewModel.refreshGames()
        updateSelectedGameInViewModel()
    }

    /// 预加载素材并转码
    private func prepareBackgrounds() async {
        isPreparing = true

        // 1. 获取素材 URL
        preparingMessage = "正在获取背景素材..."
        let assets = await backgroundService.preloadAll()
        for (game, asset) in assets {
            backgroundAssets[game] = asset
        }

        // 2. 为当前选中游戏准备视频（下载 + 转码）和 theme
        preparingMessage = "正在准备视频素材..."
        if let path = try? await backgroundService.localVideoPath(for: selectedGame) {
            localVideoPaths[selectedGame] = path
        }
        if let themePath = await backgroundService.localThemePath(for: selectedGame) {
            localThemePaths[selectedGame] = themePath
        }

        // 3. 后台预转码其他游戏
        Task {
            for game in GameType.allCases where game != selectedGame {
                if let path = try? await backgroundService.localVideoPath(for: game) {
                    await MainActor.run { localVideoPaths[game] = path }
                }
                if let themePath = await backgroundService.localThemePath(for: game) {
                    await MainActor.run { localThemePaths[game] = themePath }
                }
            }
        }

        isPreparing = false
    }

    private func updateSelectedGameInViewModel() {
        if let game = viewModel.games.first(where: { $0.type == selectedGame }) {
            viewModel.selectGame(game)
        }
    }

    // MARK: - 未识别游戏类型 Sheet

    private var unrecognizedGameSheet: some View {
        VStack(spacing: 20) {
            Image(systemName: "questionmark.folder").font(.system(size: 40)).foregroundStyle(.secondary)
            Text("未识别游戏类型").font(.headline)
            Text("无法自动识别所选文件夹中的游戏，\n请手动选择：")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            VStack(spacing: 8) {
                ForEach(GameType.allCases) { type in
                    Button {
                        Task { await viewModel.assignGameType(type) }
                    } label: {
                        HStack {
                            Image(systemName: type.placeholderIcon).foregroundStyle(type.themeColor).font(.title3)
                            Text(type.displayName)
                            Spacer()
                            Text(type.englishName).foregroundStyle(.secondary).font(.caption)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 10)
                        .background(Color(nsColor: .controlBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                    }
                    .buttonStyle(.plain)
                }
            }
            Button("取消", role: .cancel) { viewModel.cancelAssignGameType() }
                .buttonStyle(.bordered).keyboardShortcut(.escape)
        }
        .padding(30).frame(width: 340)
    }
}
