//
//  WineManager.swift
//  MiPlay
//
//  Created by Steve Tan on 2026/6/20.
//

import Foundation

actor WineManager {
    enum ManagerError: LocalizedError {
        case wineNotFound(String)
        case notInstalled
        case versionMismatch(String)

        var errorDescription: String? {
            switch self {
            case .wineNotFound(let version): return "Wine \(version) 未找到"
            case .notInstalled: return "未安装任何 Wine 版本"
            case .versionMismatch(let detail): return "版本不匹配: \(detail)"
            }
        }
    }

    nonisolated let runtimeDirectory: URL
    private let downloader = WineDownloader()
    private let prefixManager: WinePrefixManager

    var installedVersions: [WineConfig] = []

    init(runtimeDirectory: URL, prefixesDirectory: URL? = nil) {
        self.runtimeDirectory = runtimeDirectory
        self.prefixManager = WinePrefixManager(baseURL: prefixesDirectory ?? runtimeDirectory)
    }

    func loadInstalledVersions() {
        let versionsDir = runtimeDirectory.appendingPathComponent("Versions", isDirectory: true)
        guard FileManager.default.fileExists(atPath: versionsDir.path) else { return }

        do {
            let contents = try FileManager.default.contentsOfDirectory(atPath: versionsDir.path)
            installedVersions = contents.compactMap { versionName in
                let versionPath = versionsDir.appendingPathComponent(versionName)
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: versionPath.path, isDirectory: &isDir), isDir.boolValue else {
                    return nil
                }
                return WineConfig(
                    version: versionName,
                    name: versionName,
                    localPath: versionPath.path,
                    dxmtVersion: nil,
                    isDefault: installedVersions.isEmpty
                )
            }
        } catch {
            Logger.shared.error("加载 Wine 版本列表失败: \(error.localizedDescription)")
        }
    }

    func installWine(version: WineVersion, progressHandler: (@Sendable (Double) -> Void)? = nil) async throws {
        let tempDir = FileManager.default.temporaryDirectory
        let versionsDir = runtimeDirectory.appendingPathComponent("Versions", isDirectory: true)
        let targetDir = versionsDir.appendingPathComponent(version.version, isDirectory: true)

        if FileManager.default.fileExists(atPath: targetDir.path) {
            return
        }

        try FileManager.default.createDirectory(at: targetDir, withIntermediateDirectories: true)

        let archiveURL: URL
        if let progressHandler = progressHandler {
            let downloadManager = DownloadManager()
            archiveURL = try await downloadManager.downloadWithProgress(
                url: version.downloadURL,
                to: tempDir,
                progressHandler: progressHandler
            )
        } else {
            archiveURL = try await downloader.downloadWine(version: version, to: tempDir)
        }
        try await downloader.extractWinePackage(at: archiveURL, to: targetDir)
        try? FileManager.default.removeItem(at: archiveURL)
        loadInstalledVersions()
    }

    func removeWine(version: String) async throws {
        let versionsDir = runtimeDirectory.appendingPathComponent("Versions", isDirectory: true)
        let versionDir = versionsDir.appendingPathComponent(version)

        guard FileManager.default.fileExists(atPath: versionDir.path) else {
            throw ManagerError.wineNotFound(version)
        }

        try FileManager.default.removeItem(at: versionDir)
        loadInstalledVersions()
    }

    func createPrefix(config: WineConfig, prefix: WinePrefix) async throws {
        try await prefixManager.createPrefix(config, prefix: prefix)
    }

    /// 用新的 Wine 版本重新初始化已有的 prefix（运行 wineboot -u）
    func reinitializePrefix(config: WineConfig, prefixName: String) async throws {
        try await prefixManager.reinitialize(config: config, prefixName: prefixName)
    }

    func deletePrefix(name: String) async throws {
        try await prefixManager.deletePrefix(name)
    }

    nonisolated func prefixPath(for name: String) -> URL {
        prefixManager.path(for: name)
    }

    func wineBinaryPath(for version: String) -> String? {
        installedVersions.first(where: { $0.version == version })?.localPath
    }

    func fetchRemoteVersions() async throws -> [WineVersion] {
        let provider = WineVersionProvider()
        return try await provider.fetchAvailableVersions()
    }
}
