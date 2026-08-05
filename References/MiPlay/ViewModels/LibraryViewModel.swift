//
//  LibraryViewModel.swift
//  MiPlay
//
//  Created by Steve Tan on 2026/6/20.
//

import SwiftUI

@MainActor
@Observable
final class LibraryViewModel {
    private let gameManager: GameManager
    private let wineManager: WineManager
    private let launchService: LaunchService

    var games: [Game] = []
    var selectedGame: Game?
    var isLaunching = false
    var launchProgress: Double = 0
    var errorMessage: String?
    var showError = false

    // 文件选择器相关
    var showFilePicker = false
    var showUnrecognizedGamePicker = false
    var unrecognizedGamePath = ""

    init(gameManager: GameManager, wineManager: WineManager, launchService: LaunchService) {
        self.gameManager = gameManager
        self.wineManager = wineManager
        self.launchService = launchService
        self.games = []
    }

    func refreshGames() async {
        await gameManager.loadGames()
        games = await gameManager.games
    }

    func selectGame(_ game: Game) {
        selectedGame = game
    }

    // MARK: - 启动游戏

    func launchGame(_ game: Game, settings: AppSettings) async {
        guard !isLaunching else { return }
        isLaunching = true
        launchProgress = 0.0

        do {
            // 启动成功后立即释放 UI 锁定，不等待游戏退出
            try await launchService.launch(gameType: game.type, settings: settings)
            launchProgress = 1.0
            Logger.shared.info("\(game.type.displayName) 启动成功")
        } catch {
            errorMessage = error.localizedDescription
            showError = true
            Logger.shared.error("启动游戏失败: \(error.localizedDescription)")
        }

        isLaunching = false
    }

    // MARK: - 选择已安装的游戏目录

    /// 打开文件选择器，让用户选择游戏 .exe 所在的目录
    func showGameDirPicker() {
        showFilePicker = true
    }

    /// 用户选择了目录后的回调
    func didSelectGameDirectory(_ url: URL) async {
        let path = url.path

        // 如果用户选中的是 .exe 文件，取其目录
        let dirPath: String
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: path, isDirectory: &isDir) {
            dirPath = isDir.boolValue ? path : url.deletingLastPathComponent().path
        } else {
            dirPath = url.deletingLastPathComponent().path
        }

        // 自动检测游戏类型
        if let detectedType = await gameManager.detectGame(at: dirPath) {
            await gameManager.addGame(detectedType, at: dirPath)
            if let version = await gameManager.detectGameVersion(for: detectedType) {
                Logger.shared.info("检测到 \(detectedType.displayName) v\(version)")
            }
            await gameManager.saveGames()
            await refreshGames()
        } else {
            // 无法自动识别，弹出选择器让用户手动指定
            unrecognizedGamePath = dirPath
            showUnrecognizedGamePicker = true
        }
    }

    /// 用户手动指定目录对应的游戏类型
    func assignGameType(_ type: GameType) async {
        let path = unrecognizedGamePath
        guard !path.isEmpty else { return }
        await gameManager.addGame(type, at: path)
        await gameManager.saveGames()
        await refreshGames()
        showUnrecognizedGamePicker = false
        unrecognizedGamePath = ""
    }

    func cancelAssignGameType() {
        showUnrecognizedGamePicker = false
        unrecognizedGamePath = ""
    }

    // MARK: - 文件夹快捷打开

    func openGameFolder(for game: Game) {
        guard let path = game.installPath else { return }
        NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
    }

    func openScreenshotFolder(for game: Game) {
        Task {
            guard let path = await gameManager.screenshotDirectory(for: game.type) else { return }
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
        }
    }

    // MARK: - 管理游戏

    func removeGame(_ type: GameType) async {
        await gameManager.removeGame(type)
        await gameManager.saveGames()
        await refreshGames()
    }
}
