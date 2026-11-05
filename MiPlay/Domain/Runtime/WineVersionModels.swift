//
//  WineVersionModels.swift
//  MiPlay
//

import Foundation

// Source: Architecture Design -> Service Contract -> WineVersionManager
// Source: Architecture Design -> Domain Model -> ManagedWineRuntime

/// Fixed runtime catalog information retained for the setup projection.
public struct WineVersionInfo: Sendable, Identifiable, Hashable {
    public let id: String
    public let tagName: String
    public let name: String
    public let downloadURL: URL
    public let fileSize: Int64
    public let publishedAt: Date
    public let sourceID: String
    public let policyRevision: String
    public let assetName: String
    public let expectedSHA256: String?
    public var isDownloaded: Bool
    public var isSelected: Bool

    public nonisolated init(
        id: String,
        tagName: String,
        name: String,
        downloadURL: URL,
        fileSize: Int64,
        publishedAt: Date,
        sourceID: String = "officialGitHub",
        policyRevision: String = "2026-08-03",
        assetName: String = "",
        expectedSHA256: String? = nil,
        isDownloaded: Bool = false,
        isSelected: Bool = false
    ) {
        self.id = id
        self.tagName = tagName
        self.name = name
        self.downloadURL = downloadURL
        self.fileSize = fileSize
        self.publishedAt = publishedAt
        self.sourceID = sourceID
        self.policyRevision = policyRevision
        self.assetName = assetName
        self.expectedSHA256 = expectedSHA256
        self.isDownloaded = isDownloaded
        self.isSelected = isSelected
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    public static func == (lhs: WineVersionInfo, rhs: WineVersionInfo) -> Bool {
        lhs.id == rhs.id
    }
}

// A runtime identity is produced by WineVersionManager after the managed
// record, allowlist, canonical root and executable have been checked. Callers
// cannot construct one from an arbitrary user path through the public API.
nonisolated public struct ManagedWineRuntime: Sendable, Equatable {
    public let tagName: String
    public let rootURL: URL

    nonisolated internal init(tagName: String, rootURL: URL) {
        self.tagName = tagName
        self.rootURL = rootURL
    }

    nonisolated public var binaryURL: URL {
        rootURL.appendingPathComponent("bin/wine", isDirectory: false)
    }

    nonisolated public var identity: String { tagName }
}

// Source: Architecture Design -> Domain Model -> SharedWinePrefix
nonisolated public struct SharedWinePrefix: Sendable, Equatable {
    public let identity: String
    public let url: URL
    public let runtimeIdentity: String

    internal init(identity: String, url: URL, runtimeIdentity: String) {
        self.identity = identity
        self.url = url
        self.runtimeIdentity = runtimeIdentity
    }

    nonisolated public var path: String { url.path }
}

// Source: Architecture Design -> ADR 039 -> shared prefix exclusive lease
nonisolated public struct SharedWinePrefixLease: Sendable, Equatable {
    public let id: UUID
    public let prefix: SharedWinePrefix

    nonisolated internal init(id: UUID = UUID(), prefix: SharedWinePrefix) {
        self.id = id
        self.prefix = prefix
    }
}

// Source: QA Report -> F-006 - shared GitHub API models
struct GitHubRelease: Codable, Sendable {
    let id: Int
    let tagName: String
    let name: String
    let assets: [GitHubAsset]
    let publishedAt: String

    enum CodingKeys: String, CodingKey {
        case id
        case tagName = "tag_name"
        case name
        case assets
        case publishedAt = "published_at"
    }
}

struct GitHubAsset: Codable, Sendable {
    let name: String
    let browserDownloadURL: String
    let size: Int64

    enum CodingKeys: String, CodingKey {
        case name
        case browserDownloadURL = "browser_download_url"
        case size
    }
}
