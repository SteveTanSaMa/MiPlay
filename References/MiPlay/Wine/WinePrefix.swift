//
//  WinePrefix.swift
//  MiPlay
//
//  Created by Steve Tan on 2026/6/20.
//

import Foundation

actor WinePrefixManager {
    enum PrefixError: LocalizedError {
        case creationFailed(String)
        case notFound(String)
        case updateFailed(String)

        var errorDescription: String? {
            switch self {
            case .creationFailed(let detail): return "创建 Wine Prefix 失败: \(detail)"
            case .notFound(let name): return "Wine Prefix 未找到: \(name)"
            case .updateFailed(let detail): return "更新 Wine Prefix 失败: \(detail)"
            }
        }
    }

    private let fileManager = FileManager.default
    private let baseURL: URL

    init(baseURL: URL) {
        self.baseURL = baseURL
    }

    nonisolated func prefixesDirectory() -> URL {
        baseURL.appendingPathComponent("Prefixes", isDirectory: true)
    }

    nonisolated func path(for prefixName: String) -> URL {
        prefixesDirectory().appendingPathComponent(prefixName, isDirectory: true)
    }

    func createPrefix(_ config: WineConfig, prefix: WinePrefix) async throws {
        let prefixPath = path(for: prefix.name)

        if fileManager.fileExists(atPath: prefixPath.path) {
            return
        }

        try fileManager.createDirectory(at: prefixPath, withIntermediateDirectories: true)

        let wineBin = "\(config.localPath)/bin/wine64"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "WINEPREFIX=\(prefixPath.path)",
            "WINEARCH=\(prefix.arch.rawValue)",
            wineBin,
            "wineboot", "-u"
        ]

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw PrefixError.creationFailed("wineboot 初始化失败")
        }

        try await setWindowsVersion(prefix: prefix.name, wineConfig: config, version: prefix.windowsVersion)
    }

    func setWindowsVersion(prefix name: String, wineConfig: WineConfig, version: WineWindowsVersion) async throws {
        let prefixPath = path(for: name)

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "WINEPREFIX=\(prefixPath.path)",
            "\(wineConfig.localPath)/bin/wine64",
            "winecfg", "-v", version.rawValue
        ]

        try process.run()
        process.waitUntilExit()
    }

    /// 用新版本的 Wine 重新初始化已有的 prefix（运行 wineboot -u）
    func reinitialize(config: WineConfig, prefixName: String) async throws {
        let prefixPath = path(for: prefixName)
        guard fileManager.fileExists(atPath: prefixPath.path) else {
            throw PrefixError.notFound(prefixName)
        }

        let wineBin = "\(config.localPath)/bin/wine64"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = [
            "WINEPREFIX=\(prefixPath.path)",
            "WINEARCH=win64",
            wineBin,
            "wineboot", "-u"
        ]

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw PrefixError.creationFailed("wineboot 重新初始化失败，退出码: \(process.terminationStatus)")
        }

        // 重新设置 Windows 版本
        try await setWindowsVersion(prefix: prefixName, wineConfig: config, version: .win11)
    }

    func deletePrefix(_ name: String) throws {
        let prefixPath = path(for: name)
        guard fileManager.fileExists(atPath: prefixPath.path) else { return }
        try fileManager.removeItem(at: prefixPath)
    }
}
