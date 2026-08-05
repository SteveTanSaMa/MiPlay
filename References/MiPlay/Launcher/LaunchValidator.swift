//
//  LaunchValidator.swift
//  MiPlay
//
//  Created by Steve Tan on 2026/6/20.
//

import Foundation

actor LaunchValidator {
    enum ValidationError: LocalizedError {
        case gameNotInstalled(GameType)
        case executableNotFound(String)
        case wineVersionNotInstalled(String)
        case prefixNotInitialized(String)
        case dxmtNotAvailable

        var errorDescription: String? {
            switch self {
            case .gameNotInstalled(let game): return "\(game.displayName) 未安装"
            case .executableNotFound(let path): return "游戏可执行文件未找到: \(path)"
            case .wineVersionNotInstalled(let version): return "Wine \(version) 未安装"
            case .prefixNotInitialized(let name): return "Wine Prefix '\(name)' 未初始化"
            case .dxmtNotAvailable: return "DXMT 不可用"
            }
        }
    }

    struct ValidationResult {
        let isValid: Bool
        let errors: [ValidationError]

        static func success() -> ValidationResult {
            ValidationResult(isValid: true, errors: [])
        }

        static func failure(_ errors: [ValidationError]) -> ValidationResult {
            ValidationResult(isValid: false, errors: errors)
        }
    }

    private let fileManager = FileManager.default
    private let gameManager: GameManager
    private let wineManager: WineManager

    init(gameManager: GameManager, wineManager: WineManager) {
        self.gameManager = gameManager
        self.wineManager = wineManager
    }

    func validate(gameType: GameType, wineVersion: String? = nil, prefixName: String? = nil) async throws -> ValidationResult {
        var errors: [ValidationError] = []

        guard let installPath = await gameManager.gameInstallPath(for: gameType),
              fileManager.fileExists(atPath: installPath) else {
            errors.append(.gameNotInstalled(gameType))
            return .failure(errors)
        }

        if let executablePath = await gameManager.gameExecutablePath(for: gameType),
           !fileManager.fileExists(atPath: executablePath) {
            errors.append(.executableNotFound(executablePath))
        }

        if let wineVersion = wineVersion {
            let installedVersions = await wineManager.installedVersions
            let isInstalled = installedVersions.contains(where: { $0.version == wineVersion })
            if !isInstalled {
                errors.append(.wineVersionNotInstalled(wineVersion))
            }
        }

        if let prefixName = prefixName {
            let prefixPath = await wineManager.prefixPath(for: prefixName)
            if !fileManager.fileExists(atPath: prefixPath.path) {
                errors.append(.prefixNotInitialized(prefixName))
            }
        }

        return errors.isEmpty ? .success() : .failure(errors)
    }
}
