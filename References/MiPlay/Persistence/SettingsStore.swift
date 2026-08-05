//
//  SettingsStore.swift
//  MiPlay
//
//  Created by Steve Tan on 2026/6/20.
//

import Foundation

actor SettingsStore {
    enum StoreError: LocalizedError {
        case loadFailed(String)
        case saveFailed(String)

        var errorDescription: String? {
            switch self {
            case .loadFailed(let detail): return "加载设置失败: \(detail)"
            case .saveFailed(let detail): return "保存设置失败: \(detail)"
            }
        }
    }

    private let fileManager = FileManager.default
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    var settings: AppSettings = .default
    var games: [Game] = []

    private var settingsURL: URL {
        applicationSupportDirectory.appendingPathComponent("settings.json")
    }

    private var gamesURL: URL {
        applicationSupportDirectory.appendingPathComponent("games.json")
    }

    private var applicationSupportDirectory: URL {
        let urls = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        let dir = urls[0].appendingPathComponent("MiPlay", isDirectory: true)
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    func loadSettings() {
        guard fileManager.fileExists(atPath: settingsURL.path) else {
            settings = .default
            return
        }

        do {
            let data = try Data(contentsOf: settingsURL)
            settings = try decoder.decode(AppSettings.self, from: data)
        } catch {
            Logger.shared.error("加载设置失败: \(error.localizedDescription)")
            settings = .default
        }
    }

    func saveSettings() throws {
        encoder.outputFormatting = .prettyPrinted
        let data = try encoder.encode(settings)
        try data.write(to: settingsURL, options: .atomic)
    }

    func loadGames() {
        guard fileManager.fileExists(atPath: gamesURL.path) else { return }

        do {
            let data = try Data(contentsOf: gamesURL)
            games = try decoder.decode([Game].self, from: data)
        } catch {
            Logger.shared.error("加载游戏列表失败: \(error.localizedDescription)")
            games = []
        }
    }

    func saveGames() throws {
        encoder.outputFormatting = .prettyPrinted
        let data = try encoder.encode(games)
        try data.write(to: gamesURL, options: .atomic)
    }

    func resetSettings() {
        settings = .default
        try? saveSettings()
    }

    func updateSettings(_ newSettings: AppSettings) {
        settings = newSettings
    }
}
