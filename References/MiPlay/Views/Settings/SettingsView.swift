//
//  SettingsView.swift
//  MiPlay
//
//  Created by Steve Tan on 2026/6/20.
//

import SwiftUI
import UniformTypeIdentifiers

// MARK: - 导航项

private enum SettingsPane: String, CaseIterable {
    case general = "通用"
    case games = "游戏"
    case compatibility = "兼容性"
    case tools = "工具"
    case updates = "更新"
    case about = "关于"

    var icon: String {
        switch self {
        case .general: return "gearshape"
        case .games: return "gamecontroller"
        case .compatibility: return "wineglass"
        case .tools: return "wrench.and.screwdriver"
        case .updates: return "arrow.triangle.2.circlepath"
        case .about: return "info.circle"
        }
    }
}

// MARK: - 主视图

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var viewModel: SettingsViewModel
    @State private var selectedPane: SettingsPane = .general
    @State private var showWineVersions = false

    init(viewModel: SettingsViewModel) {
        self.viewModel = viewModel
    }

    var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, id: \.rawValue, selection: $selectedPane) { pane in
                Label(pane.rawValue, systemImage: pane.icon)
                    .tag(pane)
            }
            .listStyle(.sidebar)
            .frame(minWidth: 180)
            .navigationSplitViewColumnWidth(180)
        } detail: {
            detailView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(width: 800, height: 520)
        .onDisappear {
            Task { await viewModel.saveSettings() }
        }
        .overlay(alignment: .bottomTrailing) {
            Button("完成") {
                dismiss()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.trailing, 20)
            .padding(.bottom, 20)
        }
    }

    // MARK: - Detail

    @ViewBuilder
    private var detailView: some View {
        switch selectedPane {
        case .general: generalPane
        case .games: gamesPane
        case .compatibility: compatibilityPane
        case .tools: toolsPane
        case .updates: updatesPane
        case .about: aboutPane
        }
    }

    // MARK: - 通用

    private var generalPane: some View {
        Form {
            Section("通用") {
                Picker("启动器语言", selection: $viewModel.language) {
                    ForEach(AppLanguage.allCases, id: \.self) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                }

                Toggle("开机自启动", isOn: .constant(false))
                    .disabled(true)
                    .help("即将推出")

                Picker("主题", selection: .constant(0)) {
                    Text("浅色").tag(0)
                    Text("深色").tag(1)
                    Text("跟随系统").tag(2)
                }
                .disabled(true)
                .help("仅影响设置界面")
            }

            Section("背景设置") {
                ForEach(GameType.allCases) { game in
                    GameBackgroundRow(
                        game: game,
                        viewModel: viewModel
                    )
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - 游戏

    private var gamesPane: some View {
        Form {
            ForEach(GameType.allCases) { game in
                Section(game.displayName) {
                    SettingsPathRow(
                        title: "安装目录",
                        path: viewModel.gameInstallPath(for: game),
                        onOpen: { viewModel.openGameFolder(for: game) }
                    )

                    SettingsPathRow(
                        title: "截图目录",
                        path: viewModel.screenshotDirectory(for: game),
                        onOpen: { viewModel.openScreenshotFolder(for: game) }
                    )

                    PerGameSettingsRow(game: game, viewModel: viewModel)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - 兼容性

    private var compatibilityPane: some View {
        Form {
            Section("显示") {
                SettingsToggleRow(title: "Retina Mode", isOn: $viewModel.enableRetinaMode, help: "启用高分辨率渲染")
                SettingsToggleRow(title: "Metal HUD", isOn: $viewModel.enableMetalHUD, help: "显示 Metal 性能 HUD")
            }

            Section("输入") {
                SettingsToggleRow(title: "左 Control 映射到 Command", isOn: $viewModel.mapLeftControlToCommand, help: "将键盘左 Control 键映射为 Command 键")
            }

            Section("网络") {
                SettingsToggleRow(title: "启动修复（Hosts 屏蔽）", isOn: $viewModel.hostsBlockLaunch, help: "通过修改 hosts 文件屏蔽游戏启动时的验证")
            }

            Section("Wine") {
                DisclosureGroup(isExpanded: $showWineVersions) {
                    if viewModel.isLoadingWineVersions {
                        HStack {
                            Spacer()
                            ProgressView()
                                .scaleEffect(0.7)
                                .controlSize(.small)
                            Spacer()
                        }
                    } else if viewModel.remoteWineVersions.isEmpty {
                        HStack {
                            Text("未获取到版本列表")
                                .foregroundStyle(.secondary)
                            Button("刷新") {
                                Task { await viewModel.loadRemoteWineVersions() }
                            }
                            .buttonStyle(.link)
                        }
                    } else {
                        ForEach(viewModel.remoteWineVersions) { version in
                            WineVersionRow(version: version, viewModel: viewModel)
                        }
                    }
                } label: {
                    HStack {
                        Text("Wine 版本管理")
                        Spacer()
                        Text(viewModel.selectedWineVersion.isEmpty ? "未选择" : viewModel.selectedWineVersion)
                            .foregroundStyle(.secondary)
                            .font(.caption)
                    }
                }

                Button("重新执行 Wine 初始化") {
                    Task { await viewModel.reinitializeWine() }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - 工具

    private var toolsPane: some View {
        Form {
            Section("文件") {
                Button { viewModel.openLauncherFolder() }
                    label: { Label("打开启动器目录", systemImage: "folder") }
            }

            Section("辅助") {
                Button { viewModel.openWineShell() }
                    label: { Label("打开 Wine 命令行工具", systemImage: "terminal") }

                Button { }
                    label: { Label("检查文件完整性", systemImage: "checkmark.shield") }
                    .help("开发中")
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - 更新

    private var updatesPane: some View {
        Form {
            Section("更新") {
                Toggle("自动检查更新", isOn: .constant(true))

                HStack {
                    Button {
                        Task { await viewModel.checkForUpdates() }
                    } label: {
                        HStack {
                            Image(systemName: "arrow.triangle.2.circlepath")
                            Text("检查更新")
                            if viewModel.isCheckingUpdate {
                                ProgressView().scaleEffect(0.7).padding(.leading, 4)
                            }
                        }
                    }
                    .disabled(viewModel.isCheckingUpdate)

                    if viewModel.updateAvailable {
                        Text("有新版本可用")
                            .font(.caption)
                            .foregroundStyle(.blue)
                    }
                }

                HStack {
                    Text("当前版本")
                    Spacer()
                    Text(viewModel.appVersion)
                        .foregroundStyle(.secondary)
                }

                Picker("更新通道", selection: .constant(0)) {
                    Text("Stable").tag(0)
                    Text("Beta").tag(1)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: - 关于

    private var aboutPane: some View {
        Form {
            Section {
                HStack {
                    Spacer()
                    VStack(spacing: 8) {
                        Image(systemName: "square.stack.3d.up.fill")
                            .font(.system(size: 48))
                            .foregroundStyle(.tint)

                        Text("MiPlay")
                            .font(.largeTitle)
                            .fontWeight(.bold)

                        Text(viewModel.appVersion)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                }
            }

            Section {
                Link(destination: URL(string: "https://github.com/SteveTanSaMa/MiPlay")!) {
                    HStack {
                        Image(systemName: "link")
                        Text("GitHub")
                        Spacer()
                        Text("SteveTanSaMa/MiPlay")
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
            }

            Section("许可证") {
                Text("MIT License\n\nCopyright (c) 2025 Steve Tan\n\nPermission is hereby granted...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - GameBackgroundRow 已迁移到独立文件
// MARK: - PerGameSettingsRow 已迁移到独立文件
// MARK: - WineVersionRow 已迁移到独立文件
