import Foundation
import CryptoKit
import Darwin

/// Persistent, content-verified download staging. This directory is separate
/// from the commit journal so an interrupted download never blocks launching an
/// otherwise unchanged installation. It contains no trusted installation state.
nonisolated struct SophonResumeCache {
    static let directoryName = ".miplay-sophon-download"
    private static let formatVersion = 1
    private let manager = FileManager.default
    let root: URL
    let context: URL
    private let expectedKeys: Set<String>

    private struct Owner: Codable, Equatable {
        let format: Int
        let game: GameType
        let region: String
        let destination: String
    }
    private struct Context: Codable, Equatable {
        let format: Int
        let identity: String
        let keys: [String]
    }
    struct Checkpoint: Codable {
        let format: Int
        let key: String
        var bits: Data

        func contains(_ index: Int) -> Bool {
            bits[index / 8] & (UInt8(1) << (index % 8)) != 0
        }

        mutating func set(_ index: Int, _ value: Bool) {
            let mask = UInt8(1) << (index % 8)
            if value { bits[index / 8] |= mask } else { bits[index / 8] &= ~mask }
        }
    }

    /// Checks ownership; only an entirely empty ownerless cache can be adopted.
    static func isOwned(at destination: URL, game: GameType) throws -> Bool {
        let root = destination.appendingPathComponent(directoryName, isDirectory: true)
        guard exists(root) else { return false }
        try requireDirectory(root)
        let marker = root.appendingPathComponent("owner.json")
        if !exists(marker) {
            // A crash may occur after mkdir but before creating the owner.
            // Only an actually empty directory can safely be adopted.
            guard try FileManager.default.contentsOfDirectory(atPath: root.path).isEmpty else {
                throw SophonProtocolError.corrupt("续传缓存缺少归属信息")
            }
            let owner = Owner(format: formatVersion, game: game, region: "cn", destination: destination.path)
            try JSONEncoder().encode(owner).write(to: marker, options: .atomic)
        }
        try requireRegular(marker)
        let owner = try JSONDecoder().decode(Owner.self, from: Data(contentsOf: marker))
        guard owner == Owner(format: formatVersion, game: game, region: "cn", destination: destination.path) else {
            throw SophonProtocolError.corrupt("续传缓存与游戏或安装目录不匹配")
        }
        return true
    }

    static func open(destination: URL, game: GameType, identity: String, filePaths: [String]) throws -> SophonResumeCache {
        let fm = FileManager.default
        let root = destination.appendingPathComponent(directoryName, isDirectory: true)
        try ensureOwnedRoot(destination: destination, game: game)
        let contexts = root.appendingPathComponent("contexts", isDirectory: true)
        try ensureDirectory(contexts)
        let contextID = hash(identity)
        let context = contexts.appendingPathComponent(contextID, isDirectory: true)
        try ensureDirectory(context)
        let keys = filePaths.map(hash).sorted()
        guard Set(keys).count == keys.count else { throw SophonProtocolError.corrupt("续传文件标识冲突") }
        let expected = Context(format: formatVersion, identity: contextID, keys: keys)
        let marker = context.appendingPathComponent("context.json")
        if exists(marker) {
            try requireRegular(marker)
            let stored = try JSONDecoder().decode(Context.self, from: Data(contentsOf: marker))
            guard stored == expected else { throw SophonProtocolError.corrupt("续传上下文与官方清单不匹配") }
        } else {
            let contents = try fm.contentsOfDirectory(atPath: context.path)
            guard contents.isEmpty else { throw SophonProtocolError.corrupt("续传上下文缺少归属信息") }
            try JSONEncoder().encode(expected).write(to: marker, options: .atomic)
        }
        try ensureDirectory(context.appendingPathComponent("files", isDirectory: true))
        return SophonResumeCache(root: root, context: context, expectedKeys: Set(keys))
    }

    /// Establish the owner marker without adopting a non-empty unknown folder.
    static func ensureOwnedRoot(destination: URL, game: GameType) throws {
        let fm = FileManager.default
        let root = destination.appendingPathComponent(directoryName, isDirectory: true)
        if !exists(root) {
            try fm.createDirectory(at: root, withIntermediateDirectories: false)
            do {
                let owner = Owner(format: formatVersion, game: game, region: "cn", destination: destination.path)
                try JSONEncoder().encode(owner).write(to: root.appendingPathComponent("owner.json"), options: .atomic)
            } catch {
                if (try? fm.contentsOfDirectory(atPath: root.path).isEmpty) == true { try? fm.removeItem(at: root) }
                throw error
            }
        }
        guard try isOwned(at: destination, game: game) else { throw SophonProtocolError.corrupt("续传缓存不可用") }
    }

    /// Clean only a completely empty cache shell after its receipt was removed.
    static func cleanupEmptyOwnedRoot(destination: URL, game: GameType) throws {
        guard try isOwned(at: destination, game: game) else { return }
        let fm = FileManager.default
        let root = destination.appendingPathComponent(directoryName, isDirectory: true)
        var contents = Set(try fm.contentsOfDirectory(atPath: root.path))
        if contents == ["contexts", "owner.json"] {
            let contexts = root.appendingPathComponent("contexts", isDirectory: true)
            try requireDirectory(contexts)
            guard try fm.contentsOfDirectory(atPath: contexts.path).isEmpty else { return }
            try fm.removeItem(at: contexts)
            contents.remove("contexts")
        }
        guard contents == ["owner.json"] else { return }
        let owner = root.appendingPathComponent("owner.json")
        try requireRegular(owner)
        try fm.removeItem(at: owner)
        if try fm.contentsOfDirectory(atPath: root.path).isEmpty { try fm.removeItem(at: root) }
    }

    func locations(for path: String) throws -> (key: String, data: URL, checkpoint: URL) {
        try validateAncestors()
        let key = Self.hash(path)
        guard expectedKeys.contains(key) else { throw SophonProtocolError.corrupt("续传文件不属于当前清单") }
        let directory = context.appendingPathComponent("files", isDirectory: true)
        try Self.requireDirectory(directory)
        let data = directory.appendingPathComponent(key + ".data")
        let checkpoint = directory.appendingPathComponent(key + ".json")
        if Self.exists(data) { try Self.requireRegular(data) }
        if Self.exists(checkpoint) { try Self.requireRegular(checkpoint) }
        return (key, data, checkpoint)
    }

    func checkpoint(at url: URL, key: String, count: Int, dataExists: Bool) throws -> Checkpoint {
        try validateAncestors()
        let byteCount = (count + 7) / 8
        guard Self.exists(url) else {
            guard !dataExists else { throw SophonProtocolError.corrupt("续传缓存数据缺少归属记录") }
            let initial = Checkpoint(format: Self.formatVersion, key: key, bits: Data(count: byteCount))
            try createCheckpoint(initial, at: url)
            return initial
        }
        try Self.requireRegular(url)
        let attrs = try manager.attributesOfItem(atPath: url.path)
        guard ((attrs[.size] as? NSNumber)?.intValue ?? Int.max) <= byteCount * 4 + 2048 else {
            throw SophonProtocolError.corrupt("续传缓存记录无效")
        }
        guard let decoded = try? JSONDecoder().decode(Checkpoint.self, from: Data(contentsOf: url)),
              decoded.format == Self.formatVersion, decoded.key == key, decoded.bits.count == byteCount else {
            throw SophonProtocolError.corrupt("续传缓存记录损坏，已保留现有文件")
        }
        return decoded
    }

    /// Conservative estimate from persisted checkpoints and actual file
    /// lengths. Flagged chunks are rehashed by the downloader before use;
    /// a separate per-batch free-space check covers corrupt checkpoints and
    /// concurrent changes in available space.
    func estimatedRemainingBytes(for file: SophonFile) throws -> UInt64 {
        let location = try locations(for: file.path)
        guard Self.exists(location.data) else { return file.size }
        let checkpoint = try checkpoint(at: location.checkpoint, key: location.key,
                                        count: file.chunks.count, dataExists: true)
        let attrs = try manager.attributesOfItem(atPath: location.data.path)
        let currentSize = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        var remaining: UInt64 = 0
        for (index, chunk) in file.chunks.enumerated() {
            let end = chunk.offset + chunk.uncompressedSize
            if checkpoint.contains(index), end <= currentSize { continue }
            guard remaining <= UInt64.max - chunk.uncompressedSize else {
                throw SophonProtocolError.corrupt("预下载资源大小溢出")
            }
            remaining += chunk.uncompressedSize
        }
        return remaining
    }

    func save(_ checkpoint: Checkpoint, to url: URL) throws {
        try validateAncestors()
        if Self.exists(url) { try Self.requireRegular(url) }
        try JSONEncoder().encode(checkpoint).write(to: url, options: .atomic)
    }

    /// Install a fully written initial ownership record without replacing any
    /// existing path, including a dangling symbolic link.
    private func createCheckpoint(_ checkpoint: Checkpoint, at url: URL) throws {
        let temporary = url.deletingLastPathComponent().appendingPathComponent(".checkpoint-\(UUID().uuidString).tmp")
        let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else { throw SophonProtocolError.corrupt("无法创建续传记录") }
        defer { _ = Darwin.unlink(temporary.path) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: JSONEncoder().encode(checkpoint))
            try handle.synchronize()
            try handle.close()
        } catch { try? handle.close(); throw error }
        guard Darwin.link(temporary.path, url.path) == 0 else { throw SophonProtocolError.corrupt("续传记录已存在或无法安全创建") }
    }

    /// Remove only files explicitly named by the validated context manifest.
    /// Unknown or symbolic-link entries are left alone and prevent directory removal.
    func cleanup(ownedKeys: Set<String>, preservingContext: Bool = false) throws {
        try validateAncestors()
        guard ownedKeys.isSubset(of: expectedKeys) else { throw SophonProtocolError.corrupt("续传清理范围无效") }
        let directory = context.appendingPathComponent("files", isDirectory: true)
        try Self.requireDirectory(directory)
        for key in ownedKeys {
            for suffix in [".data", ".json"] {
                let url = directory.appendingPathComponent(key + suffix)
                if Self.exists(url) {
                    try Self.requireRegular(url)
                    try manager.removeItem(at: url)
                }
            }
        }
        if preservingContext { return }
        guard try manager.contentsOfDirectory(atPath: directory.path).isEmpty else { return }
        guard Set(try manager.contentsOfDirectory(atPath: context.path)) == ["files", "context.json"] else { return }
        try manager.removeItem(at: directory)
        let marker = context.appendingPathComponent("context.json")
        try Self.requireRegular(marker)
        try manager.removeItem(at: marker)
        guard try manager.contentsOfDirectory(atPath: context.path).isEmpty else { return }
        try manager.removeItem(at: context)
        let contexts = root.appendingPathComponent("contexts", isDirectory: true)
        guard try manager.contentsOfDirectory(atPath: contexts.path).isEmpty else { return }
        guard Set(try manager.contentsOfDirectory(atPath: root.path)) == ["contexts", "owner.json"] else { return }
        try manager.removeItem(at: contexts)
        let owner = root.appendingPathComponent("owner.json")
        try Self.requireRegular(owner)
        try manager.removeItem(at: owner)
        if try manager.contentsOfDirectory(atPath: root.path).isEmpty { try manager.removeItem(at: root) }
    }

    static func hash(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private func validateAncestors() throws {
        try Self.requireDirectory(root)
        try Self.requireRegular(root.appendingPathComponent("owner.json"))
        try Self.requireDirectory(root.appendingPathComponent("contexts", isDirectory: true))
        try Self.requireDirectory(context)
        try Self.requireRegular(context.appendingPathComponent("context.json"))
        try Self.requireDirectory(context.appendingPathComponent("files", isDirectory: true))
    }
    private static func exists(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path)) != nil
    }
    private static func ensureDirectory(_ url: URL) throws {
        let fm = FileManager.default
        if exists(url) { try requireDirectory(url) }
        else { try fm.createDirectory(at: url, withIntermediateDirectories: false) }
    }
    private static func requireDirectory(_ url: URL) throws {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attrs[.type] as? FileAttributeType == .typeDirectory else {
            throw SophonProtocolError.corrupt("续传目录无效或包含符号链接")
        }
    }
    private static func requireRegular(_ url: URL) throws {
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        guard attrs[.type] as? FileAttributeType == .typeRegular else {
            throw SophonProtocolError.corrupt("续传文件无效或为符号链接")
        }
    }
}
