//
//  MediaCacheManager.swift
//  MiPlay
//
//  Created by Steve Tan on 2026/7/7.
//

import Foundation

// Source: Review Issue: F4 — 背景素材实现
// 磁盘缓存管理：管理 webm/webp/mp4 文件的下载缓存

/// 媒体缓存管理器。管理背景素材的磁盘缓存。
public actor MediaCacheManager {
    public enum CacheError: Error, LocalizedError {
        case cacheFull(String)
        case writeFailed(String)
        case readFailed(String)

        public var errorDescription: String? {
            switch self {
            case .cacheFull(let detail):
                return "缓存已满: \(detail)"
            case .writeFailed(let detail):
                return "缓存写入失败: \(detail)"
            case .readFailed(let detail):
                return "缓存读取失败: \(detail)"
            }
        }
    }

    private let fileManager: FileManager
    private let baseURL: URL?

    public init(baseURL: URL? = nil) {
        self.fileManager = FileManager.default
        self.baseURL = baseURL
    }

    /// 获取缓存目录
    public func cacheDirectory() -> URL {
        let root = baseURL
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = root.appendingPathComponent(
            baseURL == nil ? "MiPlay/MediaCache" : "MediaCache",
            isDirectory: true
        )
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// 检查缓存中是否已有文件
    public func hasCachedFile(for key: String) -> Bool {
        let url = cacheDirectory().appendingPathComponent(key)
        return fileManager.fileExists(atPath: url.path)
    }

    /// 获取缓存文件路径
    public func cachedFileURL(for key: String) -> URL {
        cacheDirectory().appendingPathComponent(key)
    }

    /// Source: ADR 019 — content-addressable 缓存，支持子目录
    /// 获取指定子目录下的缓存文件路径
    /// - Parameters:
    ///   - key: 文件名（如 "background.png"）
    ///   - subdirectory: 子目录名（如 "GenshinImpact/{backgroundId}"）
    /// - Returns: MediaCache/{subdirectory}/{key}
    public func cachedFileURL(forKey key: String, inDirectory subdirectory: String) -> URL {
        let dir = cacheDirectory().appendingPathComponent(subdirectory, isDirectory: true)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(key)
    }

    /// Returns the stable metadata file location inside a Game's cache group.
    /// Fingerprints and cache manifests live here, not in AppData.
    public func cacheMetadataURL(forGameId gameId: String, filename: String) -> URL {
        let dir = cacheDirectory().appendingPathComponent(gameId, isDirectory: true)
        try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(filename)
    }

    /// Writes derived cache metadata (for example the API collection
    /// fingerprint) with an atomic replace.
    public func writeCacheMetadata(_ data: Data, forGameId gameId: String, filename: String) throws {
        let url = cacheMetadataURL(forGameId: gameId, filename: filename)
        let temporary = url.appendingPathExtension("tmp")
        do {
            try data.write(to: temporary, options: [.atomic])
            if fileManager.fileExists(atPath: url.path) {
                _ = try fileManager.replaceItemAt(url, withItemAt: temporary)
            } else {
                try fileManager.moveItem(at: temporary, to: url)
            }
        } catch {
            try? fileManager.removeItem(at: temporary)
            throw CacheError.writeFailed("缓存元数据写入失败: \(error.localizedDescription)")
        }
    }

    /// Reads derived cache metadata. A missing or unreadable file returns nil
    /// so callers can treat the collection as unknown without destructive
    /// cleanup.
    public func readCacheMetadata(forGameId gameId: String, filename: String) throws -> Data? {
        let url = cacheMetadataURL(forGameId: gameId, filename: filename)
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        return try Data(contentsOf: url)
    }

    /// Lists only background-group directories for a Game. Metadata files at
    /// the Game root are not treated as groups.
    public func groupDirectoryNames(forGameId gameId: String) throws -> [String] {
        let dir = cacheDirectory().appendingPathComponent(gameId, isDirectory: true)
        guard fileManager.fileExists(atPath: dir.path) else { return [] }
        let contents = try fileManager.contentsOfDirectory(atPath: dir.path)
        var groups: [String] = []
        for item in contents {
            let itemURL = dir.appendingPathComponent(item, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: itemURL.path, isDirectory: &isDirectory),
                  isDirectory.boolValue else { continue }
            groups.append(item)
        }
        return groups
    }

    /// 写入缓存（不自动删除旧素材，由用户手动清理）
    public func writeToCache(data: Data, for key: String) throws {
        let url = cachedFileURL(for: key)
        try data.write(to: url, options: [.atomic])
    }

    /// 从缓存读取
    public func readFromCache(for key: String) throws -> Data {
        let url = cachedFileURL(for: key)
        guard fileManager.fileExists(atPath: url.path) else {
            throw CacheError.readFailed("缓存文件不存在: \(key)")
        }
        return try Data(contentsOf: url)
    }

    /// 清除所有缓存
    public func clearCache() throws {
        let dir = cacheDirectory()
        if fileManager.fileExists(atPath: dir.path) {
            try fileManager.removeItem(at: dir)
            try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
    }

    /// 清除指定游戏的缓存
    public func clearCache(for gameType: String) throws {
        let dir = cacheDirectory()
        let contents = try fileManager.contentsOfDirectory(atPath: dir.path)
        for item in contents where item.hasPrefix(gameType) {
            try fileManager.removeItem(at: dir.appendingPathComponent(item))
        }
    }

    /// Source: ADR 019 — content-addressable 缓存清理
    /// 清除指定游戏指定背景 ID 的所有缓存
    /// - Parameters:
    ///   - gameId: GameType.rawValue
    ///   - backgroundId: 背景素材 ID
    public func clearCache(forGameId gameId: String, backgroundId: String) throws {
        let dir = cacheDirectory().appendingPathComponent("\(gameId)/\(backgroundId)", isDirectory: true)
        if fileManager.fileExists(atPath: dir.path) {
            try fileManager.removeItem(at: dir)
        }
    }

    /// 获取缓存大小
    public func cacheSize() -> UInt64 {
        let dir = cacheDirectory()
        guard fileManager.fileExists(atPath: dir.path) else { return 0 }
        var size: UInt64 = 0
        if let enumerator = fileManager.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey]) {
            for case let fileURL as URL in enumerator {
                if let attrs = try? fileURL.resourceValues(forKeys: [.fileSizeKey]),
                   let fileSize = attrs.fileSize {
                    size += UInt64(fileSize)
                }
            }
        }
        return size
    }

}
