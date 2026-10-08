//
//  GameFileSystemRepository.swift
//  MiPlay
//
//  Created by Steve Tan on 2026/7/7.
//

import CryptoKit
import Foundation

// Source: Architecture Design → Service Contract → GameFileSystemRepository
// Source: Architecture Design → ADR 003 → Actor 隔离

/// Injectable bookmark behavior used by focused tests. Production uses the
/// system implementation below; tests can model stale resolution and revoked
/// access without manufacturing platform bookmark bytes.
public struct BookmarkResolver: @unchecked Sendable {
    public struct Resolution: @unchecked Sendable {
        public let url: URL
        public let isStale: Bool

        nonisolated public init(url: URL, isStale: Bool) {
            self.url = url
            self.isStale = isStale
        }
    }

    public let resolve: @Sendable (Data) throws -> Resolution
    public let refresh: @Sendable (URL, GameLocation.Scope) throws -> Data
    public let startAccessing: @Sendable (URL) -> Bool
    public let stopAccessing: @Sendable (URL) -> Void

    nonisolated public init(
        resolve: @escaping @Sendable (Data) throws -> Resolution,
        refresh: @escaping @Sendable (URL, GameLocation.Scope) throws -> Data,
        startAccessing: @escaping @Sendable (URL) -> Bool,
        stopAccessing: @escaping @Sendable (URL) -> Void
    ) {
        self.resolve = resolve
        self.refresh = refresh
        self.startAccessing = startAccessing
        self.stopAccessing = stopAccessing
    }

    nonisolated public static var system: BookmarkResolver {
        BookmarkResolver(
            resolve: { bookmarkData in
                var stale = false
                let url = try URL(
                    resolvingBookmarkData: bookmarkData,
                    options: [.withSecurityScope],
                    relativeTo: nil,
                    bookmarkDataIsStale: &stale
                )
                return Resolution(url: url, isStale: stale)
            },
            refresh: { url, scope in
                let options: URL.BookmarkCreationOptions = scope == .readOnly
                    ? [.withSecurityScope, .securityScopeAllowOnlyReadAccess]
                    : [.withSecurityScope]
                return try url.bookmarkData(
                    options: options,
                    includingResourceValuesForKeys: nil,
                    relativeTo: nil
                )
            },
            startAccessing: { $0.startAccessingSecurityScopedResource() },
            stopAccessing: { $0.stopAccessingSecurityScopedResource() }
        )
    }
}

/// Holds a security scope for the lifetime of an operation that outlives a
/// single repository callback, such as a launched Wine process.
nonisolated public final class SecurityScopedAccess: @unchecked Sendable {
    public let url: URL
    public let resolvedLocation: GameLocation

    private let lock = NSLock()
    private let stopAccessing: @Sendable (URL) -> Void
    private var isStopped = false

    fileprivate init(
        url: URL,
        resolvedLocation: GameLocation,
        stopAccessing: @escaping @Sendable (URL) -> Void
    ) {
        self.url = url
        self.resolvedLocation = resolvedLocation
        self.stopAccessing = stopAccessing
    }

    nonisolated public func stop() {
        lock.lock()
        guard !isStopped else {
            lock.unlock()
            return
        }
        isStopped = true
        lock.unlock()
        stopAccessing(url)
    }

    deinit { stop() }
}

