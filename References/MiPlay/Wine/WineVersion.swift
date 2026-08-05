//
//  WineVersion.swift
//  MiPlay
//
//  Created by Steve Tan on 2026/6/20.
//

import Foundation

struct WineVersion: Codable, Identifiable, Equatable {
    var id: String { "\(version)-\(variant.rawValue)" }

    let version: String           // e.g. "11.8"
    let name: String              // e.g. "Wine 11.8 (devel)"
    let downloadURL: URL
    let releaseDate: Date
    let isRecommended: Bool
    let releaseNotes: String?
    let fileSize: Int64?
    let sha256: String?
    let variant: WineVariant      // devel / crossover / crossover-signed

    enum WineVariant: String, Codable, CaseIterable {
        case devel = "devel"
        case crossover = "crossover"
        case crossoverSigned = "crossover-signed"

        var displayName: String {
            switch self {
            case .devel: return "Wine (devel)"
            case .crossover: return "Wine Crossover"
            case .crossoverSigned: return "Wine Crossover (已签名)"
            }
        }

        var releasePrefix: String {
            switch self {
            case .devel: return "wine-devel"
            case .crossover: return "wine-crossover"
            case .crossoverSigned: return "wine-crossover"
            }
        }
    }
}

// MARK: - Version Provider

actor WineVersionProvider {
    enum ProviderError: LocalizedError {
        case fetchFailed(String)
        case noReleasesFound

        var errorDescription: String? {
            switch self {
            case .fetchFailed(let detail): return "获取 Wine 版本列表失败: \(detail)"
            case .noReleasesFound: return "未找到任何 Wine 版本"
            }
        }
    }

    private let repo = "yaagl/anime-game-wine"
    private let decoder = JSONDecoder()

    func fetchAvailableVersions() async throws -> [WineVersion] {
        let url = URL(string: "https://api.github.com/repos/\(repo)/releases?per_page=20")!
        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            throw ProviderError.fetchFailed("HTTP 请求失败")
        }

        let releases = try decoder.decode([GitHubRelease].self, from: data)
        let versions = releases.compactMap { release -> WineVersion? in
            parseRelease(release)
        }

        if versions.isEmpty {
            throw ProviderError.noReleasesFound
        }

        return versions.sorted { $0.releaseDate > $1.releaseDate }
    }

    private func parseRelease(_ release: GitHubRelease) -> WineVersion? {
        guard !release.draft else { return nil }

        // Determine variant from tag name
        let tag = release.tagName

        // Find the .tar.xz asset
        guard let asset = release.assets.first(where: { $0.name.hasSuffix(".tar.xz") }),
              let downloadURL = URL(string: asset.browserDownloadURL) else {
            return nil
        }

        let variant: WineVersion.WineVariant
        let versionStr: String

        if tag.contains("wine-crossover") {
            // tag: wine-crossover-11.0-1(-signed)
            variant = tag.hasSuffix("-signed") ? .crossoverSigned : .crossover
            let stripped = tag
                .replacingOccurrences(of: "wine-crossover-", with: "")
                .replacingOccurrences(of: "-signed", with: "")
            versionStr = stripped
        } else if tag.contains("wine-") {
            variant = .devel
            let stripped = tag.replacingOccurrences(of: "wine-", with: "")
            versionStr = stripped.replacingOccurrences(of: "-signed", with: "")
        } else {
            return nil
        }

        let isRecommended = variant == .crossoverSigned || variant == .devel

        return WineVersion(
            version: versionStr,
            name: variant.displayName + " " + versionStr,
            downloadURL: downloadURL,
            releaseDate: ISO8601DateFormatter().date(from: release.createdAt) ?? Date(),
            isRecommended: isRecommended,
            releaseNotes: release.body,
            fileSize: Int64(asset.size),
            sha256: asset.digest?.replacingOccurrences(of: "sha256:", with: ""),
            variant: variant
        )
    }
}

// MARK: - GitHub API Models

struct GitHubRelease: Codable {
    let tagName: String
    let name: String
    let draft: Bool
    let prerelease: Bool
    let createdAt: String
    let publishedAt: String?
    let body: String?
    let assets: [GitHubAsset]

    enum CodingKeys: String, CodingKey {
        case tagName = "tag_name"
        case name, draft, prerelease
        case createdAt = "created_at"
        case publishedAt = "published_at"
        case body, assets
    }
}

struct GitHubAsset: Codable {
    let name: String
    let size: Int
    let digest: String?
    let browserDownloadURL: String

    enum CodingKeys: String, CodingKey {
        case name, size, digest
        case browserDownloadURL = "browser_download_url"
    }
}
