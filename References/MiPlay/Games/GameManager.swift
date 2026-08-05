//
//  GameManager.swift
//  MiPlay
//
//  Created by Steve Tan on 2026/6/20.
//

import Foundation

actor GameManager {
    enum GameError: LocalizedError {
        case notInstalled(GameType)
        case installPathNotFound(GameType)
        case alreadyInstalled(GameType)
        case launchFailed(String)

        var errorDescription: String? {
            switch self {
            case .notInstalled(let game): return "\(game.displayName) 未安装"
            case .installPathNotFound(let game): return "\(game.displayName) 安装路径未找到"
            case .alreadyInstalled(let game): return "\(game.displayName) 已安装"
            case .launchFailed(let detail): return "启动失败: \(detail)"
            }
        }
    }

    private let fileManager = FileManager.default
    private let gamesDirectory: URL

    var games: [Game] = []

    init(gamesDirectory: URL) {
        self.gamesDirectory = gamesDirectory
        loadGames()
    }

    // MARK: - 游戏加载

    func loadGames() {
        do {
            let gamesFile = gamesDirectory.appendingPathComponent("games.json")
            if fileManager.fileExists(atPath: gamesFile.path) {
                let data = try Data(contentsOf: gamesFile)
                let decoded = try JSONDecoder().decode([Game].self, from: data)
                games = decoded
                for i in games.indices {
                    if let path = games[i].installPath {
                        games[i].installStatus = fileManager.fileExists(atPath: path) ? .installed : .notInstalled
                    } else {
                        games[i].installStatus = .notInstalled
                    }
                }
                return
            }
        } catch {
            Logger.shared.error("加载游戏列表失败: \(error.localizedDescription)")
        }

        games = GameType.allCases.map { Game.empty(for: $0) }
    }

    func saveGames() async {
        do {
            let gamesFile = gamesDirectory.appendingPathComponent("games.json")
            let data = try JSONEncoder().encode(games)
            try data.write(to: gamesFile, options: .atomic)
        } catch {
            Logger.shared.error("保存游戏列表失败: \(error.localizedDescription)")
        }
    }

    // MARK: - 游戏检测

    func detectGame(at path: String) -> GameType? {
        let contents: [String]
        do {
            contents = try fileManager.contentsOfDirectory(atPath: path)
        } catch {
            return nil
        }

        if contents.contains("GenshinImpact.exe") ||
           contents.contains(where: { $0.contains("GenshinImpact") }) ||
           fileManager.fileExists(atPath: "\(path)/Genshin Impact Game/GenshinImpact.exe") {
            return .genshinImpact
        }
        if contents.contains("StarRail.exe") ||
           contents.contains("StarRail_Data") {
            return .starRail
        }
        if contents.contains("ZenlessZoneZero.exe") ||
           contents.contains("ZenlessZoneZero_Data") {
            return .zenlessZoneZero
        }

        return nil
    }

    func addGame(_ type: GameType, at path: String) {
        if let idx = games.firstIndex(where: { $0.type == type }) {
            games[idx].installPath = path
            games[idx].installStatus = .installed
        } else {
            var game = Game.empty(for: type)
            game.installPath = path
            game.installStatus = .installed
            games.append(game)
        }
    }

    func removeGame(_ type: GameType) {
        if let idx = games.firstIndex(where: { $0.type == type }) {
            games[idx].installPath = nil
            games[idx].installStatus = .notInstalled
            games[idx].version = nil
        }
    }

    // MARK: - 路径查询

    func gameInstallPath(for type: GameType) -> String? {
        games.first(where: { $0.type == type })?.installPath
    }

    func gameExecutablePath(for type: GameType) -> String? {
        guard let installPath = gameInstallPath(for: type) else { return nil }

        switch type {
        case .genshinImpact:
            let paths = [
                "\(installPath)/Genshin Impact Game/GenshinImpact.exe",
                "\(installPath)/GenshinImpact.exe"
            ]
            return paths.first { fileManager.fileExists(atPath: $0) }
        case .starRail:
            return "\(installPath)/StarRail.exe"
        case .zenlessZoneZero:
            return "\(installPath)/ZenlessZoneZero.exe"
        }
    }

    func screenshotDirectory(for type: GameType) -> String? {
        guard let installPath = gameInstallPath(for: type) else { return nil }

        switch type {
        case .genshinImpact:
            return "\(installPath)/Genshin Impact Game/Screenshots"
        case .starRail:
            return "\(installPath)/Screenshots"
        case .zenlessZoneZero:
            return "\(installPath)/Screenshots"
        }
    }

    // MARK: - 版本检测

    func detectGameVersion(for type: GameType) async -> String? {
        guard let installPath = gameInstallPath(for: type) else { return nil }
        return Self.gameVersion(from: installPath, gameType: type)
    }

    static func gameVersion(from installPath: String, gameType: GameType) -> String? {
        let fm = FileManager.default
        let dataDir: String

        switch gameType {
        case .genshinImpact:
            dataDir = "\(installPath)/Genshin Impact Game"
        case .starRail:
            dataDir = installPath
        case .zenlessZoneZero:
            dataDir = installPath
        }

        let pkgVersionPath = "\(dataDir)/pkg_version"
        if fm.fileExists(atPath: pkgVersionPath),
           let content = try? String(contentsOfFile: pkgVersionPath) {
            for line in content.components(separatedBy: .newlines) {
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                if !trimmed.isEmpty {
                    return trimmed
                }
            }
        }

        let configPath = "\(dataDir)/config.ini"
        if fm.fileExists(atPath: configPath),
           let content = try? String(contentsOfFile: configPath) {
            for line in content.components(separatedBy: .newlines) {
                if line.hasPrefix("game_version=") {
                    return String(line.dropFirst("game_version=".count)).trimmingCharacters(in: .whitespaces)
                }
            }
        }

        return nil
    }

    func isInstalled(_ type: GameType) -> Bool {
        games.first(where: { $0.type == type })?.installStatus == .installed
    }
}