/// 游戏文件系统操作仓储。管理游戏文件路径、文件读写、目录扫描。
public actor GameFileSystemRepository {
    public enum FileError: Error, LocalizedError {
        case fileNotFound(String)
        case directoryNotFound(String)
        case permissionDenied(String)
        case readFailed(String)
        case writeFailed(String)
        case deleteFailed(String)
        case hashCalculationFailed(String)
        case pathNotAccessible(String)
        case bookmarkMissing(String)
        case bookmarkResolutionFailed(String)
        case securityScopeDenied(String)

        public var errorDescription: String? {
            switch self {
            case .fileNotFound(let path):
                return "文件未找到: \(path)"
            case .directoryNotFound(let path):
                return "目录未找到: \(path)"
            case .permissionDenied(let path):
                return "权限不足: \(path)"
            case .readFailed(let detail):
                return "文件读取失败: \(detail)"
            case .writeFailed(let detail):
                return "文件写入失败: \(detail)"
            case .deleteFailed(let detail):
                return "文件删除失败: \(detail)"
            case .hashCalculationFailed(let detail):
                return "哈希计算失败: \(detail)"
            case .pathNotAccessible(let path):
                return "路径不可达: \(path)"
            case .bookmarkMissing(let id):
                return "未找到游戏授权凭据: \(id)"
            case .bookmarkResolutionFailed(let detail):
                return "游戏授权凭据解析失败: \(detail)"
            case .securityScopeDenied(let path):
                return "无法取得安全访问作用域: \(path)"
            }
        }
    }

    nonisolated(unsafe) private let fileManager = FileManager.default
    private let configuredAppSupportDirectory: URL?
    private let bookmarkResolver: BookmarkResolver

    public init(
        appSupportDirectory: URL? = nil,
        bookmarkResolver: BookmarkResolver = .system
    ) {
        self.configuredAppSupportDirectory = appSupportDirectory
        self.bookmarkResolver = bookmarkResolver
    }

    // MARK: - Security-scoped bookmarks

    /// Creates the bookmark while the URL returned by NSOpenPanel is still authorized.
    public nonisolated func makeGameLocation(gameID: String, for url: URL, scope: GameLocation.Scope = .readOnly) throws -> GameLocation {
        let options: URL.BookmarkCreationOptions = scope == .readOnly
            ? [.withSecurityScope, .securityScopeAllowOnlyReadAccess]
            : [.withSecurityScope]
        do {
            let data = try url.bookmarkData(options: options, includingResourceValuesForKeys: nil, relativeTo: nil)
            return GameLocation(
                gameID: gameID,
                bookmarkData: data,
                lastKnownPath: url.path,
                scope: scope,
                resolutionState: .resolvable,
                lastResolvedAt: Date()
            )
        } catch {
            throw FileError.bookmarkResolutionFailed(error.localizedDescription)
        }
    }

    /// Runs an operation only while the bookmark's security scope is active.
    /// A stale bookmark is refreshed before the operation returns.
    public nonisolated func withSecurityScopedAccess<T: Sendable>(
        _ location: GameLocation,
        operation: @Sendable (URL, GameLocation) async throws -> T
    ) async throws -> T {
        let access = try acquireSecurityScopedAccess(location)
        defer { access.stop() }
        return try await operation(access.url, access.resolvedLocation)
    }

    /// Acquires a scope for callers whose operation continues after the
    /// repository callback returns. The caller must eventually call `stop()`.
    public nonisolated func acquireSecurityScopedAccess(_ location: GameLocation) throws -> SecurityScopedAccess {
        guard let bookmarkData = location.bookmarkData else {
            throw FileError.bookmarkMissing(location.gameID)
        }

        let resolution: BookmarkResolver.Resolution
        do {
            resolution = try bookmarkResolver.resolve(bookmarkData)
        } catch {
            throw FileError.bookmarkResolutionFailed(error.localizedDescription)
        }
        let resolvedURL = resolution.url

        guard bookmarkResolver.startAccessing(resolvedURL) else {
            throw FileError.securityScopeDenied(location.lastKnownPath ?? location.gameID)
        }

        var resolvedLocation = location
        resolvedLocation.lastKnownPath = resolvedURL.path
        resolvedLocation.lastResolvedAt = Date()
        if resolution.isStale {
            do {
                resolvedLocation.bookmarkData = try bookmarkResolver.refresh(resolvedURL, location.scope)
                // The refreshed bookmark is the new durable authorization
                // fact. Keep the stale bit only as an input condition.
                resolvedLocation.resolutionState = .resolvable
            } catch {
                bookmarkResolver.stopAccessing(resolvedURL)
                throw FileError.bookmarkResolutionFailed("stale bookmark 更新失败: \(error.localizedDescription)")
            }
        } else {
            resolvedLocation.resolutionState = .resolvable
        }

        return SecurityScopedAccess(
            url: resolvedURL,
            resolvedLocation: resolvedLocation,
            stopAccessing: bookmarkResolver.stopAccessing
        )
    }

    // MARK: - Path Validation

    /// 验证路径是否可达
    internal nonisolated func validatePath(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return fileManager.fileExists(atPath: path, isDirectory: &isDirectory)
    }

    /// 验证路径是否为目录
    internal nonisolated func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory) else { return false }
        return isDirectory.boolValue
    }

    // MARK: - Directory Contents

    /// 扫描目录下的文件（不递归）
    internal func listFiles(in directory: String) throws -> [String] {
        guard validatePath(directory) else {
            throw FileError.directoryNotFound(directory)
        }
        return try fileManager.contentsOfDirectory(atPath: directory)
    }

    /// 递归扫描目录下的所有文件
    internal func listFilesRecursively(in directory: String) throws -> [String] {
        guard validatePath(directory) else {
            throw FileError.directoryNotFound(directory)
        }
        guard let enumerator = fileManager.enumerator(atPath: directory) else {
            throw FileError.readFailed("无法枚举目录: \(directory)")
        }
        return enumerator.compactMap { $0 as? String }
    }

    // MARK: - File Operations

    /// 读取文件数据
    internal func readFile(at path: String) throws -> Data {
        guard validatePath(path) else {
            throw FileError.fileNotFound(path)
        }
        do {
            return try Data(contentsOf: URL(fileURLWithPath: path))
        } catch {
            throw FileError.readFailed(error.localizedDescription)
        }
    }

    /// 写入文件数据
    internal func writeFile(data: Data, to path: String) throws {
        let url = URL(fileURLWithPath: path)
        try ensureDirectoryExists(at: url.deletingLastPathComponent())
        do {
            try data.write(to: url, options: [.atomic])
        } catch {
            throw FileError.writeFailed(error.localizedDescription)
        }
    }

    /// 复制文件
    internal func copyFile(from sourcePath: String, to destPath: String) throws {
        guard validatePath(sourcePath) else {
            throw FileError.fileNotFound(sourcePath)
        }
        let destURL = URL(fileURLWithPath: destPath)
        try ensureDirectoryExists(at: destURL.deletingLastPathComponent())
        do {
            try fileManager.copyItem(atPath: sourcePath, toPath: destPath)
        } catch {
            throw FileError.writeFailed(error.localizedDescription)
        }
    }

    /// 移动文件
    internal func moveFile(from sourcePath: String, to destPath: String) throws {
        guard validatePath(sourcePath) else {
            throw FileError.fileNotFound(sourcePath)
        }
        let destURL = URL(fileURLWithPath: destPath)
        try ensureDirectoryExists(at: destURL.deletingLastPathComponent())
        do {
            try fileManager.moveItem(atPath: sourcePath, toPath: destPath)
        } catch {
            throw FileError.writeFailed(error.localizedDescription)
        }
    }

    /// 删除文件
    internal func deleteFile(at path: String) throws {
        guard validatePath(path) else { return }
        do {
            try fileManager.removeItem(atPath: path)
        } catch {
            throw FileError.deleteFailed(error.localizedDescription)
        }
    }

    /// 获取文件属性
    internal func fileAttributes(at path: String) throws -> [FileAttributeKey: Any] {
        guard validatePath(path) else {
            throw FileError.fileNotFound(path)
        }
        return try fileManager.attributesOfItem(atPath: path)
    }

    /// 获取文件大小（字节）
    internal func fileSize(at path: String) throws -> UInt64 {
        let attrs = try fileAttributes(at: path)
        return (attrs[.size] as? UInt64) ?? 0
    }

    // MARK: - File Integrity

    /// 计算文件 SHA-256 哈希值
    internal func calculateSHA256(of filePath: String) throws -> String {
        guard validatePath(filePath) else {
            throw FileError.fileNotFound(filePath)
        }
        let data = try readFile(at: filePath)
        return calculateSHA256(of: data)
    }

    /// 计算数据的 SHA-256 哈希值
    public func calculateSHA256(of data: Data) -> String {
        var hash = [UInt8](repeating: 0, count: Int(CC_SHA256_DIGEST_LENGTH))
        data.withUnsafeBytes { buffer in
            _ = CC_SHA256(buffer.baseAddress, CC_LONG(data.count), &hash)
        }
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    /// Calculates the MD5 evidence recorded by `pkg_version`.
    /// This is an evidence comparison helper, not the application's integrity
    /// result; the versioned manifest remains the authoritative verifier.
    internal func calculateMD5(of filePath: String) throws -> String {
        guard validatePath(filePath) else {
            throw FileError.fileNotFound(filePath)
        }
        return calculateMD5(of: try readFile(at: filePath))
    }

    internal func calculateMD5(of data: Data) -> String {
        Insecure.MD5.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - MiPlay Storage

    /// 获取 MiPlay 应用支持目录
    public func appSupportDirectory() -> URL {
        if let configuredAppSupportDirectory {
            return configuredAppSupportDirectory
        }
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return appSupport.appendingPathComponent("MiPlay", isDirectory: true)
    }

    /// 获取游戏库持久化文件路径
    public func gameLibraryURL() -> URL {
        return appSupportDirectory().appendingPathComponent("GameLibrary.json")
    }

    /// 获取配置持久化文件路径
    public func settingsURL() -> URL {
        return appSupportDirectory().appendingPathComponent("Settings.json")
    }

    /// 获取日志目录
    public func logDirectory() -> URL {
        let logs = appSupportDirectory().appendingPathComponent("Logs", isDirectory: true)
        return logs
    }

    /// 获取游戏前缀目录（Wine）
    public func winePrefixDirectory() -> URL {
        let prefixes = appSupportDirectory().appendingPathComponent("WinePrefixes", isDirectory: true)
        return prefixes
    }

    /// 获取游戏安装引导缓存目录
    public func installerCacheDirectory() -> URL {
        let cache = appSupportDirectory().appendingPathComponent("InstallerCache", isDirectory: true)
        return cache
    }

    // MARK: - Private

    private func ensureDirectoryExists(at url: URL) throws {
        var isDirectory: ObjCBool = false
        if !fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true)
        }
    }
}

// MARK: - CommonCrypto import
import CommonCrypto
