// WineVersionDownloaderValidation.swift
// MiPlay

import Foundation

// Source: Architecture Design -> Wine download -> managed archive validation and cleanup
extension WineVersionDownloader {
    internal nonisolated func validateManagedTag(_ tagName: String) throws {
        guard BuiltInWineVersions.source(for: tagName) != nil else {
            throw DownloaderError.assetForbidden("未批准的 Wine 版本标签: \(tagName)")
        }
    }

    internal nonisolated func validateApprovedAsset(_ asset: ApprovedAsset) throws {
        try validateManagedTag(asset.tagName)
        guard let source = BuiltInWineVersions.sourceDescriptor(for: asset.sourceID) else {
            throw DownloaderError.assetForbidden("未批准的 Wine 来源: \(asset.sourceID)")
        }
        guard asset.fileSize >= 0,
              !asset.assetName.isEmpty else {
            throw DownloaderError.assetForbidden("Wine asset 元数据不完整")
        }
        try validateApprovedAsset(
            asset.url,
            tagName: asset.tagName,
            assetName: asset.assetName,
            source: source
        )
    }

    internal nonisolated func validateApprovedAsset(_ url: URL, tagName: String, assetName: String) throws {
        guard let source = BuiltInWineVersions.sourceDescriptor(for: "officialGitHub") else {
            throw DownloaderError.assetForbidden("缺少批准的 Wine 来源")
        }
        try validateApprovedAsset(url, tagName: tagName, assetName: assetName, source: source)
    }

    internal nonisolated func validateApprovedAsset(
        _ url: URL,
        tagName: String,
        assetName: String,
        source: BuiltInWineVersions.SourceDescriptor
    ) throws {
        guard url.scheme?.lowercased() == "https",
              url.host?.lowercased() == source.allowedAssetHost.lowercased(),
              url.path.hasPrefix(source.allowedAssetPathPrefix + tagName + "/"),
              url.pathExtension.lowercased() == "xz",
              assetName.hasSuffix(".tar.xz"),
              source.supportsAssetName(assetName),
              url.lastPathComponent == assetName else {
            throw DownloaderError.assetForbidden("Wine asset 不在批准来源 allowlist 内")
        }
    }

    internal nonisolated func allowedRedirectHosts(for asset: ApprovedAsset) -> [String] {
        guard let source = BuiltInWineVersions.sourceDescriptor(for: asset.sourceID) else { return [] }
        return ([source.allowedAssetHost] + source.allowedAssetRedirectHosts).map { $0.lowercased() }
    }

    internal func validateArchiveEntries(_ listing: String) throws {
        for entry in listing.split(whereSeparator: \.isNewline).map(String.init) {
            let name = entry.trimmingCharacters(in: .whitespacesAndNewlines)
            guard name.isEmpty == false,
                  name.hasPrefix("/") == false,
                  name.split(separator: "/", omittingEmptySubsequences: false).contains(where: { $0 == ".." }) == false else {
                throw DownloaderError.extractionFailed("归档包含越界条目: \(name)")
                        }
                    }
                }

    internal func validateArchiveSymlinks(_ listing: String, inside root: URL) throws {
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        let rootPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        for line in listing.split(whereSeparator: \.isNewline).map(String.init) {
            guard line.first == "l", let arrow = line.range(of: " -> ") else { continue }
            let left = String(line[..<arrow.lowerBound])
            let target = String(line[arrow.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let linkPath = left.split(separator: " ").last.map(String.init),
                  linkPath.hasPrefix("/") == false,
                  target.isEmpty == false,
                  target.hasPrefix("/") == false else {
                throw DownloaderError.extractionFailed("归档包含绝对路径符号链接")
            }

            let linkURL = root.appendingPathComponent(linkPath, isDirectory: false)
            let resolvedTarget = linkURL.deletingLastPathComponent()
                .appendingPathComponent(target, isDirectory: false)
                .standardizedFileURL
            guard resolvedTarget.path.hasPrefix(rootPrefix) else {
                throw DownloaderError.extractionFailed("归档包含越界符号链接: \(linkPath)")
            }
        }
    }

    internal func validateExtractedTree(at directory: URL) throws {
        let rootPath = directory.resolvingSymlinksInPath().standardizedFileURL.path
        let containedPrefix = rootPath.hasSuffix("/") ? rootPath : rootPath + "/"
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: [.isSymbolicLinkKey],
            options: []
        ) else {
            throw DownloaderError.extractionFailed("无法检查解压目录")
        }

        for case let childURL as URL in enumerator {
            let values = try childURL.resourceValues(forKeys: [.isSymbolicLinkKey])
            let canonical = childURL.resolvingSymlinksInPath().standardizedFileURL
            guard canonical.path.hasPrefix(containedPrefix) else {
                throw DownloaderError.extractionFailed("解压条目通过符号链接越界: \(childURL.lastPathComponent)")
            }
            // Links that remain inside the staging root are allowed by Wine
            // archives; links escaping the root were rejected above.
            _ = values.isSymbolicLink
        }
    }

    internal func cleanup(staging: ManagedStaging) throws {
        let rootPath = staging.rootURL.path.hasSuffix("/") ? staging.rootURL.path : staging.rootURL.path + "/"
        let canonicalDirectory = staging.directoryURL.resolvingSymlinksInPath().standardizedFileURL
        guard canonicalDirectory.path.hasPrefix(rootPath),
              staging.directoryURL.path != staging.rootURL.path else {
            throw DownloaderError.cleanupFailed("拒绝清理托管 staging 之外的目录")
        }
        guard FileManager.default.fileExists(atPath: staging.directoryURL.path) else {
            return
        }
        do {
            try FileManager.default.removeItem(at: staging.directoryURL)
        } catch {
            // Cancellation can race with the manager's idempotent cleanup.
            // A missing path after the failed remove means the other cleanup
            // owner completed the same verified, managed cleanup.
            guard FileManager.default.fileExists(atPath: staging.directoryURL.path) else {
                return
            }
            throw error
        }
    }

    internal func wasCancelled(sessionID: UUID) -> Bool {
        cancelledSessions.contains(sessionID)
    }
}
