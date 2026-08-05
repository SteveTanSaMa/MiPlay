//
//  ContentView.swift
//  MiPlay
//
//  Created by Steve Tan on 2026/6/20.
//

import SwiftUI

struct ContentView: View {
    private let settingsStore: SettingsStore
    private let updateManager: UpdateManager

    private let gameManager: GameManager
    private let wineManager: WineManager
    private let settingsViewModel: SettingsViewModel
    private let launchService: LaunchService
    private let libraryViewModel: LibraryViewModel

    init() {
        let baseDir = Self.setupDirectories()
        let gameManager = GameManager(gamesDirectory: baseDir.appendingPathComponent("Games"))
        let wineManager = WineManager(runtimeDirectory: baseDir.appendingPathComponent("Runtime"))

        self.gameManager = gameManager
        self.wineManager = wineManager

        let settingsStore = SettingsStore()
        let updateManager = UpdateManager()
        self.settingsStore = settingsStore
        self.updateManager = updateManager

        let launchService = LaunchService(gameManager: gameManager, wineManager: wineManager)
        self.launchService = launchService

        settingsViewModel = SettingsViewModel(
            settingsStore: settingsStore,
            gameManager: gameManager,
            wineManager: wineManager,
            updateManager: updateManager
        )

        libraryViewModel = LibraryViewModel(
            gameManager: gameManager,
            wineManager: wineManager,
            launchService: launchService
        )
    }

    var body: some View {
        LibraryView(viewModel: libraryViewModel, settingsViewModel: settingsViewModel)
            .task {
                wineManager.loadInstalledVersions()
                settingsStore.loadSettings()
                await settingsViewModel.loadSettings()
                updateManager.configure(version: Bundle.main.appVersion)
            }
    }

    private static func setupDirectories() -> URL {
        let urls = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        let baseDir = urls[0].appendingPathComponent("MiPlay", isDirectory: true)

        let dirs = [
            baseDir,
            baseDir.appendingPathComponent("Games"),
            baseDir.appendingPathComponent("Runtime"),
            baseDir.appendingPathComponent("Runtime/Versions"),
            baseDir.appendingPathComponent("Runtime/Prefixes"),
            baseDir.appendingPathComponent("Configs"),
            baseDir.appendingPathComponent("Downloads"),
        ]

        for dir in dirs {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }

        return baseDir
    }
}
