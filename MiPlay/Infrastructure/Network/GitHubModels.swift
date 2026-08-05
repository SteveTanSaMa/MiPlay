//
//  GitHubModels.swift
//  MiPlay
//
//  Created by Steve Tan on 2026/7/26.
//

@preconcurrency import Foundation

// Source: QA Report → F-006 — GitHub API 模型重复定义
// Source: Architecture Design → ADR 017 — GitHub API 认证策略

// MARK: - GitHub Release API 模型

/// GitHub Release API 响应（releases endpoint）
public struct GitHubReleaseResponse: Codable, Sendable {
    public let assets: [GitHubReleaseAsset]

    public init(assets: [GitHubReleaseAsset]) {
        self.assets = assets
    }

    nonisolated public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.assets = try container.decode([GitHubReleaseAsset].self, forKey: .assets)
    }
}

/// GitHub Release Asset
public struct GitHubReleaseAsset: Codable, Sendable {
    public let name: String
    public let browserDownloadURL: String
    public let size: Int64

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
        case size
    }

    public init(name: String, browserDownloadURL: String, size: Int64) {
        self.name = name
        self.browserDownloadURL = browserDownloadURL
        self.size = size
    }
}
