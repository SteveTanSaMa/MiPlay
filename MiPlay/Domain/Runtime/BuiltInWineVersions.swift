//
//  BuiltInWineVersions.swift
//  MiPlay
//
//  Created by Steve Tan on 2026/7/7.
//

import Foundation

// Source: Architecture Design → Domain Model → RuntimeEnvironment
// Source: Architecture Design -> ADR 037 -> fixed runtime catalog

/// The single Wine release approved by the current product boundary.
public struct BuiltInWineVersions {
    nonisolated public static let fixedTag = "wine-crossover-11.0-1-signed"
    // Upstream release asset identity and digest, published on the GitHub release page.
    // Pinning these values permits recovery from GitHub API rate limiting without
    // weakening archive integrity or allowing arbitrary fallback URLs.
    nonisolated public static let fixedAssetName = "wine-crossover-11.0-1-osx64-signed.tar.xz"
    nonisolated public static let fixedAssetSize: Int64 = 456_021_524
    nonisolated public static let fixedAssetSHA256 = "89fa7e90fb626523a90d5867a03c6be785d017176739c6320a3b86c7838c3a35"
    nonisolated public static let fixedAssetURL = URL(string: "https://github.com/yaagl/anime-game-wine/releases/download/\(fixedTag)/\(fixedAssetName)")!
    // Source: Architecture Design -> Revision 2026-08-03 -> WineSourceSelection
    public struct SourceDescriptor: Sendable, Equatable {
        public let sourceID: String
        public let apiEndpoint: URL
        /// 仓库页面地址（设置页展示用）。与 `apiEndpoint` 必须指向同一仓库，
        /// 由 `testSourceRepositoryWebURLMatchesAPIEndpoint` 锁定。
        public let repositoryWebURL: URL
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
            repositoryWebURL: URL,
            allowedAssetHost: String,
            allowedAssetPathPrefix: String,
            allowedAssetRedirectHosts: [String] = [],
            policyRevision: String,
            supportedArchitecture: String = "osx64",
            additionalSupportedArchitectures: [String] = ["arm64"]
        ) {
            self.sourceID = sourceID
            self.apiEndpoint = apiEndpoint
            self.repositoryWebURL = repositoryWebURL
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
        repositoryWebURL: URL(string: "https://github.com/yaagl/anime-game-wine")!,
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

    /// Fixed GitHub release metadata policy.
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

    /// Returns the one runtime entry supported by this release.
    nonisolated public static func allSources() -> [WineVersionSource] {
        return [
            WineVersionSource(
                tagName: fixedTag,
                displayName: "MiPlay Wine 11.0-1 (Signed)",
                githubReleaseURL: URL(string: "https://api.github.com/repos/yaagl/anime-game-wine/releases")!,
                assetNameFilter: "osx64",
                description: "MiPlay 托管的签名 Wine 运行时；上游发布标识保留为 \(fixedTag)"
            ),
        ]
    }

    /// 获取指定版本的来源
    nonisolated public static func source(for tagName: String) -> WineVersionSource? {
        return allSources().first { $0.tagName == tagName }
    }
}
