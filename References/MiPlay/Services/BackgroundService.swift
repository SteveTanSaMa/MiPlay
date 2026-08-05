//
//  BackgroundService.swift
//  MiPlay
//
//  Created by Steve Tan on 2026/6/20.
//

import SwiftUI

// MARK: - GameType 扩展

extension GameType {
    var hoyoBiz: String {
        switch self {
        case .genshinImpact: return "hk4e_cn"
        case .starRail: return "hkrpg_cn"
        case .zenlessZoneZero: return "nap_cn"
        }
    }

    var placeholderIcon: String {
        switch self {
        case .genshinImpact: return "wind"
        case .starRail: return "star.fill"
        case .zenlessZoneZero: return "flame.fill"
        }
    }

    var themeColor: Color {
        switch self {
        case .genshinImpact: return Color(red: 1.0, green: 0.84, blue: 0.0)
        case .starRail: return Color(red: 0.29, green: 0.57, blue: 0.95)
        case .zenlessZoneZero: return Color(red: 1.0, green: 0.65, blue: 0.0)
        }
    }
}

// MARK: - 背景素材

struct GameBackgroundAssets {
    let backgroundURL: URL      // webp 静态图
    let videoURL: URL           // webm 源视频
    let iconURL: URL?
    let themeURL: URL?
}

// MARK: - 背景服务

@MainActor
@Observable
final class BackgroundService {
    private static let apiURL = URL(
        string: "https://hyp-api.mihoyo.com/hyp/hyp-connect/api/getAllGameBasicInfo?launcher_id=jGHBHlcOq1"
    )!

    // MARK: - 缓存目录

