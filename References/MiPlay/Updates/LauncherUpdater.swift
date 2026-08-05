//
//  LauncherUpdater.swift
//  MiPlay
//
//  Created by Steve Tan on 2026/6/20.
//

import Foundation

actor LauncherUpdater {
    enum LauncherUpdateError: LocalizedError {
        case checkFailed(String)
        case downloadFailed(String)
        case installFailed(String)

        var errorDescription: String? {
            switch self {
            case .checkFailed(let detail): return "启动器更新检查失败: \(detail)"
            case .downloadFailed(let detail): return "启动器下载失败: \(detail)"
            case .installFailed(let detail): return "启动器安装失败: \(detail)"
            }
        }
    }

    private let updateManager: UpdateManager

    init(updateManager: UpdateManager) {
        self.updateManager = updateManager
    }

    func checkForLauncherUpdate() async throws -> UpdateManager.UpdateInfo? {
        try await updateManager.checkForUpdates()
    }

    func downloadAndInstallUpdate(_ update: UpdateManager.UpdateInfo) async throws {
        let updatePath = try await updateManager.downloadUpdate(update)
        let applicationSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        let stagingDir = applicationSupport.appendingPathComponent("MiPlay/Updates", isDirectory: true)

        try FileManager.default.createDirectory(at: stagingDir, withIntermediateDirectories: true)

        let stagedPath = stagingDir.appendingPathComponent("MiPlay-\(update.latestVersion).zip")
        if FileManager.default.fileExists(atPath: stagedPath.path) {
            try FileManager.default.removeItem(at: stagedPath)
        }
        try FileManager.default.moveItem(at: updatePath, to: stagedPath)

        Logger.shared.info("启动器更新已暂存: \(stagedPath.path)")
    }
}
