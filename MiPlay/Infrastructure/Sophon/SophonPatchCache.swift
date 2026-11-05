import Foundation
import CryptoKit
import Darwin

/// An object is split into bounded independently checksummed cache files.
/// These SHA-256 checksums detect local cache corruption; authenticity is
/// established by checking the patched target against its official MD5.
nonisolated struct SophonPatchObject: Sendable {
    let id: String
    let size: UInt64
    let prefix: URL
    let suffix: String

    init(file: SophonPatchFile, category: SophonPatchCategory) {
        id = file.objectID; size = file.objectSize; prefix = category.prefix; suffix = category.suffix
    }
    init(id: String, size: UInt64, prefix: URL, suffix: String = "") {
        self.id = id; self.size = size; self.prefix = prefix; self.suffix = suffix
    }
}

actor SophonPatchCache {
    static let segmentSize: UInt64 = 4 * 1024 * 1024
    typealias Fetch = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)
    private let root: URL
    private let fetch: Fetch
    private let transport: SophonBoundedTransport?

    /// root must already exist, be private to the caller, and be protected by
    /// the caller's existing installation directory lock for the entire use.
    init(root: URL, session: URLSession = .shared) {
        self.root = root
        let transport = SophonBoundedTransport(configuration: session.configuration)
        self.transport = transport
        self.fetch = { request in try await transport.fetch(request, limit: Int(Self.segmentSize), requiredStatus: 206) }
    }
    /// Offline transport injection for deterministic tests.
    init(root: URL, fetch: @escaping Fetch) { self.root = root; self.fetch = fetch; self.transport = nil }
    deinit { transport?.invalidate() }

    /// Download or resume an object. The progress callback reports verified
    /// bytes in this object, including previously completed segments.
    func download(_ object: SophonPatchObject, ranges: [Range<UInt64>]? = nil,
                  beforeWrite: (@Sendable (UInt64) async throws -> Void)? = nil,
                  progress: (@Sendable (UInt64) async -> Void)? = nil) async throws {
        let (directory, key, url) = try openObject(object)
        defer { _ = Darwin.close(directory) }
        let lock = try openLock(directory, key)
        defer { _ = flock(lock, LOCK_UN); _ = Darwin.close(lock) }
        var completed: UInt64 = 0
        for index in try selectedSegments(object, ranges: ranges) {
            try Task.checkCancellation()
            let offset = index * Self.segmentSize
            let length = min(Self.segmentSize, object.size - offset)
            let name = "\(key)-\(index).part"
            if try readSegment(directory, name, expected: Int(length)) == nil {
                var request = URLRequest(url: url)
                request.setValue("bytes=\(offset)-\(offset + length - 1)", forHTTPHeaderField: "Range")
                request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
                let (data, http) = try await fetch(request)
                guard http.statusCode == 206, http.url?.scheme == "https", http.url?.host == url.host,
                      http.url?.port == url.port,
                      http.value(forHTTPHeaderField: "Content-Range")?.lowercased() == "bytes \(offset)-\(offset + length - 1)/\(object.size)",
                      data.count == Int(length) else {
                    throw SophonProtocolError.invalidResponse("补丁分段响应不匹配")
                }
                try Task.checkCancellation()
                try await beforeWrite?(length + 32)
                try Task.checkCancellation()
                try storeSegment(directory, name, data: data)
            }
            completed += length
            await progress?(completed)
        }
    }

    /// Counts selected transfer bytes after expanding to cache segments and
    /// removing overlaps. Includes bytes already cached, but not SHA headers.
    func selectedBytes(_ object: SophonPatchObject, ranges: [Range<UInt64>]? = nil) throws -> UInt64 {
        var total: UInt64 = 0
        for index in try selectedSegments(object, ranges: ranges) {
            let offset = index * Self.segmentSize
            let length = min(Self.segmentSize, object.size - offset)
            guard total <= UInt64.max - length else { throw SophonProtocolError.corrupt("补丁分段大小溢出") }
            total += length
        }
        return total
    }

    /// Conservatively account for each missing data segment and SHA-256
    /// header. Existing segments are rehashed; corrupt ones are discarded.
    func estimatedRemainingBytes(_ object: SophonPatchObject, ranges: [Range<UInt64>]? = nil) throws -> UInt64 {
        let (directory, key, _) = try openObject(object)
        defer { _ = Darwin.close(directory) }
        let lock = try openLock(directory, key)
        defer { _ = flock(lock, LOCK_UN); _ = Darwin.close(lock) }
        var bytes: UInt64 = 0
        for index in try selectedSegments(object, ranges: ranges) {
            try Task.checkCancellation()
            let offset = index * Self.segmentSize
            let length = min(Self.segmentSize, object.size - offset)
            if try readSegment(directory, "\(key)-\(index).part", expected: Int(length)) == nil {
                guard bytes <= UInt64.max - length - 32 else { throw SophonProtocolError.corrupt("补丁缓存空间大小溢出") }
                bytes += length + 32
            }
        }
        return bytes
    }

    /// Revalidates each cached segment while copying. The caller owns the
    /// output handle and must verify the patched target against official MD5.
    func copy(_ object: SophonPatchObject, range: Range<UInt64>? = nil, to output: FileHandle) throws {
        let (directory, key, _) = try openObject(object)
        defer { _ = Darwin.close(directory) }
        let lock = try openLock(directory, key)
        defer { _ = flock(lock, LOCK_UN); _ = Darwin.close(lock) }
        let requested = range ?? 0..<object.size
        for index in try selectedSegments(object, ranges: [requested]) {
            try Task.checkCancellation()
            let offset = index * Self.segmentSize
            let length = min(Self.segmentSize, object.size - offset)
            guard let data = try readSegment(directory, "\(key)-\(index).part", expected: Int(length)) else {
                throw SophonProtocolError.corrupt("补丁缓存不完整或已损坏")
            }
            let lower = Int(max(requested.lowerBound, offset) - offset)
            let upper = Int(min(requested.upperBound, offset + length) - offset)
            try output.write(contentsOf: data.subdata(in: lower..<upper))
        }
    }

    /// Invalidates only ordinary cache files in the requested ranges. Call
    /// after a patched target fails its official MD5 and before retry/fallback.
    func invalidate(_ object: SophonPatchObject, ranges: [Range<UInt64>]? = nil) throws {
        let (directory, key, _) = try openObject(object)
        defer { _ = Darwin.close(directory) }
        let lock = try openLock(directory, key)
        defer { _ = flock(lock, LOCK_UN); _ = Darwin.close(lock) }
        for index in try selectedSegments(object, ranges: ranges) {
            try Task.checkCancellation()
            let offset = index * Self.segmentSize
            let name = "\(key)-\(index).part"
            if try readSegment(directory, name, expected: Int(min(Self.segmentSize, object.size - offset))) != nil {
                guard unlinkat(directory, name, 0) == 0 else { throw POSIXError(.EIO) }
            }
        }
    }

    /// After a successful update, remove only intact segments and locks whose
    /// names belong to the supplied official objects. Unknown, corrupt,
    /// linked or busy entries are preserved. The caller must hold the game
    /// directory lock and must not call this before the transaction commits.
    /// Returns true only when the entire patch directory was removed.
    @discardableResult
    func cleanup(objects: [SophonPatchObject]) throws -> Bool {
        var handled = Set<String>()
        for object in objects {
            let (directory, key, _) = try openObject(object)
            defer { _ = Darwin.close(directory) }
            guard handled.insert(key).inserted else { continue }
            let lockName = "\(key).lock"
            let lockFD = openat(directory, lockName, O_RDWR | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard lockFD >= 0 else { continue }
            defer { _ = Darwin.close(lockFD) }
            var lockInfo = stat()
            guard fstat(lockFD, &lockInfo) == 0, (lockInfo.st_mode & S_IFMT) == S_IFREG,
                  lockInfo.st_nlink == 1, lockInfo.st_size == 0,
                  flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { continue }
            defer { _ = flock(lockFD, LOCK_UN) }
            let entries = try FileManager.default.contentsOfDirectory(atPath: root.path)
            let prefix = "\(key)-", suffix = ".part"
            for name in entries where name.hasPrefix(prefix) && name.hasSuffix(suffix) {
                let number = String(name.dropFirst(prefix.count).dropLast(suffix.count))
                guard let index = UInt64(number), String(index) == number,
                      index <= (object.size - 1) / Self.segmentSize else { continue }
                let offset = index * Self.segmentSize
                let length = Int(min(Self.segmentSize, object.size - offset))
                try removeIntactSegment(directory, name, expected: length)
            }
            // Do not unlink a replaced lock file or a lock with unexpected data.
            var current = stat()
            if fstatat(directory, lockName, &current, AT_SYMLINK_NOFOLLOW) == 0,
               current.st_dev == lockInfo.st_dev, current.st_ino == lockInfo.st_ino,
               current.st_nlink == 1, current.st_size == 0, (current.st_mode & S_IFMT) == S_IFREG {
                _ = unlinkat(directory, lockName, 0)
            }
        }
        // rmdir never removes contents; unknown entries therefore survive.
        // Verify the pathname still names the opened directory first.
        guard let first = objects.first else { return false }
        let (directory, _, _) = try openObject(first)
        defer { _ = Darwin.close(directory) }
        var opened = stat(), named = stat()
        guard fstat(directory, &opened) == 0, lstat(root.path, &named) == 0,
              (named.st_mode & S_IFMT) == S_IFDIR,
              opened.st_dev == named.st_dev, opened.st_ino == named.st_ino else { return false }
        return rmdir(root.path) == 0
    }

    private func removeIntactSegment(_ directory: Int32, _ name: String, expected: Int) throws {
        let fd = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var opened = stat(), named = stat()
        guard fstat(fd, &opened) == 0, (opened.st_mode & S_IFMT) == S_IFREG,
              opened.st_nlink == 1, opened.st_size == expected + 32,
              let all = try handle.readToEnd(), all.count == expected + 32,
              Data(all.prefix(32)) == Data(SHA256.hash(data: all.dropFirst(32))),
              fstatat(directory, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
              named.st_dev == opened.st_dev, named.st_ino == opened.st_ino,
              named.st_nlink == 1, (named.st_mode & S_IFMT) == S_IFREG else { return }
        _ = unlinkat(directory, name, 0)
    }

    private func selectedSegments(_ object: SophonPatchObject, ranges: [Range<UInt64>]?) throws -> [UInt64] {
        guard object.size > 0, object.size <= UInt64(Int64.max) else {
            throw SophonProtocolError.corrupt("补丁对象大小无效")
        }
        let ranges = ranges ?? [0..<object.size]
        var indices = Set<UInt64>()
        for range in ranges {
            guard !range.isEmpty, range.upperBound <= object.size else { throw SophonProtocolError.corrupt("补丁范围无效") }
            let first = range.lowerBound / Self.segmentSize, last = (range.upperBound - 1) / Self.segmentSize
            // Bound untrusted metadata before allocating the segment index set.
            guard last - first <= 1_000_000 else { throw SophonProtocolError.corrupt("补丁分段数量超限") }
            for index in first...last { indices.insert(index) }
        }
        return indices.sorted()
    }

    private func openObject(_ object: SophonPatchObject) throws -> (Int32, String, URL) {
        guard root.isFileURL, root.path.hasPrefix("/"), root.path != "/",
              SophonPatchClient.safeComponent(object.id), object.size > 0, object.size <= UInt64(Int64.max),
              let prefix = SophonPatchClient.safePrefix(object.prefix.absoluteString),
              SophonPatchClient.safeSuffix(object.suffix),
              let url = URL(string: prefix.appendingPathComponent(object.id).absoluteString + object.suffix) else {
            throw SophonProtocolError.corrupt("补丁缓存参数无效")
        }
        // App Sandbox may grant the cache directory without granting access to
        // every ancestor. Resolve first, then verify the opened descriptor's
        // canonical path, and use openat/O_NOFOLLOW for all descendants.
        guard let resolved = realpath(root.path, nil) else { throw SophonProtocolError.corrupt("补丁缓存目录不存在") }
        let canonical = String(cString: resolved)
        free(resolved)
        let requested = root.standardizedFileURL.path
        // Foundation exposes the system /var and /tmp aliases even when URL
        // resolvingSymlinksInPath() was requested. Permit only these aliases.
        let expected: String
        if requested == "/var" || requested.hasPrefix("/var/") { expected = "/private" + requested }
        else if requested == "/tmp" || requested.hasPrefix("/tmp/") { expected = "/private" + requested }
        else { expected = requested }
        guard canonical == expected else { throw SophonProtocolError.corrupt("补丁缓存路径包含符号链接") }
        let directory = Darwin.open(canonical, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard directory >= 0 else { throw SophonProtocolError.corrupt("补丁缓存目录无法访问") }
        do {
            var actual = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            guard fcntl(directory, F_GETPATH, &actual) == 0, String(cString: actual) == canonical else {
                throw SophonProtocolError.corrupt("补丁缓存目录已发生变化")
            }
            // Signed URL query parameters can change between runs; object
            // identity is its host/path, id and declared size instead.
            let identity = "\(prefix.appendingPathComponent(object.id).absoluteString)\n\(object.size)\n\(Self.segmentSize)"
            let key = SHA256.hash(data: Data(identity.utf8)).map { String(format: "%02x", $0) }.joined()
            return (directory, key, url)
        } catch { _ = Darwin.close(directory); throw error }
    }
    private func openLock(_ directory: Int32, _ key: String) throws -> Int32 {
        let fd = openat(directory, "\(key).lock", O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard fd >= 0 else { throw SophonProtocolError.corrupt("无法打开补丁缓存锁") }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1,
              flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            _ = Darwin.close(fd); throw SophonProtocolError.corrupt("补丁缓存正被占用或锁文件无效")
        }
        return fd
    }
    /// A corrupt ordinary file is removed and downloaded again. Links and other
    /// unknown filesystem objects are rejected without modification.
    private func readSegment(_ directory: Int32, _ name: String, expected: Int) throws -> Data? {
        let fd = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0 {
            if errno == ENOENT { return nil }
            throw SophonProtocolError.corrupt("补丁缓存文件无效")
        }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_nlink == 1 else {
            throw SophonProtocolError.corrupt("补丁缓存文件不安全")
        }
        guard info.st_size == expected + 32,
              let all = try handle.readToEnd(), all.count == expected + 32 else {
            guard unlinkat(directory, name, 0) == 0 else { throw POSIXError(.EIO) }
            return nil
        }
        let data = all.dropFirst(32)
        guard Data(all.prefix(32)) == Data(SHA256.hash(data: data)) else {
            guard unlinkat(directory, name, 0) == 0 else { throw POSIXError(.EIO) }
            return nil
        }
        return Data(data)
    }
    private func storeSegment(_ directory: Int32, _ name: String, data: Data) throws {
        let tmp = ".patch-\(UUID().uuidString).tmp"
        let fd = openat(directory, tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard fd >= 0 else { throw SophonProtocolError.corrupt("无法创建补丁缓存") }
        defer { _ = unlinkat(directory, tmp, 0) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        do {
            try handle.write(contentsOf: Data(SHA256.hash(data: data)))
            try handle.write(contentsOf: data)
            try handle.synchronize()
            try handle.close()
        } catch { try? handle.close(); throw error }
        guard renameatx_np(directory, tmp, directory, name, UInt32(RENAME_EXCL)) == 0 else {
            throw SophonProtocolError.corrupt("补丁缓存文件已存在或无法创建")
        }
        guard fsync(directory) == 0 else { throw POSIXError(.EIO) }
    }
}
