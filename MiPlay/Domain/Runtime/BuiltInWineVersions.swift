//
//  BuiltInWineVersions.swift
//  MiPlay
//
//  Created by Steve Tan on 2026/7/7.
//

import Foundation

// Source: Architecture Design → Domain Model → RuntimeEnvironment
// Source: Architecture Design → ADR 011 → Wine 版本管理双层分离

/// 内置 Wine 版本清单。
/// 定义 MiPlay 已知的、可从指定上游获取的 Wine 构建版本集合。
/// Product 边界：不提供通用 Wine 版本管理器，仅管理 MiPlay 内置指定的有限版本集合。
public struct BuiltInWineVersions {
    // Source: Architecture Design -> Revision 2026-08-03 -> WineSourceSelection
    public struct SourceDescriptor: Sendable, Equatable {
        public let sourceID: String
        public let apiEndpoint: URL
        public let allowedAssetHost: String
        public let allowedAssetPathPrefix: String
        public let allowedAssetRedirectHosts: [String]
        public let policyRevision: String
        public let supportedArchitectures: [String]
        nonisolated public var supportedArchitecture: String {
            supportedArchitectures[0]
        }

        nonisolated public init(
            sourceID: String,
            apiEndpoint: URL,
            allowedAssetHost: String,
            allowedAssetPathPrefix: String,
            allowedAssetRedirectHosts: [String] = [],
            policyRevision: String,
            supportedArchitecture: String = "osx64",
            additionalSupportedArchitectures: [String] = ["arm64"]
        ) {
            self.sourceID = sourceID
            self.apiEndpoint = apiEndpoint
            self.allowedAssetHost = allowedAssetHost
            self.allowedAssetPathPrefix = allowedAssetPathPrefix
            self.allowedAssetRedirectHosts = allowedAssetRedirectHosts
            self.policyRevision = policyRevision
            var architectures: [String] = []
            for architecture in [supportedArchitecture] + additionalSupportedArchitectures
                where !architecture.isEmpty && !architectures.contains(architecture) {
                architectures.append(architecture)
            }
            self.supportedArchitectures = architectures.isEmpty ? ["osx64"] : architectures
        }

        nonisolated public func supportsAssetName(_ name: String) -> Bool {
            supportedArchitectures.contains { name.contains($0) }
        }
    }

    nonisolated public static let officialSource = SourceDescriptor(
        sourceID: "officialGitHub",
        apiEndpoint: URL(string: "https://api.github.com/repos/yaagl/anime-game-wine/releases?per_page=100")!,
        allowedAssetHost: "github.com",
        allowedAssetPathPrefix: "/yaagl/anime-game-wine/releases/download/",
        allowedAssetRedirectHosts: [
            "objects.githubusercontent.com",
            "release-assets.githubusercontent.com"
        ],
        policyRevision: "2026-08-03"
    )

    /// Research has not approved a third-party mirror yet. An empty list is a
    /// deliberate allowlist, not an implicit arbitrary-URL fallback.
    nonisolated public static let approvedMirrorSources: [SourceDescriptor] = []

    nonisolated public static var approvedSources: [SourceDescriptor] {
        [officialSource] + approvedMirrorSources
    }

    nonisolated public static func sourceDescriptor(for sourceID: String) -> SourceDescriptor? {
        approvedSources.first { $0.sourceID == sourceID }
    }

    /// GitHub 发布版本元数据
    public struct WineVersionSource: Sendable {
        public let tagName: String
        public let displayName: String
        public let githubReleaseURL: URL
        public let assetNameFilter: String  // 用于筛选 assets 名称
        public let description: String

        nonisolated public init(
            tagName: String,
            displayName: String,
            githubReleaseURL: URL,
            assetNameFilter: String,
            description: String
        ) {
            self.tagName = tagName
            self.displayName = displayName
            self.githubReleaseURL = githubReleaseURL
            self.assetNameFilter = assetNameFilter
            self.description = description
        }
    }

    /// 获取所有内置 Wine 版本来源
    nonisolated public static func allSources() -> [WineVersionSource] {
        return [
            WineVersionSource(
                tagName: "wine-crossover-11.0-1-signed",
                displayName: "Wine CrossOver 11.0-1 (Signed)",
                githubReleaseURL: URL(string: "https://api.github.com/repos/yaagl/anime-game-wine/releases")!,
                assetNameFilter: "osx64",
                description: "签名的 CrossOver 11.0-1 版本"
            ),
            WineVersionSource(
                tagName: "wine-crossover-11.0-1",
                displayName: "Wine CrossOver 11.0-1",
                githubReleaseURL: URL(string: "https://api.github.com/repos/yaagl/anime-game-wine/releases")!,
                assetNameFilter: "osx64",
                description: "CrossOver 11.0-1 版本"
            ),
            WineVersionSource(
                tagName: "wine-11.0-signed",
                displayName: "Wine Devel 11.0 (Signed)",
                githubReleaseURL: URL(string: "https://api.github.com/repos/yaagl/anime-game-wine/releases")!,
                assetNameFilter: "osx64",
                description: "签名的 Wine 11.0 开发版本"
            ),
            WineVersionSource(
                tagName: "wine-11.8-signed",
                displayName: "Wine Devel 11.8 (Signed)",
                githubReleaseURL: URL(string: "https://api.github.com/repos/yaagl/anime-game-wine/releases")!,
                assetNameFilter: "osx64",
                description: "签名的 Wine 11.8 开发版本"
            ),
            WineVersionSource(
                tagName: "wine-crossover-21.2.0",
                displayName: "Wine CrossOver 21.2.0",
                githubReleaseURL: URL(string: "https://api.github.com/repos/yaagl/anime-game-wine/releases")!,
                assetNameFilter: "arm64",
                description: "稳定的 CrossOver 分支版本，兼容性较好"
            ),
            WineVersionSource(
                tagName: "wine-devel-9.0",
                displayName: "Wine Devel 9.0",
                githubReleaseURL: URL(string: "https://api.github.com/repos/yaagl/anime-game-wine/releases")!,
                assetNameFilter: "arm64",
                description: "最新的 Wine 开发分支版本"
            ),
        ]
    }

    /// 获取指定版本的来源
    nonisolated public static func source(for tagName: String) -> WineVersionSource? {
        return allSources().first { $0.tagName == tagName }
    }
}
