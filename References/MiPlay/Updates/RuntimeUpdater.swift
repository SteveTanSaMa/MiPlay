//
//  RuntimeUpdater.swift
//  MiPlay
//
//  Created by Steve Tan on 2026/6/20.
//

import Foundation

actor RuntimeUpdater {
    enum RuntimeUpdateError: LocalizedError {
        case updateCheckFailed(String)
        case downloadFailed(String)
        case installationFailed(String)

        var errorDescription: String? {
            switch self {
            case .updateCheckFailed(let detail): return "运行环境更新检查失败: \(detail)"
            case .downloadFailed(let detail): return "运行环境下载失败: \(detail)"
            case .installationFailed(let detail): return "运行环境安装失败: \(detail)"
            }
        }
    }

    private let runtimeDirectory: URL

    init(runtimeDirectory: URL) {
        self.runtimeDirectory = runtimeDirectory
    }

    /// 检查远程是否有新的 Wine 版本
    func checkForRuntimeUpdates() async throws -> [WineVersion] {
        let provider = WineVersionProvider()
        return try await provider.fetchAvailableVersions()
    }

    /// 安装指定版本的 Wine
    func installRuntimeUpdate(version: WineVersion) async throws {
        let downloadManager = DownloadManager()
        let tempDir = FileManager.default.temporaryDirectory
        let archiveURL = tempDir.appendingPathComponent(version.downloadURL.lastPathComponent)

        _ = try await downloadManager.download(url: version.downloadURL, to: archiveURL)

        let versionsDir = runtimeDirectory.appendingPathComponent("Versions", isDirectory: true)
        let targetDir = versionsDir.appendingPathComponent(version.version, isDirectory: true)

        if FileManager.default.fileExists(atPath: targetDir.path) {
            try FileManager.default.removeItem(at: targetDir)
        }
        try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-xJf", archiveURL.path, "-C", targetDir.path]

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw RuntimeUpdateError.installationFailed("解压失败")
        }

        try? FileManager.default.removeItem(at: archiveURL)
    }

    /// 获取当前已安装的版本
    func getInstalledVersions() -> [String] {
        let versionsDir = runtimeDirectory.appendingPathComponent("Versions", isDirectory: true)
        guard FileManager.default.fileExists(atPath: versionsDir.path) else { return [] }

        do {
            return try FileManager.default.contentsOfDirectory(atPath: versionsDir.path)
                .filter { name in
                    var isDir: ObjCBool = false
                    let path = versionsDir.appendingPathComponent(name).path
                    return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && isDir.boolValue
                }
        } catch {
            return []
        }
    }
}