    private let fileManager = FileManager.default
    private var cacheDir: URL {
        let urls = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        let dir = urls[0].appendingPathComponent("MiPlay/Backgrounds", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - 状态

    private var assetsCache: [GameType: GameBackgroundAssets] = [:]
    private(set) var loadingStates: [GameType: Bool] = [:]
    private(set) var transcodingStates: [GameType: Bool] = [:]
    private(set) var lastError: Error?

    /// 获取素材元数据（URL 信息）
    func fetchAssets(for game: GameType) async throws -> GameBackgroundAssets? {
        if let cached = assetsCache[game] { return cached }

        loadingStates[game] = true
        defer { loadingStates[game] = false }

        var request = URLRequest(url: Self.apiURL)
        request.timeoutInterval = 15
        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw BackgroundError.invalidResponse
        }

        let decoded = try JSONDecoder().decode(HoyoConnectResponse.self, from: data)

        guard let gameInfo = decoded.data.gameInfoList.first(where: { $0.game.biz == game.hoyoBiz }),
              let firstBackground = gameInfo.backgrounds.first,
              let bgURL = URL(string: firstBackground.background.url) else {
            throw BackgroundError.noAssets(game: game)
        }

        // 取 video URL（优先）、无 video 时用 background URL
        let videoURL: URL
        if let vURL = firstBackground.video.flatMap({ URL(string: $0.url) }),
           !vURL.absoluteString.isEmpty {
            videoURL = vURL
        } else {
            videoURL = bgURL
        }

        let iconURL = firstBackground.icon.flatMap { URL(string: $0.url) }
        let themeURL = firstBackground.theme.flatMap { URL(string: $0.url) }
            .flatMap { $0.absoluteString.isEmpty ? nil : $0 }

        let assets = GameBackgroundAssets(
            backgroundURL: bgURL,
            videoURL: videoURL,
            iconURL: iconURL,
            themeURL: themeURL
        )
        assetsCache[game] = assets
        return assets
    }

    /// 获取已转码的 mp4 本地路径。如果尚未转码，执行转码。
    func localVideoPath(for game: GameType) async throws -> URL? {
        let mp4Path = cacheDir.appendingPathComponent("\(game.hoyoBiz).mp4")

        // 缓存存在且有效
        if fileManager.fileExists(atPath: mp4Path.path) {
            return mp4Path
        }

        // 获取视频源 URL
        guard let assets = try? await fetchAssets(for: game) else { return nil }
        let videoURL = assets.videoURL
        let isWebM = videoURL.pathExtension.lowercased() == "webm"

        if !isWebM {
            // 不是 webm，直接下载
            let data = try await downloadData(from: videoURL)
            try data.write(to: mp4Path)
            return mp4Path
        }

        // webm → mp4 转码
        transcodingStates[game] = true
        defer { transcodingStates[game] = false }

        let webmPath = cacheDir.appendingPathComponent("\(game.hoyoBiz).webm")
        try? fileManager.removeItem(at: webmPath)

        // 下载 webm
        let data = try await downloadData(from: videoURL)
        try data.write(to: webmPath)

        // 用 ffmpeg 转码
        let process = Process()
        // 优先用 bundle 内的 ffmpeg，没有则用 brew 安装的
        if let bundledFFmpeg = Bundle.main.url(forResource: "ffmpeg", withExtension: nil) {
            process.executableURL = bundledFFmpeg
        } else {
            process.executableURL = URL(fileURLWithPath: "/opt/anaconda3/bin/ffmpeg")
        }
        process.arguments = [
            "-y",
            "-i", webmPath.path,
            "-c:v", "libx264",
            "-preset", "fast",
            "-crf", "23",
            "-c:a", "aac",
            "-b:a", "128k",
            "-movflags", "+faststart",
            mp4Path.path
        ]

        let outputPipe = Pipe()
        let errorPipe = Pipe()
        process.standardOutput = outputPipe
        process.standardError = errorPipe

        print("[BackgroundService] Starting ffmpeg: \(process.executableURL?.path ?? "nil")")
        do {
            try process.run()
            process.waitUntilExit()
            print("[BackgroundService] ffmpeg exit code: \(process.terminationStatus)")
        } catch {
            print("[BackgroundService] ffmpeg failed to run: \(error)")
            try? fileManager.removeItem(at: webmPath)
            return nil
        }

        // 删除临时 webm
        try? fileManager.removeItem(at: webmPath)

        if process.terminationStatus == 0, fileManager.fileExists(atPath: mp4Path.path) {
            print("[BackgroundService] Transcode succeeded: \(mp4Path.path)")
            return mp4Path
        }

        print("[BackgroundService] Transcode failed, falling back to static image")
        // 转码失败，回退到静态图
        return nil
    }

    /// 预加载所有三个游戏的素材
    func preloadAll() async -> [GameType: GameBackgroundAssets] {
        var result: [GameType: GameBackgroundAssets] = [:]
        for game in GameType.allCases {
            if let assets = try? await fetchAssets(for: game) {
                result[game] = assets
            }
        }
        return result
    }

    // MARK: - 辅助

    private func downloadData(from url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.timeoutInterval = 60
        let (data, _) = try await URLSession.shared.data(for: request)
        return data
    }

    /// 获取本地缓存的 theme 图片路径
    func localThemePath(for game: GameType) async -> URL? {
        let themePath = cacheDir.appendingPathComponent("\(game.hoyoBiz)_theme.webp")
        if fileManager.fileExists(atPath: themePath.path) {
            return themePath
        }

        guard let assets = try? await fetchAssets(for: game),
              let themeURL = assets.themeURL else { return nil }

        if let data = try? await downloadData(from: themeURL) {
            try? data.write(to: themePath)
            return themePath
        }
        return nil
    }

    func clearCache() {
        assetsCache.removeAll()
        try? fileManager.removeItem(at: cacheDir)
        try? fileManager.createDirectory(at: cacheDir, withIntermediateDirectories: true)
    }
}

// MARK: - 错误

enum BackgroundError: LocalizedError {
    case invalidResponse
    case noAssets(game: GameType)

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "服务器响应异常"
        case .noAssets(game: let g): return "未找到 \(g.displayName) 的背景素材"
        }
    }
}
