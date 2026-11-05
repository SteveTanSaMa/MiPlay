//
//  GameIconProvider.swift
//  MiPlay
//

import Foundation

// Source: 用户反馈 — 打包后的启动器 app 缺少图标，可用官方应用的 icon
//
// 图标来源：HoYoPlay（hyp-connect）公开接口 `getGames`，按 `biz`
// （hk4e_cn / hkrpg_cn / nap_cn / *_global）取官方游戏图标 PNG。
// 下载后转成 `.icns` 缓存到 `RuntimeAssets/GameIcons/<GameType>.icns`，
// 由 `LaunchCompatibilityEnvironment.prepareAppBundle` 挂进游戏 `.app` bundle。
//
// 每一步都是 best-effort：网络或系统工具失败只记录日志，不影响启动；
// 图标缺失时 bundle 保持无图标形态，下次启动自动重试（缓存命中即跳过）。

/// 官方游戏图标获取与转换。
public actor GameIconProvider {
    /// 区服。官方接口按 launcher 返回一份该区服的全部游戏列表；
    /// 游戏属于哪个区服由安装目录的 `config.ini`（`uapc` 字段）判定。
    public enum Region: String, Sendable, CaseIterable {
        case china
        case global

        nonisolated var gamesListURL: URL {
            switch self {
            case .china:
                return URL(string: "https://hyp-api.mihoyo.com/hyp/hyp-connect/api/getGames?launcher_id=jGHBHlcOq1&language=zh-cn")!
            case .global:
                return URL(string: "https://sg-hyp-api.hoyoverse.com/hyp/hyp-connect/api/getGames?launcher_id=VYTpXlbWo8&language=zh-cn")!
            }
        }
    }

    /// `getGames` 响应里本模块关心的字段。
    private struct GamesResponse: Decodable {
        struct Payload: Decodable {
            let games: [Entry]
        }
        struct Entry: Decodable {
            let biz: String
            let display: Display?

            struct Display: Decodable {
                let icon: Image?

                struct Image: Decodable {
                    let url: String?
                }
            }
        }

        let retcode: Int
        let data: Payload?
    }

    private let networkProvider: NetworkDownloadProvider
    private let processManager: ProcessManager
    private let fileSystemRepository: GameFileSystemRepository
    private let logWriter: LogWriter

    /// 一次运行内缓存 `biz → 图标 URL`，避免每个游戏都拉一次列表。
    private var cachedIconURLs: [Region: [String: String]] = [:]

    public init(
        networkProvider: NetworkDownloadProvider,
        processManager: ProcessManager,
        fileSystemRepository: GameFileSystemRepository,
        logWriter: LogWriter
    ) {
        self.networkProvider = networkProvider
        self.processManager = processManager
        self.fileSystemRepository = fileSystemRepository
        self.logWriter = logWriter
    }

    // MARK: - Provisioning

    /// 确保该游戏在缓存目录里有一份官方 `.icns`；已存在则直接返回。
    /// - Returns: 缓存文件的 URL（成功或已存在时），失败返回 nil。
    @discardableResult
    public func provisionIcon(
        for gameType: GameType,
        installPath: String?,
        assetRootURL: URL? = nil
    ) async -> URL? {
        let rootURL: URL
        if let assetRootURL {
            rootURL = assetRootURL
        } else {
            rootURL = await defaultAssetRootURL()
        }
        let destinationURL = LaunchCompatibilityEnvironment.iconCacheURL(
            for: gameType,
            assetRootURL: rootURL
        )
        if FileManager.default.fileExists(atPath: destinationURL.path) {
            return destinationURL
        }

        let region = Self.region(for: gameType, installPath: installPath)
        let biz = Self.biz(for: gameType, region: region)
        do {
            guard let iconURL = try await iconURL(for: biz, region: region) else {
                await logWriter.record(.init(
                    level: .warning,
                    module: "GameIconProvider",
                    eventName: "icon.provision",
                    gameID: gameType.rawValue,
                    phase: "resolve",
                    result: "unavailable",
                    errorCategory: "resourceNotFound",
                    messageCode: "icon.source_missing"
                ))
                return nil
            }
            let data = try await networkProvider.requestData(from: iconURL)
            guard !data.isEmpty else { throw NetworkDownloadProvider.NetworkError.serviceUnavailable("空图标响应") }

            let temporaryDirectory = FileManager.default.temporaryDirectory
                .appendingPathComponent("MiPlayIcon-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: temporaryDirectory) }
            try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
            let pngURL = temporaryDirectory.appendingPathComponent("icon.png")
            try data.write(to: pngURL, options: .atomic)

            try await convertToICNS(pngURL: pngURL, destinationURL: destinationURL, workDirectory: temporaryDirectory)
            await logWriter.record(.init(
                level: .info,
                module: "GameIconProvider",
                eventName: "icon.provision",
                gameID: gameType.rawValue,
                phase: "completed",
                result: "completed",
                messageCode: "icon.provisioned",
                fields: ["assetSize": String(data.count)]
            ))
            return destinationURL
        } catch {
            await logWriter.record(.init(
                level: .warning,
                module: "GameIconProvider",
                eventName: "icon.provision",
                gameID: gameType.rawValue,
                phase: "download",
                result: "failed",
                errorCategory: "apiNetworkError",
                messageCode: "icon.provision_failed"
            ))
            return nil
        }
    }

    private func defaultAssetRootURL() async -> URL {
        await fileSystemRepository.appSupportDirectory()
            .appendingPathComponent("RuntimeAssets", isDirectory: true)
    }

    // MARK: - Source resolution

    /// 读取安装目录 `config.ini` 的 `uapc` 字段判断区服；读不到时按可执行文件名
    /// 回退（原神国服使用 `YuanShen.exe`），仍不确定则按国服处理。
    nonisolated static func region(for gameType: GameType, installPath: String?) -> Region {
        if let installPath {
            let configURL = URL(fileURLWithPath: installPath, isDirectory: true)
                .appendingPathComponent("config.ini")
            if let content = try? String(contentsOf: configURL, encoding: .utf8) {
                for biz in candidateBizIDs(for: gameType) where content.contains(biz) {
                    return biz.hasSuffix("_cn") ? .china : .global
                }
            }
            if gameType == .genshinImpact,
               FileManager.default.fileExists(
                atPath: URL(fileURLWithPath: installPath, isDirectory: true)
                    .appendingPathComponent("YuanShen.exe").path
               ) {
                return .china
            }
        }
        return .china
    }

    /// 官方接口使用的 biz 标识（同一款游戏的国服/国际服条目）。
    nonisolated static func candidateBizIDs(for gameType: GameType) -> [String] {
        candidateBizIDs(for: gameType.definition)
    }

    /// International identity is optional for games only published in China.
    nonisolated static func candidateBizIDs(for definition: BuiltInGameDefinition) -> [String] {
        [definition.mainlandBiz, definition.globalBiz].compactMap { value in
            guard let value, !value.isEmpty else { return nil }
            return value
        }
    }

    nonisolated private static func biz(for gameType: GameType, region: Region) -> String {
        let candidates = candidateBizIDs(for: gameType)
        let suffix = region == .china ? "_cn" : "_global"
        return candidates.first { $0.hasSuffix(suffix) } ?? gameType.definition.mainlandBiz
    }

    private func iconURL(for biz: String, region: Region) async throws -> URL? {
        if let cached = cachedIconURLs[region]?[biz] {
            return URL(string: cached)
        }
        let data = try await networkProvider.requestData(from: region.gamesListURL)
        let response = try JSONDecoder().decode(GamesResponse.self, from: data)
        guard response.retcode == 0, let games = response.data?.games else {
            throw NetworkDownloadProvider.NetworkError.serviceUnavailable("游戏列表响应异常")
        }
        var map: [String: String] = [:]
        for game in games {
            if let url = game.display?.icon?.url {
                map[game.biz] = url
            }
        }
        cachedIconURLs[region] = map
        return map[biz].flatMap { URL(string: $0) }
    }

    // MARK: - ICNS conversion

    /// PNG → `.icns`：`sips` 生成 `AppIcon.iconset` 各档尺寸，`iconutil` 打包。
    /// 官方接口的图标是 96×96，大尺寸档位由 sips 放大（Dock/强制退出使用 32–128pt）。
    private func convertToICNS(pngURL: URL, destinationURL: URL, workDirectory: URL) async throws {
        let iconsetURL = workDirectory.appendingPathComponent("AppIcon.iconset", isDirectory: true)
        try FileManager.default.createDirectory(at: iconsetURL, withIntermediateDirectories: true)
        let sizes: [(name: String, pixels: Int)] = [
            ("icon_16x16", 16), ("icon_16x16@2x", 32),
            ("icon_32x32", 32), ("icon_32x32@2x", 64),
            ("icon_128x128", 128), ("icon_128x128@2x", 256),
            ("icon_256x256", 256), ("icon_256x256@2x", 512),
            ("icon_512x512", 512), ("icon_512x512@2x", 1024),
        ]
        for size in sizes {
            _ = try await processManager.launchAndWait(
                executablePath: "/usr/bin/sips",
                arguments: [
                    "-z", String(size.pixels), String(size.pixels),
                    pngURL.path,
                    "--out", iconsetURL.appendingPathComponent("\(size.name).png").path,
                ],
                timeout: 30
            )
        }
        try FileManager.default.createDirectory(
            at: destinationURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        _ = try await processManager.launchAndWait(
            executablePath: "/usr/bin/iconutil",
            arguments: ["-c", "icns", iconsetURL.path, "-o", destinationURL.path],
            timeout: 30
        )
        guard FileManager.default.fileExists(atPath: destinationURL.path) else {
            throw NetworkDownloadProvider.NetworkError.serviceUnavailable("iconutil 未生成 icns")
        }
    }
}
