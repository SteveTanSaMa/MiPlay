// Source: Implementation maintenance split -> Wine catalog and HTTP asset semantics
import XCTest
import Observation
import CryptoKit
import Darwin
@testable import MiPlay

private final class SophonResumeProgressEvidence: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int64] = []

    var downloadBytes: [Int64] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }

    func record(_ progress: SophonProgress) {
        guard progress.bytesTotal != nil, progress.message.contains("下载") else { return }
        lock.lock()
        values.append(progress.bytesCompleted)
        lock.unlock()
    }
}

private final class SophonScanProgressEvidence: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [SophonProgress] = []
    func record(_ progress: SophonProgress) {
        lock.lock()
        recorded.append(progress)
        lock.unlock()
    }
    var values: [SophonProgress] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
}

private actor SophonIncrementalProgressProbe {
    private var cancelled = false
    private var peakTemporaryBytes: UInt64 = 0
    private var installedPaths: [String] = []

    /// Measure distinct temporary file inodes, excluding data already linked
    /// into an installed target. This also catches retained FULL caches without
    /// counting a cache/staged hard link as two physical copies.
    func observe(_ progress: SophonProgress, root: URL, targets: [String: Data], pauseAfterFirstFile: Bool) -> Bool {
        let fm = FileManager.default
        var installedInodes = Set<String>()
        for path in targets.keys {
            var info = stat()
            if lstat(root.appendingPathComponent(path).path, &info) == 0 {
                installedInodes.insert("\(info.st_dev):\(info.st_ino)")
            }
        }
        var seen = Set<String>()
        var bytes: UInt64 = 0
        for directory in [SophonInstaller.transactionDirectoryName, SophonInstaller.resumeDirectoryName] {
            let entries = fm.enumerator(at: root.appendingPathComponent(directory), includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []
            for url in entries {
                var info = stat()
                guard lstat(url.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, info.st_size >= 0 else { continue }
                let inode = "\(info.st_dev):\(info.st_ino)"
                if !installedInodes.contains(inode), seen.insert(inode).inserted { bytes += UInt64(info.st_size) }
            }
        }
        peakTemporaryBytes = max(peakTemporaryBytes, bytes)
        guard progress.message.hasPrefix("已安装 ") else { return false }
        installedPaths = targets.keys.sorted().filter { (try? Data(contentsOf: root.appendingPathComponent($0))) == targets[$0] }
        if pauseAfterFirstFile, !cancelled, !installedPaths.isEmpty, installedPaths.count < targets.count {
            cancelled = true
            return true
        }
        return false
    }

    func snapshot() -> (peakTemporaryBytes: UInt64, installedPaths: [String]) { (peakTemporaryBytes, installedPaths) }
}

nonisolated private final class BackgroundRetentionRequestProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var requested = false
    func record() { lock.lock(); requested = true; lock.unlock() }
    var hasRequest: Bool { lock.lock(); defer { lock.unlock() }; return requested }
}

@MainActor extension MiPlayCoreTests {
    func testStreamingFileHasherKeepsMemoryBoundedAndVerifiesRegions() throws {
        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("large-sparse-file")
        XCTAssertTrue(FileManager.default.createFile(atPath: url.path, contents: nil))
        let size = 256 * 1024 * 1024
        let writer = try FileHandle(forWritingTo: url)
        try writer.truncate(atOffset: UInt64(size))
        try writer.close()

        // A sparse fixture lets us exercise hundreds of reads without using
        // hundreds of MB of actual disk space or test-owned heap memory.
        let zeroBlock = Data(count: 1024 * 1024)
        var expected = Insecure.MD5()
        for _ in 0..<256 { expected.update(data: zeroBlock) }
        let expectedDigest = expected.finalize().map { String(format: "%02x", $0) }.joined()

        let reader = try StreamingFileHasher<Insecure.MD5>(path: url.path)
        defer { reader.close() }
        let baseline = try self.residentMemoryForStreamingTest()
        var peak = baseline
        var count = 0
        while true {
            let read = try reader.readNext()
            if read == 0 { break }
            XCTAssertLessThanOrEqual(read, 1024 * 1024)
            count += read
            peak = max(peak, try self.residentMemoryForStreamingTest())
        }
        XCTAssertEqual(count, size)
        XCTAssertEqual(reader.digest(), expectedDigest)
        XCTAssertLessThan(peak > baseline ? peak - baseline : 0, 128 * 1024 * 1024,
                          "读取 256 MiB 文件时，哈希内存不应随文件大小增长")

        let region = try reader.hash(offset: UInt64(size - 200), length: 1_000)
        XCTAssertEqual(region.bytes, 200, "截断的缓存分块必须作为短读处理")
        XCTAssertEqual(region.digest, Insecure.MD5.hash(data: Data(count: 200)).map { String(format: "%02x", $0) }.joined())
        let middle = try reader.hash(offset: UInt64(size / 2), length: 1024 * 1024 + 17)
        XCTAssertEqual(middle.bytes, 1024 * 1024 + 17)
        XCTAssertEqual(middle.digest, Insecure.MD5.hash(data: Data(count: 1024 * 1024 + 17)).map { String(format: "%02x", $0) }.joined())
    }

    private func residentMemoryForStreamingTest() throws -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { throw POSIXError(.EIO) }
        return UInt64(info.resident_size)
    }

    /// Explicit real-game acceptance only. Uses a temporary task store and the
    /// user's existing scoped bookmark; the installer writes only its owned
    /// predownload cache, never the game files or the user's AppData.
    func testLiveLocatedGenshinPredownload() async throws {
        guard ProcessInfo.processInfo.environment["MIPLAY_LIVE_PREDOWNLOAD"] == "1" else {
            throw XCTSkip("Set TEST_RUNNER_MIPLAY_LIVE_PREDOWNLOAD=1 for explicit real-game acceptance")
        }
        let data = try await PersistenceStore().readAppData()
        let game = try XCTUnwrap(data.games.first { $0.type == .genshinImpact && $0.location?.bookmarkData != nil })
        let location = try XCTUnwrap(game.location)
        let repository = GameFileSystemRepository()
        let access = try repository.acquireSecurityScopedAccess(location)
        defer { access.stop() }
        let configURL = access.url.appendingPathComponent("config.ini")
        let configBefore = try Data(contentsOf: configURL)
        let installer = SophonInstaller()
        let pending = await installer.hasPendingTransaction(destination: access.url)
        XCTAssertFalse(pending, "Real-game acceptance requires no unfinished transaction")
        guard !pending else { return }
        let available = try await SophonMetadataClient().fetchPreDownloadVersion(for: .genshinImpact)
        let target = try XCTUnwrap(available)
        let fixture = try await makeScheduler(games: [game])
        var lastFailure = ""
        for attempt in 1...3 {
            // Subscribe before enqueue so short phases and the final resource
            // count are not lost when the scheduler removes terminal metrics.
            let progressStream = await fixture.scheduler.makeProgressStream()
            let current = await fixture.registry.getGame(by: game.id)
            let bookmark = try XCTUnwrap(current?.location?.bookmarkData)
            let taskID = try await fixture.scheduler.enqueue(type: .gamePredownload, gameId: game.id,
                                                               context: ["predownloadVersion": target,
                                                                         "predownloadLocationBookmark": bookmark.base64EncodedString()])
            var stageMaxBytes: [String: Int64] = [:]
            var finalResourceBytes: Int64?
            var blockedFullTotal: Int64?
            let monitor = Task { @MainActor in
                for await update in progressStream where update.taskId == taskID {
                    guard let download = update.download else { continue }
                    let phase = update.phase
                    if phase.contains("预下载差分资源") {
                        stageMaxBytes["patch"] = max(stageMaxBytes["patch"] ?? 0, download.bytesReceived)
                    } else if phase.contains("预下载完整资源") || phase.contains("预下载游戏资源") {
                        stageMaxBytes["full"] = max(stageMaxBytes["full"] ?? 0, download.bytesReceived)
                        // Avoid an unexpected tens-of-GB FULL fallback. This
                        // is detected from scheduler progress, so a first
                        // batch can already be in flight when we cancel.
                        if download.totalBytes > 2 * 1024 * 1024 * 1024, blockedFullTotal == nil {
                            blockedFullTotal = download.totalBytes
                            NSLog("LIVE_PREDOWNLOAD cancelling oversized FULL phase total=%lld", download.totalBytes)
                            try? await fixture.scheduler.cancel(taskId: taskID)
                        }
                    } else if phase.contains("预下载缓存已就绪") {
                        finalResourceBytes = download.bytesReceived
                    }
                }
            }
            defer { monitor.cancel() }
            let deadline = Date().addingTimeInterval(6 * 60 * 60)
            var lastReport = Date.distantPast
            while Date() < deadline {
                let snapshot = try await fixture.scheduler.taskSnapshot(id: taskID)
                if Date().timeIntervalSince(lastReport) >= 20 {
                    let transfer = await fixture.scheduler.downloadProgressDetails[taskID]
                    NSLog("LIVE_PREDOWNLOAD attempt=%d phase=%@ progress=%.4f received=%lld total=%lld", attempt,
                          snapshot.phaseDescription, snapshot.progress ?? -1,
                          transfer?.bytesReceived ?? 0, transfer?.totalBytes ?? 0)
                    lastReport = Date()
                }
                if snapshot.state == .completed {
                    // Give the already-buffered progress event a chance to run
                    // before reporting the final resource count.
                    try await Task.sleep(for: .milliseconds(100))
                    if let blockedFullTotal {
                        XCTFail("完整资源阶段超过 2 GiB：\(blockedFullTotal)；已请求取消")
                        return
                    }
                    XCTAssertEqual(snapshot.outcome, "gamePredownloaded")
                    let after = await fixture.registry.getGame(by: game.id)
                    XCTAssertEqual(after?.state, game.state)
                    XCTAssertEqual(after?.version, game.version)
                    XCTAssertEqual(try Data(contentsOf: configURL), configBefore)
                    let stillPending = await installer.hasPendingTransaction(destination: access.url)
                    XCTAssertFalse(stillPending)
                    NSLog("LIVE_PREDOWNLOAD completed version=%@ patchResourceBytes=%lld fullResourceBytes=%lld finalResourceBytes=%lld (resource progress includes reused cache; not exact network traffic)",
                          target, stageMaxBytes["patch"] ?? 0, stageMaxBytes["full"] ?? 0, finalResourceBytes ?? -1)
                    return
                }
                if snapshot.state == .failed || snapshot.state == .cancelled {
                    if let blockedFullTotal {
                        XCTFail("完整资源阶段超过 2 GiB：\(blockedFullTotal)；已取消并保留缓存")
                        return
                    }
                    lastFailure = snapshot.error ?? snapshot.recovery ?? snapshot.phaseDescription
                    NSLog("LIVE_PREDOWNLOAD attempt=%d failed=%@", attempt, lastFailure)
                    break
                }
                try await Task.sleep(for: .milliseconds(250))
            }
            if attempt < 3 { try await Task.sleep(for: .seconds(5 * attempt)) }
        }
        XCTFail("真实预下载未完成：\(lastFailure)")
    }

    /// Opt-in acceptance of the installed game against the current official
    /// Sophon full manifests. Reads the game and bookmark only; never creates a
    /// cache, downloads game assets, changes registry data, or repairs files.
    func testLiveGenshinOfficialSophonIntegrity() async throws {
        guard ProcessInfo.processInfo.environment["MIPLAY_LIVE_SOPHON_INTEGRITY"] == "1" else {
            throw XCTSkip("Set TEST_RUNNER_MIPLAY_LIVE_SOPHON_INTEGRITY=1 for read-only real-game acceptance")
        }
        let appData = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MiPlay/AppData.json")
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: appData)) as? [String: Any])
        let games = try XCTUnwrap(object["games"] as? [[String: Any]])
        let game = try XCTUnwrap(games.first { $0["type"] as? String == "GenshinImpact" })
        let location = try XCTUnwrap(game["location"] as? [String: Any])
        let encoded = try XCTUnwrap(location["bookmarkData"] as? String)
        let bookmark = try XCTUnwrap(Data(base64Encoded: encoded))
        var stale = false
        let url = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale)
        guard !stale else { throw SophonProtocolError.unsupported("游戏目录授权已过期") }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let root = url.resolvingSymlinksInPath().standardizedFileURL
        let fm = FileManager.default
        guard !fm.fileExists(atPath: root.appendingPathComponent(SophonInstaller.transactionDirectoryName).path) else {
            throw SophonProtocolError.unsupported("游戏存在未完成的更新事务")
        }
        let config = try String(contentsOf: root.appendingPathComponent("config.ini"), encoding: .utf8)
        let versions = config.components(separatedBy: .newlines).compactMap { line -> String? in
            let pair = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            return pair.count == 2 && pair[0].lowercased() == "game_version" ? pair[1] : nil
        }
        guard versions.count == 1, let installedVersion = versions.first else {
            throw SophonProtocolError.corrupt("游戏配置版本无效")
        }
        let profiles = SophonGameProfile.audioResources(for: .genshinImpact)
        var audio = Set(profiles.compactMap { language, marker, directory in
            fm.fileExists(atPath: root.appendingPathComponent("Audio_\(marker)_pkg_version").path) ||
            fm.fileExists(atPath: root.appendingPathComponent(directory).path) ? language : nil
        })
        if audio.isEmpty { audio = ["zh-cn"] }
        let client = SophonMetadataClient()
        let build = try await client.fetchBuild(for: .genshinImpact, audioLanguages: audio)
        guard installedVersion == build.version else {
            throw SophonProtocolError.unsupported("安装版本 \(installedVersion) 与官方正式版本 \(build.version) 不一致")
        }
        var files: [String: SophonFile] = [:]
        for category in build.categories {
            for entry in try await client.downloadManifest(category) {
                guard SophonPatchClient.safePath(entry.path), entry.flags == 0 || entry.flags == 64 else {
                    throw SophonProtocolError.corrupt("清单路径或类型无效：\(entry.path)")
                }
                if entry.flags == 64 { continue }
                guard SophonPatchClient.isMD5(entry.md5), entry.size <= UInt64(Int64.max) else {
                    throw SophonProtocolError.corrupt("清单文件校验信息无效：\(entry.path)")
                }
                let key = entry.path.lowercased()
                if let existing = files[key], existing != entry {
                    throw SophonProtocolError.corrupt("资源分类存在冲突：\(entry.path)")
                }
                files[key] = entry
            }
        }
        guard !files.isEmpty else { throw SophonProtocolError.corrupt("官方游戏清单为空") }
        NSLog("LIVE_SOPHON_INTEGRITY start version=%@ audio=%@ files=%d", build.version, audio.sorted().joined(separator: ","), files.count)
        var failures: [String] = []
        var checked = 0
        for entry in files.values.sorted(by: { $0.path < $1.path }) {
            try Task.checkCancellation()
            var target = root
            var pathSafe = true
            for component in entry.path.split(separator: "/") {
                target.appendPathComponent(String(component))
                var info = stat()
                if lstat(target.path, &info) != 0 || (info.st_mode & S_IFMT) == S_IFLNK {
                    pathSafe = false
                    break
                }
            }
            if !pathSafe {
                failures.append("缺失或路径不安全：\(entry.path)")
            } else {
                do {
                    let reader = try StreamingFileHasher<Insecure.MD5>(path: target.path)
                    let result = try reader.hash()
                    reader.close()
                    if result.bytes != entry.size || result.digest != entry.md5.lowercased() {
                        failures.append("大小或 MD5 不一致：\(entry.path)")
                    }
                } catch {
                    failures.append("读取失败：\(entry.path): \(error.localizedDescription)")
                }
            }
            checked += 1
            if checked % 100 == 0 || checked == files.count {
                NSLog("LIVE_SOPHON_INTEGRITY progress=%d/%d failed=%d", checked, files.count, failures.count)
            }
        }
        NSLog("LIVE_SOPHON_INTEGRITY completed version=%@ checked=%d failed=%d", build.version, checked, failures.count)
        XCTAssertTrue(failures.isEmpty, "官方清单校验失败，共 \(failures.count) 项：\n\(failures.prefix(100).joined(separator: "\n"))")
    }

    func testSophonManifestDecodesDirectoryRepeatedChunksAndLargeOffsets() throws {
        let files = try SophonManifestDecoder.decode(sophonSyntheticManifestFixture())

        XCTAssertEqual(files.count, 2)
        XCTAssertEqual(files[0].path, "YuanShen_Data")
        XCTAssertEqual(files[0].flags, 64)
        XCTAssertTrue(files[0].chunks.isEmpty)
        let file = files[1]
        XCTAssertEqual(file.path, "YuanShen_Data/StreamingAssets/data.bin")
        XCTAssertEqual(file.size, 4_294_967_318)
        XCTAssertEqual(file.md5, "0123456789abcdef0123456789abcdef")
        XCTAssertEqual(file.chunks.count, 2)
        XCTAssertEqual(file.chunks[0].offset, 0)
        XCTAssertEqual(file.chunks[0].compressedSize, 3)
        XCTAssertEqual(file.chunks[0].uncompressedSize, 3)
        XCTAssertEqual(file.chunks[0].xxhash, 99)
        XCTAssertEqual(file.chunks[1].name, "fedcba9876543210_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
        XCTAssertEqual(file.chunks[1].md5, "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
        XCTAssertEqual(file.chunks[1].offset, 4_294_967_305)
        XCTAssertEqual(file.chunks[1].compressedSize, 8)
        XCTAssertEqual(file.chunks[1].uncompressedSize, 13)
        XCTAssertEqual(file.chunks[1].xxhash, UInt64.max)
        XCTAssertTrue(try SophonManifestDecoder.decode(Data()).isEmpty)
    }

    func testSophonManifestRejectsMalformedProtobuf() throws {
        let cases: [(String, Data)] = [
            ("zero field number", Data([0x00])),
            ("truncated message", Data([0x0a, 0x05, 0x0a])),
            ("truncated varint", Data([0x08, 0x80])),
            ("invalid UTF-8 path", Data([0x0a, 0x03, 0x0a, 0x01, 0xff])),
            ("unsupported wire type", Data([0x0b])),
            ("truncated file field", Data([0x0a, 0x02, 0x18, 0x80])),
            ("truncated nested chunk", Data([0x0a, 0x04, 0x12, 0x03, 0x0a, 0x05])),
            ("truncated fixed64", Data([0x59, 0x01])),
            ("truncated fixed32", Data([0x6d, 0x01])),
            ("overflowing varint", Data([0x50] + Array(repeating: 0xff, count: 9) + [0x02])),
        ]
        for (reason, data) in cases {
            XCTAssertThrowsError(try SophonManifestDecoder.decode(data), reason)
        }
    }

    func testSophonZstdDecodesOfficialManifestAndRejectsCorruptSizes() throws {
        // Read-only official CN ZZZ 3.3.0 category 72108 manifest:
        // manifest_2b289cac252a9f3d_5cb659f826e54c38eed36ea39f6a3063.
        // Captured from autopatchcn.juequling.com; only the 220-byte manifest
        // is embedded, with no game asset download or runtime dependency.
        let compressed = try XCTUnwrap(Data(base64Encoded:
            "KLUv/UQAGgBtBgDCjC8vkCkNv4q3xpkrOPRTQPpkU21Kz8gNBKB/kX69q4pgnTMwM6W/95IsMDKvcX0K4QECDWXCMIg7Po4lc/AfRghB7aHG5IsfHR0ZAoaFREVlohLxQMEayiSggbhgmIaD3+/nw+w8hy4d5x7mFvv9fH5was2Pa+xA+Sb0fsfCaGhErGSgsWmCNK3qlSCs9iqifE4aq1qwGC5doFdG62Gwqk+asOx1ayMFikbaq3uw+vZjqpVLTlXJWodQLsUFwGEJAwDqhRF+UThMeswzY+TTrA=="
        ))
        let decoded = try SophonZstd.decompress(compressed, expectedSize: 282, limit: 282)
        let files = try SophonManifestDecoder.decode(decoded)

        XCTAssertEqual(compressed.count, 220)
        XCTAssertEqual(decoded.count, 282)
        XCTAssertEqual(files.count, 1)
        let file = try XCTUnwrap(files.first)
        XCTAssertEqual(file.path, "ZenlessZoneZero_Data/StreamingAssets/Video/HD/Activity/ForbiddenArea/Tutorial_ForbiddenArea_06.usm")
        XCTAssertEqual(file.flags, 0)
        XCTAssertEqual(file.size, 597_920)
        XCTAssertEqual(file.md5, "985fdf8ab6553772ce9e82553df8af97")
        XCTAssertEqual(file.chunks.count, 1)
        XCTAssertEqual(file.chunks[0].offset, 0)
        XCTAssertEqual(file.chunks[0].compressedSize, 593_918)
        XCTAssertEqual(file.chunks[0].uncompressedSize, 597_920)
        // This current official chunk contains an additional field 7, which
        // must remain compatible with the known manifest fields above.
        XCTAssertEqual(file.chunks[0].md5, file.md5)

        XCTAssertThrowsError(try SophonZstd.decompress(compressed, expectedSize: 281))
        XCTAssertThrowsError(try SophonZstd.decompress(compressed, expectedSize: 283))
        XCTAssertThrowsError(try SophonZstd.decompress(compressed, expectedSize: -1))
        XCTAssertThrowsError(try SophonZstd.decompress(compressed, expectedSize: 282, limit: 281))
        XCTAssertThrowsError(try SophonZstd.decompress(Data(compressed.dropLast()), expectedSize: 282))
        XCTAssertThrowsError(try SophonZstd.decompress(Data(), expectedSize: 282))
        var corrupt = compressed
        corrupt[0] ^= 0xff
        XCTAssertThrowsError(try SophonZstd.decompress(corrupt, expectedSize: 282))
    }

    private func sophonSyntheticManifestFixture() throws -> Data {
        // Two files and two chunks, with uint64 boundary values and unknown
        // fields using varint, fixed64, length-delimited and fixed32 wires.
        try XCTUnwrap(Data(base64Encoded:
            "ChEKDVl1YW5TaGVuX0RhdGEYQAqbAgomWXVhblNoZW5fRGF0YS9TdHJlYW1pbmdBc3NldHMvZGF0YS5iaW4SXQoxMDEyMzQ1Njc4OWFiY2RlZl9hYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYRIgYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWFhYWEYACADKAMwYxJqCjFmZWRjYmE5ODc2NTQzMjEwX2JiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiEiBiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYmJiYhiJgICAECAIKA0w////////////ASCWgICAECogMDEyMzQ1Njc4OWFiY2RlZjAxMjM0NTY3ODlhYmNkZWZQBVkAAAAAAAAAAGIGZnV0dXJlbQAAAAA="
        ))
    }

    func testSophonPreDownloadVersionDetectionDoesNotTreatErrorsAsAbsence() async throws {
        let absent = SophonMetadataClient(session: try makeSophonInstallerSession(files: [:]))
        let noVersion = try await absent.fetchPreDownloadVersion(for: .genshinImpact)
        XCTAssertNil(noVersion)
        let available = SophonMetadataClient(session: try makeSophonInstallerSession(files: [:], branchVersion: "1.0.0", preDownloadVersion: "9.9.0"))
        let version = try await available.fetchPreDownloadVersion(for: .genshinImpact)
        XCTAssertEqual(version, "9.9.0")
        let stale = SophonMetadataClient(session: try makeSophonInstallerSession(files: [:], preDownloadVersion: "9.9.0"))
        let staleVersion = try await stale.fetchPreDownloadVersion(for: .genshinImpact)
        XCTAssertNil(staleVersion)
        let wrongGame = SophonMetadataClient(session: try makeSophonInstallerSession(files: [:], branchGameID: "wrong"))
        do { _ = try await wrongGame.fetchPreDownloadVersion(for: .genshinImpact); XCTFail("Invalid metadata must fail") }
        catch {}
    }

    func testSophonPreDownloadDoesNotChangeGameAndIsReusedByFormalUpdate() async throws {
        let destination = try makeTemporaryDirectory().resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: destination) }
        let oldConfig = try seedSophonMainlandInstallation(at: destination)
        let requests = destination.deletingLastPathComponent().appendingPathComponent("requests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: requests) }
        try Data().write(to: requests)
        let files = ["YuanShen.exe": Data("updated game executable".utf8), "resource.bin": Data("future release data".utf8)]
        let pre = SophonInstaller(session: try makeSophonInstallerSession(files: files, requests: requests, branchVersion: "1.0.0", chunkSize: 8, preDownloadVersion: "9.9.0"))
        let result = try await pre.preDownload(game: .genshinImpact, destination: destination, expectedVersion: "9.9.0") { _ in }
        XCTAssertEqual(result.version, "9.9.0")
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("YuanShen.exe"), encoding: .utf8), "original executable")
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("config.ini"), encoding: .utf8), oldConfig)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("resource.bin").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent(SophonInstaller.transactionDirectoryName).path))
        let initialRequests = try String(contentsOf: requests, encoding: .utf8)
        XCTAssertTrue(initialRequests.contains("chunk-"))

        try Data().write(to: requests)
        let update = SophonInstaller(session: try makeSophonInstallerSession(files: files, requests: requests, chunkSize: 8))
        _ = try await update.run(game: .genshinImpact, destination: destination, mode: .update) { _ in }
        try await update.finalizeCommittedUpdate(destination: destination, game: .genshinImpact)
        let updateRequests = try String(contentsOf: requests, encoding: .utf8)
        XCTAssertFalse(updateRequests.contains("chunk-"), "The released build must reuse verified pre-download chunks")
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("YuanShen.exe")), files["YuanShen.exe"])
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("resource.bin")), files["resource.bin"])
    }

    func testSophonPreDownloadRejectsChangedVersionBeforeCreatingCache() async throws {
        let destination = try makeTemporaryDirectory().resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: destination) }
        _ = try seedSophonMainlandInstallation(at: destination)
        let installer = SophonInstaller(session: try makeSophonInstallerSession(files: ["YuanShen.exe": Data("new".utf8)], branchVersion: "1.0.0", preDownloadVersion: "9.9.0"))
        do { _ = try await installer.preDownload(game: .genshinImpact, destination: destination, expectedVersion: "9.8.0") { _ in }; XCTFail("Stale selection must be rejected") }
        catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent(SophonInstaller.resumeDirectoryName).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent(SophonInstaller.transactionDirectoryName).path))
    }

    func testSophonPreDownloadRejectsInstalledSameOrNewerVersion() async throws {
        for installed in ["9.9.0", "10.0.0", "invalid"] {
            let destination = try makeTemporaryDirectory().resolvingSymlinksInPath()
            defer { try? FileManager.default.removeItem(at: destination) }
            _ = try seedSophonMainlandInstallation(at: destination)
            let config = "[General]\r\ngame_version=\(installed)\r\nchannel=1\r\nsub_channel=1\r\ncps=mihoyo\r\n"
            try config.write(to: destination.appendingPathComponent("config.ini"), atomically: true, encoding: .utf8)
            let installer = SophonInstaller(session: try makeSophonInstallerSession(
                files: ["YuanShen.exe": Data("new".utf8)], branchVersion: "1.0.0", preDownloadVersion: "9.9.0"
            ))
            do { _ = try await installer.preDownload(game: .genshinImpact, destination: destination, expectedVersion: "9.9.0") { _ in }; XCTFail("不应预下载相同、旧或无法比较的版本：\(installed)") }
            catch {}
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent(SophonInstaller.resumeDirectoryName).path))
            XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("config.ini"), encoding: .utf8), config)
        }
    }

    func testSophonPreDownloadSkipsHashWhenSizeDiffersAndReportsScanProgress() async throws {
        let destination = try makeTemporaryDirectory().resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: destination) }
        _ = try seedSophonMainlandInstallation(at: destination)
        let oldResource = destination.appendingPathComponent("old-resource.bin")
        try Data("x".utf8).write(to: oldResource)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: oldResource.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: oldResource.path) }
        if let readable = try? FileHandle(forReadingFrom: oldResource) {
            try? readable.close()
            throw XCTSkip("此环境可绕过文件权限，无法验证未读取不同大小的文件")
        }
        let files = ["YuanShen.exe": Data("original executable".utf8),
                     "old-resource.bin": Data("new larger resource".utf8)]
        let recorder = SophonScanProgressEvidence()
        let installer = SophonInstaller(session: try makeSophonInstallerSession(
            files: files, branchVersion: "1.0.0", preDownloadVersion: "9.9.0"
        ), preDownloadAvailableBytes: { _ in UInt64.max })
        _ = try await installer.preDownload(game: .genshinImpact, destination: destination, expectedVersion: "9.9.0") {
            recorder.record($0)
        }
        let scan = recorder.values.filter { $0.message.contains("正在检查已有游戏文件") }
        XCTAssertEqual(scan.first?.message, "正在检查已有游戏文件（0/3）")
        XCTAssertEqual(scan.last?.message, "正在检查已有游戏文件（3/3）")
        XCTAssertTrue(scan.allSatisfy { $0.fractionCompleted == nil && $0.bytesCompleted == 0 && $0.bytesTotal == nil },
                      "扫描进度不能伪装成下载百分比或字节数")
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: oldResource.path)
        XCTAssertEqual(try Data(contentsOf: oldResource), Data("x".utf8))
        let cached = try sophonCachedFile(in: destination, startingWith: files["old-resource.bin"]!)
        XCTAssertEqual(try Data(contentsOf: cached), files["old-resource.bin"])
    }

    func testSophonPreDownloadCancellationResumesVerifiedChunks() async throws {
        let destination = try makeTemporaryDirectory().resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: destination) }
        let originalConfig = try seedSophonMainlandInstallation(at: destination)
        let paused = ObservationFlag()
        let first = SophonInstaller(session: try makeSophonInstallerSession(
            files: sophonResumeFiles, branchVersion: "1.0.0", chunkSize: 8,
            pauseAfterChunk: 4, pauseSignal: paused, preDownloadVersion: "9.9.0"
        ))
        let operation = Task {
            try await first.preDownload(game: .genshinImpact, destination: destination, expectedVersion: "9.9.0") { _ in }
        }
        defer { operation.cancel() }
        let deadline = Date().addingTimeInterval(5)
        while !paused.isSet && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(paused.isSet)
        operation.cancel()
        do { _ = try await operation.value; XCTFail("Expected interrupted pre-download") }
        catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("YuanShen.exe"), encoding: .utf8), "original executable")
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("config.ini"), encoding: .utf8), originalConfig)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent(SophonInstaller.transactionDirectoryName).path))

        let requests = destination.deletingLastPathComponent().appendingPathComponent("pre-resume-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: requests) }
        try Data().write(to: requests)
        let retry = SophonInstaller(session: try makeSophonInstallerSession(
            files: sophonResumeFiles, requests: requests, branchVersion: "1.0.0", chunkSize: 8, preDownloadVersion: "9.9.0"
        ))
        _ = try await retry.preDownload(game: .genshinImpact, destination: destination, expectedVersion: "9.9.0") { _ in }
        let resumed = try String(contentsOf: requests, encoding: .utf8)
        for name in sophonVerifiedResumeChunks { XCTAssertFalse(resumed.contains("GET \(name)"), "Reused chunks must not be downloaded again") }
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("config.ini"), encoding: .utf8), originalConfig)
    }

    func testSophonPreDownloadReservesDiskAndDoesNotRecountCachedData() async throws {
        let destination = try makeTemporaryDirectory().resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: destination) }
        let originalConfig = try seedSophonMainlandInstallation(at: destination)
        let files = ["YuanShen.exe": Data("pre-download test executable".utf8)]
        let requests = destination.deletingLastPathComponent().appendingPathComponent("pre-space-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: requests) }
        try Data().write(to: requests)
        let reserve = SophonInstaller.preDownloadSpaceReserve
        let limited = SophonInstaller(
            session: try makeSophonInstallerSession(files: files, requests: requests, branchVersion: "1.0.0", preDownloadVersion: "9.9.0"),
            preDownloadAvailableBytes: { _ in reserve }
        )
        do { _ = try await limited.preDownload(game: .genshinImpact, destination: destination, expectedVersion: "9.9.0") { _ in }; XCTFail("Insufficient space must fail before downloading") }
        catch { XCTAssertTrue(error.localizedDescription.contains("空间"), "\(error)") }
        XCTAssertFalse(try String(contentsOf: requests, encoding: .utf8).contains("GET chunk-"))
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("config.ini"), encoding: .utf8), originalConfig)

        let sufficient = SophonInstaller(
            session: try makeSophonInstallerSession(files: files, requests: requests, branchVersion: "1.0.0", preDownloadVersion: "9.9.0"),
            preDownloadAvailableBytes: { _ in reserve + 1_000_000 }
        )
        _ = try await sufficient.preDownload(game: .genshinImpact, destination: destination, expectedVersion: "9.9.0") { _ in }
        try Data().write(to: requests)
        let completeCache = SophonInstaller(
            session: try makeSophonInstallerSession(files: files, requests: requests, branchVersion: "1.0.0", preDownloadVersion: "9.9.0"),
            preDownloadAvailableBytes: { _ in 0 }
        )
        _ = try await completeCache.preDownload(game: .genshinImpact, destination: destination, expectedVersion: "9.9.0") { _ in }
        XCTAssertFalse(try String(contentsOf: requests, encoding: .utf8).contains("GET chunk-"), "已验证缓存不应被重复计入所需空间")
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("config.ini"), encoding: .utf8), originalConfig)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent(SophonInstaller.transactionDirectoryName).path))

        // A checkpoint can overestimate reusable bytes if its data was
        // corrupted. Rehashing detects that and the per-batch check still
        // prevents writing below the reserve.
        let cached = try sophonCachedFile(in: destination, startingWith: files["YuanShen.exe"]!)
        try Data(repeating: 0, count: files["YuanShen.exe"]!.count).write(to: cached)
        try Data().write(to: requests)
        let corrupt = SophonInstaller(
            session: try makeSophonInstallerSession(files: files, requests: requests, branchVersion: "1.0.0", preDownloadVersion: "9.9.0"),
            preDownloadAvailableBytes: { _ in reserve }
        )
        do { _ = try await corrupt.preDownload(game: .genshinImpact, destination: destination, expectedVersion: "9.9.0") { _ in }; XCTFail("Corrupt cache must not bypass disk reserve") }
        catch { XCTAssertTrue(error.localizedDescription.contains("空间"), "\(error)") }
        XCTAssertFalse(try String(contentsOf: requests, encoding: .utf8).contains("GET chunk-"))
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("config.ini"), encoding: .utf8), originalConfig)
    }

    func testSophonIncrementalUpdateBoundsTemporaryDataAndResumesCommittedFiles() async throws {
        let base = try makeTemporaryDirectory().resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let game = base.appendingPathComponent("game", isDirectory: true)
        try FileManager.default.createDirectory(at: game, withIntermediateDirectories: true)
        let config = try seedSophonMainlandInstallation(at: game)
        let files: [String: Data] = [
            "A.bin": Data(repeating: 0x21, count: 64 * 1024),
            "B.bin": Data(repeating: 0x32, count: 64 * 1024),
            "C.bin": Data(repeating: 0x43, count: 64 * 1024),
            "YuanShen.exe": Data(repeating: 0x54, count: 64 * 1024),
        ]
        let first = SophonInstaller(session: try makeSophonInstallerSession(files: files))
        let firstProbe = SophonIncrementalProgressProbe()
        let operation = Task {
            try await first.run(game: .genshinImpact, destination: game, mode: .update) { progress in
                if await firstProbe.observe(progress, root: game, targets: files, pauseAfterFirstFile: true) {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }
        }
        do { _ = try await operation.value; XCTFail("The update should pause between committed files") }
        catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        let firstSnapshot = await firstProbe.snapshot()
        XCTAssertFalse(firstSnapshot.installedPaths.isEmpty, "At least one verified target must already be installed")
        XCTAssertLessThan(firstSnapshot.installedPaths.count, files.count)
        XCTAssertEqual(try String(contentsOf: game.appendingPathComponent("config.ini"), encoding: .utf8), config,
                       "The public game version must remain unchanged until every batch is installed")
        let pendingAfterPause = await first.hasPendingTransaction(destination: game)
        let resumableAfterPause = try await first.hasResumableUpdate(destination: game, game: .genshinImpact)
        XCTAssertTrue(pendingAfterPause)
        XCTAssertTrue(resumableAfterPause)

        let requests = base.appendingPathComponent("resume-requests")
        try Data().write(to: requests)
        let retry = SophonInstaller(session: try makeSophonInstallerSession(files: files, requests: requests))
        let recovered = try await retry.recover(destination: game, game: .genshinImpact)
        XCTAssertNil(recovered, "An unfinished v2 transaction must not be reported as an installed game")
        for path in firstSnapshot.installedPaths { XCTAssertEqual(try Data(contentsOf: game.appendingPathComponent(path)), files[path]) }
        let resumeProbe = SophonIncrementalProgressProbe()
        let result = try await retry.run(game: .genshinImpact, destination: game, mode: .update) { progress in
            _ = await resumeProbe.observe(progress, root: game, targets: files, pauseAfterFirstFile: false)
        }
        XCTAssertEqual(result.version, "9.9.0")
        for (path, data) in files { XCTAssertEqual(try Data(contentsOf: game.appendingPathComponent(path)), data) }
        let requested = try String(contentsOf: requests, encoding: .utf8)
        for path in firstSnapshot.installedPaths {
            XCTAssertFalse(requested.contains("chunk-" + SophonMetadataClient.md5(try XCTUnwrap(files[path]))),
                           "A durably committed file must not be downloaded again: \(path)")
        }
        let resumeSnapshot = await resumeProbe.snapshot()
        XCTAssertLessThanOrEqual(max(firstSnapshot.peakTemporaryBytes, resumeSnapshot.peakTemporaryBytes), 2 * 64 * 1024 + 32 * 1024,
                                 "Independent files must not accumulate all full targets in staging/backup/cache")
        XCTAssertTrue(try String(contentsOf: game.appendingPathComponent("config.ini"), encoding: .utf8).contains("game_version=9.9.0"))
        let pendingAfterCommit = await retry.hasPendingTransaction(destination: game)
        XCTAssertTrue(pendingAfterCommit, "Keep completion durable until registration is acknowledged")
        let completed = try await SophonInstaller(session: try makeSophonInstallerSession(files: [:]))
            .recover(destination: game, game: .genshinImpact)
        XCTAssertEqual(completed?.version, "9.9.0", "A committed update must be recoverable without network access")
        try await retry.finalizeCommittedUpdate(destination: game, game: .genshinImpact)
        let pendingAfterFinalization = await retry.hasPendingTransaction(destination: game)
        XCTAssertFalse(pendingAfterFinalization)
    }

    func testSophonIncrementalResumeRejectsChangedTargetVersionAndModifiedCommittedFiles() async throws {
        for scenario in ["version-changed", "file-modified"] {
            let game = try makeTemporaryDirectory().resolvingSymlinksInPath()
            defer { try? FileManager.default.removeItem(at: game) }
            let config = try seedSophonMainlandInstallation(at: game)
            let files = ["A.bin": Data("new A".utf8), "B.bin": Data("new B".utf8), "YuanShen.exe": Data("new executable".utf8)]
            let first = SophonInstaller(session: try makeSophonInstallerSession(files: files))
            let probe = SophonIncrementalProgressProbe()
            let operation = Task {
                try await first.run(game: .genshinImpact, destination: game, mode: .update) { progress in
                    if await probe.observe(progress, root: game, targets: files, pauseAfterFirstFile: true) {
                        withUnsafeCurrentTask { $0?.cancel() }
                    }
                }
            }
            do { _ = try await operation.value; XCTFail("Expected a paused update") }
            catch { XCTAssertTrue(error is CancellationError, "\(error)") }
            let installed = await probe.snapshot().installedPaths
            let committedPath = try XCTUnwrap(installed.first)
            let changed = Data("external change: preserve".utf8)
            if scenario == "file-modified" { try changed.write(to: game.appendingPathComponent(committedPath)) }
            let retry = SophonInstaller(session: try makeSophonInstallerSession(
                files: files, buildVersion: scenario == "version-changed" ? "10.0.0" : "9.9.0",
                branchVersion: scenario == "version-changed" ? "10.0.0" : "9.9.0"
            ))
            do {
                _ = try await retry.run(game: .genshinImpact, destination: game, mode: .update) { _ in }
                XCTFail("A resumed update must not silently accept \(scenario)")
            } catch { }
            XCTAssertEqual(try Data(contentsOf: game.appendingPathComponent(committedPath)), scenario == "file-modified" ? changed : files[committedPath])
            XCTAssertEqual(try String(contentsOf: game.appendingPathComponent("config.ini"), encoding: .utf8), config)
            let pending = await retry.hasPendingTransaction(destination: game)
            XCTAssertTrue(pending, "An unresolved transaction must continue blocking game launch")
        }
    }

    func testSophonIncrementalDiskPressurePausesAfterCommittedFileAndCanContinue() async throws {
        let base = try makeTemporaryDirectory().resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let game = base.appendingPathComponent("game", isDirectory: true)
        try FileManager.default.createDirectory(at: game, withIntermediateDirectories: true)
        let originalConfig = try seedSophonMainlandInstallation(at: game)
        let files = ["A.bin": Data("new first resource".utf8), "B.bin": Data("new second resource".utf8),
                     "YuanShen.exe": Data("new executable".utf8)]
        let lowSpace = ObservationFlag()
        let first = SophonInstaller(session: try makeSophonInstallerSession(files: files),
                                    preDownloadAvailableBytes: { _ in lowSpace.isSet ? 0 : UInt64.max })
        do {
            _ = try await first.run(game: .genshinImpact, destination: game, mode: .update) { progress in
                if progress.message.hasPrefix("已安装 ") { lowSpace.mark() }
            }
            XCTFail("Every new batch must check disk space before its writes")
        } catch { XCTAssertTrue(error.localizedDescription.contains("空间"), "\(error)") }
        XCTAssertTrue(lowSpace.isSet, "The space failure must happen after a successful first commit")
        XCTAssertEqual(try Data(contentsOf: game.appendingPathComponent("A.bin")), files["A.bin"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: game.appendingPathComponent("B.bin").path))
        XCTAssertEqual(try String(contentsOf: game.appendingPathComponent("config.ini"), encoding: .utf8), originalConfig)
        let resumable = try await first.hasResumableUpdate(destination: game, game: .genshinImpact)
        XCTAssertTrue(resumable)
        let requests = base.appendingPathComponent("retry-requests")
        try Data().write(to: requests)
        let retry = SophonInstaller(session: try makeSophonInstallerSession(files: files, requests: requests),
                                    preDownloadAvailableBytes: { _ in UInt64.max })
        _ = try await retry.run(game: .genshinImpact, destination: game, mode: .update) { _ in }
        let requested = try String(contentsOf: requests, encoding: .utf8)
        XCTAssertFalse(requested.contains("chunk-" + SophonMetadataClient.md5(try XCTUnwrap(files["A.bin"]))))
        for (path, data) in files { XCTAssertEqual(try Data(contentsOf: game.appendingPathComponent(path)), data) }
        try await retry.finalizeCommittedUpdate(destination: game, game: .genshinImpact)
    }

    func testSophonIncrementalRecoveryHandlesRenameBoundariesWithoutRollingBackPriorFiles() async throws {
        for state in ["before-renames", "old-moved", "new-moved", "staged-damaged", "external-target"] {
            let root = try makeTemporaryDirectory().resolvingSymlinksInPath()
            defer { try? FileManager.default.removeItem(at: root) }
            let work = root.appendingPathComponent(SophonInstaller.transactionDirectoryName, isDirectory: true)
            let staged = work.appendingPathComponent("staged", isDirectory: true)
            let backup = work.appendingPathComponent("backup", isDirectory: true)
            try FileManager.default.createDirectory(at: staged, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
            let first = Data("earlier durably installed A".utf8)
            let old = Data("original B".utf8)
            let new = Data("verified new B".utf8)
            let external = Data("external B: preserve".utf8)
            let oldConfig = Data("[General]\ngame_version=1.0.0\nchannel=1\nsub_channel=1\ncps=mihoyo\n".utf8)
            let newConfig = Data("[General]\ngame_version=9.9.0\nchannel=1\nsub_channel=1\ncps=mihoyo\n".utf8)
            try first.write(to: root.appendingPathComponent("A.bin"))
            try oldConfig.write(to: root.appendingPathComponent("config.ini"))
            if state == "before-renames" { try old.write(to: root.appendingPathComponent("B.bin")) }
            else { try old.write(to: backup.appendingPathComponent("B.bin")) }
            if state == "new-moved" { try new.write(to: root.appendingPathComponent("B.bin")) }
            else { try (state == "staged-damaged" ? Data("bad staging".utf8) : new).write(to: staged.appendingPathComponent("B.bin")) }
            if state == "external-target" { try external.write(to: root.appendingPathComponent("B.bin")) }
            let operations = [
                SophonInstaller.IncrementalOperation(path: "A.bin", size: UInt64(first.count), md5: SophonMetadataClient.md5(first),
                    originalMD5: nil, category: "game", patch: nil, deletion: false),
                SophonInstaller.IncrementalOperation(path: "B.bin", size: UInt64(new.count), md5: SophonMetadataClient.md5(new),
                    originalMD5: SophonMetadataClient.md5(old), category: "game", patch: nil, deletion: false),
                SophonInstaller.IncrementalOperation(path: "config.ini", size: UInt64(newConfig.count), md5: SophonMetadataClient.md5(newConfig),
                    originalMD5: SophonMetadataClient.md5(oldConfig), category: nil, patch: nil, deletion: false),
            ]
            let journal = SophonInstaller.IncrementalJournal(version: 2, game: .genshinImpact, destination: root.path,
                sourceVersion: "1.0.0", targetVersion: "9.9.0", identity: "fixture-identity", audioLanguages: ["zh-cn"],
                config: newConfig, operations: operations, completedCount: 1, activeIndex: 1, committed: false)
            let journalURL = work.appendingPathComponent("journal.json")
            try JSONEncoder().encode(journal).write(to: journalURL)
            let installer = SophonInstaller()
            if state == "external-target" {
                do { _ = try await installer.recover(destination: root, game: .genshinImpact); XCTFail("Unknown target bytes must never be overwritten") }
                catch { }
                XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("B.bin")), external)
                XCTAssertEqual(try Data(contentsOf: backup.appendingPathComponent("B.bin")), old)
            } else {
                let result = try await installer.recover(destination: root, game: .genshinImpact)
                XCTAssertNil(result, "The final version configuration is still pending")
                XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("B.bin")), state == "staged-damaged" ? old : new)
                let after = try JSONDecoder().decode(SophonInstaller.IncrementalJournal.self, from: Data(contentsOf: journalURL))
                XCTAssertEqual(after.completedCount, state == "staged-damaged" ? 1 : 2)
                XCTAssertNil(after.activeIndex)
            }
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("A.bin")), first,
                           "An earlier completed batch must survive recovery of the active file")
            XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("config.ini")), oldConfig)
            let pending = await installer.hasPendingTransaction(destination: root)
            XCTAssertTrue(pending)
        }
    }

    func testSophonIncrementalCompletionRejectsChangedInitiallyCurrentFile() async throws {
        for removed in [false, true] {
            let root = try makeTemporaryDirectory().resolvingSymlinksInPath()
            defer { try? FileManager.default.removeItem(at: root) }
            let originalConfig = try seedSophonMainlandInstallation(at: root)
            let current = Data("already current resource".utf8)
            let currentURL = root.appendingPathComponent("unchanged.bin")
            try current.write(to: currentURL)
            let files = ["A.bin": Data("first updated resource".utf8), "B.bin": Data("second updated resource".utf8),
                         "YuanShen.exe": Data("new executable".utf8), "unchanged.bin": current]
            let first = SophonInstaller(session: try makeSophonInstallerSession(files: files))
            let operation = Task {
                try await first.run(game: .genshinImpact, destination: root, mode: .update) { progress in
                    if progress.message.hasPrefix("已安装 ") { withUnsafeCurrentTask { $0?.cancel() } }
                }
            }
            do { _ = try await operation.value; XCTFail("Expected a paused update") }
            catch { XCTAssertTrue(error is CancellationError, "\(error)") }
            let external = Data("external change in previously current file".utf8)
            if removed { try FileManager.default.removeItem(at: currentURL) }
            else { try external.write(to: currentURL) }
            let retry = SophonInstaller(session: try makeSophonInstallerSession(files: files))
            do {
                _ = try await retry.run(game: .genshinImpact, destination: root, mode: .update) { _ in }
                XCTFail("A file omitted from the initial change plan must still match before completion")
            } catch { }
            if removed { XCTAssertFalse(FileManager.default.fileExists(atPath: currentURL.path)) }
            else { XCTAssertEqual(try Data(contentsOf: currentURL), external) }
            XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("config.ini"), encoding: .utf8), originalConfig)
            let pending = await retry.hasPendingTransaction(destination: root)
            XCTAssertTrue(pending)
        }
    }

    func testSophonIncrementalFinalVersionCommitSurvivesLateCancellation() async throws {
        let root = try makeTemporaryDirectory().resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        _ = try seedSophonMainlandInstallation(at: root)
        let updated = Data("verified executable".utf8)
        let installer = SophonInstaller(session: try makeSophonInstallerSession(files: ["YuanShen.exe": updated]))
        let operation = Task {
            try await installer.run(game: .genshinImpact, destination: root, mode: .update) { progress in
                if progress.message == ScheduledTask.sophonCommitPhaseDescription,
                   (try? String(contentsOf: root.appendingPathComponent("config.ini"), encoding: .utf8))?.contains("game_version=9.9.0") == true {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }
        }
        let result = try await operation.value
        XCTAssertEqual(result.version, "9.9.0")
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("YuanShen.exe")), updated)
        let recovered = try await installer.recover(destination: root, game: .genshinImpact)
        XCTAssertEqual(recovered?.version, "9.9.0", "Cancellation after publishing the final config cannot turn success into a paused update")
        try await installer.finalizeCommittedUpdate(destination: root, game: .genshinImpact)
        let pending = await installer.hasPendingTransaction(destination: root)
        XCTAssertFalse(pending)
    }

    func testSophonInstallerFreshInstallCommitsVerifiedFilesConfigAndIdentity() async throws {
        let destination = try makeTemporaryDirectory().resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: destination) }
        let executable = Data("verified executable fixture".utf8)
        let resource = Data("verified game resource".utf8)
        let installer = SophonInstaller(session: try makeSophonInstallerSession(files: [
            "YuanShen.exe": executable, "YuanShen_Data/data.bin": resource,
        ]))

        let result = try await installer.run(game: .genshinImpact, destination: destination, mode: .install) { _ in }

        XCTAssertEqual(result.version, "9.9.0")
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("YuanShen.exe")), executable)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("YuanShen_Data/data.bin")), resource)
        let config = try String(contentsOf: destination.appendingPathComponent("config.ini"), encoding: .utf8)
        for line in ["[General]", "game_version=9.9.0", "channel=1", "sub_channel=1", "cps=mihoyo"] {
            XCTAssertTrue(config.components(separatedBy: .newlines).contains(line), line)
        }
        let identity = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf:
            destination.appendingPathComponent(".miplay-sophon-install.json")
        )) as? [String: Any])
        XCTAssertEqual(identity["game"] as? String, GameType.genshinImpact.rawValue)
        XCTAssertEqual(identity["region"] as? String, "cn")
        let pending = await installer.hasPendingTransaction(destination: destination)
        XCTAssertFalse(pending)
    }

    func testSophonCommitProgressAndLateCancellationKeepCommittedFreshInstall() async throws {
        let destination = try makeTemporaryDirectory().resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: destination) }
        let executable = Data("updated executable".utf8)
        let installer = SophonInstaller(session: try makeSophonInstallerSession(files: ["YuanShen.exe": executable]))
        let recorder = SophonScanProgressEvidence()
        let operation = Task {
            try await installer.run(game: .genshinImpact, destination: destination, mode: .install) { progress in
                recorder.record(progress)
                // Simulate a cancellation racing in after the first file was
                // committed; the remaining transaction must still finish.
                if progress.message == ScheduledTask.sophonCommitPhaseDescription,
                   let value = progress.fractionCompleted, value > 0 {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }
        }
        let result = try await operation.value
        XCTAssertEqual(result.version, "9.9.0")
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("YuanShen.exe")), executable)
        XCTAssertTrue(try String(contentsOf: destination.appendingPathComponent("config.ini"), encoding: .utf8)
            .contains("game_version=9.9.0"))
        let pending = await installer.hasPendingTransaction(destination: destination)
        XCTAssertFalse(pending)
        let commit = recorder.values.filter { $0.message == ScheduledTask.sophonCommitPhaseDescription }
        XCTAssertEqual(commit.first?.fractionCompleted, 0)
        XCTAssertTrue(commit.contains { ($0.fractionCompleted ?? 0) > 0 })
        XCTAssertTrue(commit.allSatisfy { ($0.fractionCompleted ?? 1) < 1 })
        XCTAssertEqual(recorder.values.last?.message, ScheduledTask.sophonCommitPhaseDescription)

        var task = ScheduledTask(type: .gameInstall, gameId: GameType.genshinImpact.rawValue)
        XCTAssertEqual(task.cancellationPolicy, .cleanupAfterSideEffect)
        task.phaseDescription = ScheduledTask.sophonCommitPhaseDescription
        XCTAssertEqual(task.cancellationPolicy, .notCancellable)
    }

    func testSophonFreshInstallCancellationBeforeCommitLeavesDirectoryUninstalled() async throws {
        let destination = try makeTemporaryDirectory().resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: destination) }
        let installer = SophonInstaller(session: try makeSophonInstallerSession(
            files: ["YuanShen.exe": Data("updated executable".utf8)]
        ))
        let operation = Task {
            try await installer.run(game: .genshinImpact, destination: destination, mode: .install) { progress in
                if progress.message == ScheduledTask.sophonCommitPhaseDescription,
                   progress.fractionCompleted == 0 {
                    withUnsafeCurrentTask { $0?.cancel() }
                }
            }
        }
        do { _ = try await operation.value; XCTFail("Cancellation before commit should stop the update") }
        catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("YuanShen.exe").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("config.ini").path))
        let pending = await installer.hasPendingTransaction(destination: destination)
        XCTAssertFalse(pending)
    }

    func testSophonInstallerUpdateReusesVerifiedFilesAndPreservesUserFiles() async throws {
        let base = try makeTemporaryDirectory().resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let destination = base.appendingPathComponent("game", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let originalConfig = try seedSophonMainlandInstallation(at: destination)
        let unchanged = Data("already correct game resource".utf8)
        let unchangedURL = destination.appendingPathComponent("unchanged.bin")
        try unchanged.write(to: unchangedURL)
        let originalDate = Date(timeIntervalSince1970: 123_456)
        try FileManager.default.setAttributes([.modificationDate: originalDate], ofItemAtPath: unchangedURL.path)
        let userFile = destination.appendingPathComponent("user-save.dat")
        let userData = Data("user data".utf8)
        try userData.write(to: userFile)
        let obsolete = destination.appendingPathComponent("obsolete.bin")
        let obsoleteData = Data("known old resource".utf8)
        try obsoleteData.write(to: obsolete)
        let updatedExecutable = Data("updated executable".utf8)
        let requests = base.appendingPathComponent("requests.txt")
        try Data().write(to: requests)
        let installer = SophonInstaller(session: try makeSophonInstallerSession(
            files: ["YuanShen.exe": updatedExecutable, "unchanged.bin": unchanged], requests: requests,
            deletions: ["obsolete.bin": obsoleteData], otherVersionDeletions: ["user-save.dat": userData]
        ))

        _ = try await installer.run(game: .genshinImpact, destination: destination, mode: .update) { _ in }
        try await installer.finalizeCommittedUpdate(destination: destination, game: .genshinImpact)

        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("YuanShen.exe")), updatedExecutable)
        XCTAssertEqual(try Data(contentsOf: unchangedURL), unchanged)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: unchangedURL.path)[.modificationDate] as? Date, originalDate)
        XCTAssertEqual(try String(contentsOf: userFile, encoding: .utf8), "user data")
        XCTAssertFalse(FileManager.default.fileExists(atPath: obsolete.path), "Only the deletion list for installed version 1.0.0 should apply")
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("config.ini"), encoding: .utf8),
                       originalConfig.replacingOccurrences(of: "game_version=1.0.0", with: "game_version=9.9.0"))
        let requested = try String(contentsOf: requests, encoding: .utf8)
        XCTAssertFalse(requested.contains("chunk-" + SophonMetadataClient.md5(unchanged)), "Verified unchanged files should not be downloaded again")
        XCTAssertTrue(requested.contains("chunk-" + SophonMetadataClient.md5(updatedExecutable)))
        XCTAssertTrue(requested.contains("POST getPatchBuild"))
    }

    func testSophonInstallerCorruptChunkLeavesOriginalInstallationUnchanged() async throws {
        let destination = try makeTemporaryDirectory().resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: destination) }
        let originalConfig = try seedSophonMainlandInstallation(at: destination)
        let requests = destination.appendingPathComponent("fixture-requests.txt")
        try Data().write(to: requests)
        let installer = SophonInstaller(session: try makeSophonInstallerSession(
            files: ["YuanShen.exe": Data("replacement executable".utf8)], corruptPath: "YuanShen.exe", requests: requests
        ))

        do {
            _ = try await installer.run(game: .genshinImpact, destination: destination, mode: .update) { _ in }
            XCTFail("A corrupt download must fail")
        } catch {}

        XCTAssertTrue(try String(contentsOf: requests, encoding: .utf8).contains("chunk-" + SophonMetadataClient.md5(Data("replacement executable".utf8))), "The failure must occur after fetching the corrupt chunk")
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("YuanShen.exe"), encoding: .utf8), "original executable")
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("config.ini"), encoding: .utf8), originalConfig)
        let pending = await installer.hasPendingTransaction(destination: destination)
        XCTAssertTrue(pending, "A failed incremental update must retain its forward-resume journal")
    }

    func testSophonInstallerFailurePreservesUserBlockerAndKeepsUpdateResumable() async throws {
        let destination = try makeTemporaryDirectory().resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: destination) }
        let originalConfig = try seedSophonMainlandInstallation(at: destination)
        // A user file blocks a resource directory. The update must preserve the
        // blocker and leave its transaction available for an explicit retry.
        let blocker = destination.appendingPathComponent("blocked")
        try Data("existing user file".utf8).write(to: blocker)
        let installer = SophonInstaller(session: try makeSophonInstallerSession(files: [
            "YuanShen.exe": Data("replacement executable".utf8),
            "blocked/resource.bin": Data("new resource".utf8),
        ]))
        let staged = ObservationFlag()
        var failurePath: String?

        do {
            _ = try await installer.run(game: .genshinImpact, destination: destination, mode: .update) { progress in
                if progress.bytesCompleted > 0 { staged.mark() }
            }
            XCTFail("Committing through a regular file must fail")
        } catch { failurePath = (error as NSError).userInfo[NSFilePathErrorKey] as? String }

        XCTAssertTrue(staged.isSet, "The fixture must stage verified replacements before the injected commit failure")
        XCTAssertTrue(failurePath?.contains("/blocked") == true, "The expected failure is creating the blocked commit directory")
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("YuanShen.exe"), encoding: .utf8), "original executable")
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("config.ini"), encoding: .utf8), originalConfig)
        XCTAssertEqual(try String(contentsOf: blocker, encoding: .utf8), "existing user file")
        let pending = await installer.hasPendingTransaction(destination: destination)
        XCTAssertTrue(pending, "A failed batch must retain completed files and the journal for forward recovery")
    }

    func testSophonInstallerCancellationLeavesOriginalInstallationUnchanged() async throws {
        let destination = try makeTemporaryDirectory().resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: destination) }
        let originalConfig = try seedSophonMainlandInstallation(at: destination)
        let downloading = ObservationFlag()
        let installer = SophonInstaller(session: try makeSophonInstallerSession(files: [
            "YuanShen.exe": Data("replacement executable".utf8),
        ], chunkSize: 4, reverseChunkResponses: true, chunkStarted: downloading))
        let operation = Task {
            try await installer.run(game: .genshinImpact, destination: destination, mode: .update) { _ in }
        }
        defer { operation.cancel() }
        let deadline = Date().addingTimeInterval(5)
        while !downloading.isSet && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(downloading.isSet, "The fixture should reach in-flight chunk downloads")
        operation.cancel()
        do {
            _ = try await operation.value
            XCTFail("Cancelled staging must not commit")
        } catch { XCTAssertTrue(error is CancellationError, "\(error)") }

        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("YuanShen.exe"), encoding: .utf8), "original executable")
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("config.ini"), encoding: .utf8), originalConfig)
        let pending = await installer.hasPendingTransaction(destination: destination)
        XCTAssertTrue(pending, "Cancelled updates keep the forward-resume transaction")
    }

    func testSophonTransactionIdentityIsValidatedWithoutMutation() async throws {
        let destination = try makeTemporaryDirectory().resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: destination) }
        let installer = SophonInstaller()
        let work = destination.appendingPathComponent(SophonInstaller.transactionDirectoryName)
        let journalURL = work.appendingPathComponent("journal.json")
        let missing = try await installer.hasRecoverableTransaction(destination: destination, game: .zenlessZoneZero)
        XCTAssertFalse(missing)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        do {
            _ = try await installer.hasRecoverableTransaction(destination: destination, game: .zenlessZoneZero)
            XCTFail("Missing journal must not authorize a recovery")
        } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: work.path))
        let journal: [String: Any] = [
            "version": 1, "game": GameType.zenlessZoneZero.rawValue,
            "destination": destination.path, "committed": false,
            "operations": [], "createdDirectories": []
        ]
        let bytes = try JSONSerialization.data(withJSONObject: journal)
        try bytes.write(to: journalURL)
        let found = try await installer.hasRecoverableTransaction(destination: destination, game: .zenlessZoneZero)
        XCTAssertTrue(found)
        XCTAssertEqual(try Data(contentsOf: journalURL), bytes)
        do {
            _ = try await installer.hasRecoverableTransaction(destination: destination, game: .genshinImpact)
            XCTFail("A journal for another game must not be accepted")
        } catch {}
        let other = try makeTemporaryDirectory().resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: other) }
        let otherWork = other.appendingPathComponent(SophonInstaller.transactionDirectoryName)
        try FileManager.default.createDirectory(at: otherWork, withIntermediateDirectories: true)
        try bytes.write(to: otherWork.appendingPathComponent("journal.json"))
        do {
            _ = try await installer.hasRecoverableTransaction(destination: other, game: .zenlessZoneZero)
            XCTFail("A journal copied from another destination must not be accepted")
        } catch {}
        try FileManager.default.removeItem(at: journalURL)
        try FileManager.default.createSymbolicLink(at: journalURL, withDestinationURL: otherWork.appendingPathComponent("journal.json"))
        do {
            _ = try await installer.hasRecoverableTransaction(destination: destination, game: .zenlessZoneZero)
            XCTFail("A symlinked journal must not authorize a recovery")
        } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: otherWork.appendingPathComponent("journal.json").path))
        try FileManager.default.removeItem(at: work)
        try FileManager.default.createSymbolicLink(at: work, withDestinationURL: otherWork)
        do {
            _ = try await installer.hasRecoverableTransaction(destination: destination, game: .zenlessZoneZero)
            XCTFail("A symlinked transaction directory must not authorize a recovery")
        } catch {}
        XCTAssertTrue(FileManager.default.fileExists(atPath: otherWork.appendingPathComponent("journal.json").path))
    }

    func testSophonInstallerRecoveryRollsBackIncompleteAndKeepsCommittedFiles() async throws {
        for committed in [false, true] {
            let destination = try makeTemporaryDirectory().resolvingSymlinksInPath()
            defer { try? FileManager.default.removeItem(at: destination) }
            let work = destination.appendingPathComponent(".miplay-sophon-transaction", isDirectory: true)
            let backup = work.appendingPathComponent("backup", isDirectory: true)
            try FileManager.default.createDirectory(at: backup, withIntermediateDirectories: true)
            let original = Data("original executable".utf8)
            let replacement = Data("verified replacement".utf8)
            try original.write(to: backup.appendingPathComponent("YuanShen.exe"))
            let obsolete = Data("removed old resource".utf8)
            try obsolete.write(to: backup.appendingPathComponent("obsolete.bin"))
            try replacement.write(to: destination.appendingPathComponent("YuanShen.exe"))
            let journal: [String: Any] = [
                "version": 1, "game": GameType.genshinImpact.rawValue,
                "destination": destination.standardizedFileURL.path, "committed": committed,
                "operations": [["path": "YuanShen.exe", "hadExisting": true,
                                "installedMD5": SophonMetadataClient.md5(replacement)],
                               ["path": "obsolete.bin", "hadExisting": true, "installedMD5": "",
                                "deletion": true, "originalMD5": SophonMetadataClient.md5(obsolete)]],
                "createdDirectories": [],
            ]
            try JSONSerialization.data(withJSONObject: journal).write(to: work.appendingPathComponent("journal.json"))
            let installer = SophonInstaller(session: try makeSophonInstallerSession(files: [:]))
            let pending = await installer.hasPendingTransaction(destination: destination)
            XCTAssertTrue(pending)

            try await installer.recover(destination: destination, game: .genshinImpact)

            XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("YuanShen.exe")), committed ? replacement : original)
            let obsoleteURL = destination.appendingPathComponent("obsolete.bin")
            if committed { XCTAssertFalse(FileManager.default.fileExists(atPath: obsoleteURL.path)) }
            else { XCTAssertEqual(try Data(contentsOf: obsoleteURL), obsolete) }
            let remaining = await installer.hasPendingTransaction(destination: destination)
            XCTAssertFalse(remaining)
        }
    }

    func testSophonInstallerRejectsOverseasIdentityAndManifestTraversal() async throws {
        let base = try makeTemporaryDirectory().resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let overseas = base.appendingPathComponent("overseas", isDirectory: true)
        try FileManager.default.createDirectory(at: overseas, withIntermediateDirectories: true)
        let originalConfig = try seedSophonMainlandInstallation(at: overseas)
        let globalConfig = originalConfig.replacingOccurrences(of: "sub_channel=1", with: "sub_channel=0")
        try globalConfig.write(to: overseas.appendingPathComponent("config.ini"), atomically: true, encoding: .utf8)
        let installer = SophonInstaller(session: try makeSophonInstallerSession(files: ["YuanShen.exe": Data("new".utf8)]))
        do {
            _ = try await installer.run(game: .genshinImpact, destination: overseas, mode: .update) { _ in }
            XCTFail("An overseas installation must not be updated with mainland files")
        } catch {}
        XCTAssertEqual(try String(contentsOf: overseas.appendingPathComponent("config.ini"), encoding: .utf8), globalConfig)

        let destination = base.appendingPathComponent("new-install", isDirectory: true)
        let outside = base.appendingPathComponent("outside.bin")
        try Data("unrelated file".utf8).write(to: outside)
        let unsafe = SophonInstaller(session: try makeSophonInstallerSession(files: [
            "YuanShen.exe": Data("new".utf8), "../outside.bin": Data("unsafe replacement".utf8),
        ]))
        do {
            _ = try await unsafe.run(game: .genshinImpact, destination: destination, mode: .install) { _ in }
            XCTFail("A traversal path must be rejected before any installation files are committed")
        } catch {}
        XCTAssertEqual(try String(contentsOf: outside, encoding: .utf8), "unrelated file")
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("YuanShen.exe").path))
    }

    func testSophonInstallerRejectsModifiedDeletionTargetBeforeUpdating() async throws {
        let destination = try makeTemporaryDirectory().resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: destination) }
        let originalConfig = try seedSophonMainlandInstallation(at: destination)
        let obsolete = destination.appendingPathComponent("obsolete.bin")
        try Data("user modified old resource".utf8).write(to: obsolete)
        let requests = destination.appendingPathComponent("fixture-requests.txt")
        try Data().write(to: requests)
        let installer = SophonInstaller(session: try makeSophonInstallerSession(
            files: ["YuanShen.exe": Data("replacement executable".utf8)], requests: requests,
            deletions: ["obsolete.bin": Data("official original resource".utf8)]
        ))

        do {
            _ = try await installer.run(game: .genshinImpact, destination: destination, mode: .update) { _ in }
            XCTFail("A deletion target whose hash differs from the official old resource must be preserved")
        } catch {}

        XCTAssertTrue(try String(contentsOf: requests, encoding: .utf8).contains("POST getPatchBuild"))
        XCTAssertEqual(try String(contentsOf: obsolete, encoding: .utf8), "user modified old resource")
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("YuanShen.exe"), encoding: .utf8), "original executable")
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("config.ini"), encoding: .utf8), originalConfig)
        let pending = await installer.hasPendingTransaction(destination: destination)
        XCTAssertFalse(pending)
    }

    func testSophonMetadataRejectsWrongGameIdentityAndMismatchedBuildTag() async throws {
        for (gameID, buildTag) in [("wrong-game", "9.9.0"), ("1Z8W5NHUQb", "9.8.0")] {
            let client = SophonMetadataClient(session: try makeSophonInstallerSession(
                files: ["YuanShen.exe": Data("fixture".utf8)], branchGameID: gameID, buildVersion: buildTag
            ))
            do {
                _ = try await client.fetchBuild(for: .genshinImpact)
                XCTFail("A mismatched game identity or stale build must be rejected")
            } catch {}
        }
    }

    func testSophonInstallerOlderVersionUsesExactHistoricalManifestForCleanup() async throws {
        let destination = try makeTemporaryDirectory().resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: destination) }
        let config = try seedSophonMainlandInstallation(at: destination)
        try config.replacingOccurrences(of: "game_version=1.0.0", with: "game_version=0.9.0")
            .write(to: destination.appendingPathComponent("config.ini"), atomically: true, encoding: .utf8)
        let oldResource = Data("old official resource".utf8)
        let obsolete = destination.appendingPathComponent("obsolete.bin")
        try oldResource.write(to: obsolete)
        let userFile = destination.appendingPathComponent("user-save.dat")
        try Data("user data".utf8).write(to: userFile)
        let requests = destination.appendingPathComponent("fixture-requests.txt")
        try Data().write(to: requests)
        let replacement = Data("replacement executable".utf8)
        let installer = SophonInstaller(session: try makeSophonInstallerSession(
            files: ["YuanShen.exe": replacement], requests: requests,
            historicalFiles: ["YuanShen.exe": Data("original executable".utf8), "obsolete.bin": oldResource]
        ))

        _ = try await installer.run(game: .genshinImpact, destination: destination, mode: .update) { _ in }

        let requested = try String(contentsOf: requests, encoding: .utf8)
        XCTAssertTrue(requested.contains("GET getBuild tag=0.9.0"))
        XCTAssertFalse(requested.contains("getPatchBuild"), "Version 0.9.0 lies outside the direct diff_tags fixture")
        XCTAssertFalse(FileManager.default.fileExists(atPath: obsolete.path))
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("YuanShen.exe")), replacement)
        XCTAssertEqual(try String(contentsOf: userFile, encoding: .utf8), "user data")
        try await installer.finalizeCommittedUpdate(destination: destination, game: .genshinImpact)
    }

    func testSophonInstallerRejectsHistoricalResponseForDifferentVersion() async throws {
        let destination = try makeTemporaryDirectory().resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: destination) }
        let config = try seedSophonMainlandInstallation(at: destination)
            .replacingOccurrences(of: "game_version=1.0.0", with: "game_version=0.9.0")
        try config.write(to: destination.appendingPathComponent("config.ini"), atomically: true, encoding: .utf8)
        let requests = destination.appendingPathComponent("fixture-requests.txt")
        try Data().write(to: requests)
        let installer = SophonInstaller(session: try makeSophonInstallerSession(
            files: ["YuanShen.exe": Data("replacement executable".utf8)], requests: requests,
            historicalFiles: ["YuanShen.exe": Data("original executable".utf8)], historicalResponseVersion: "9.9.0"
        ))

        do {
            _ = try await installer.run(game: .genshinImpact, destination: destination, mode: .update) { _ in }
            XCTFail("A server ignoring the historical tag must not authorize old-file cleanup")
        } catch {}

        XCTAssertTrue(try String(contentsOf: requests, encoding: .utf8).contains("GET getBuild tag=0.9.0"))
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("YuanShen.exe"), encoding: .utf8), "original executable")
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("config.ini"), encoding: .utf8), config)
        let pending = await installer.hasPendingTransaction(destination: destination)
        XCTAssertFalse(pending)
    }

    func testSophonInstallerAssemblesOutOfOrderChunks() async throws {
        let base = try makeTemporaryDirectory().resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let destination = base.appendingPathComponent("game", isDirectory: true)
        let requests = base.appendingPathComponent("requests.txt")
        try Data().write(to: requests)
        let content = Data("abcdefghABCDEFGH12345678!@#$%^&*".utf8)
        let installer = SophonInstaller(session: try makeSophonInstallerSession(
            files: ["YuanShen.exe": content], requests: requests, chunkSize: 8, reverseChunkResponses: true
        ))

        _ = try await installer.run(game: .genshinImpact, destination: destination, mode: .install) { _ in }

        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("YuanShen.exe")), content)
        let lines = try String(contentsOf: requests, encoding: .utf8).components(separatedBy: .newlines)
        let firstName = "chunk-" + SophonMetadataClient.md5(Data(content.prefix(8)))
        let secondName = "chunk-" + SophonMetadataClient.md5(Data(content.dropFirst(8).prefix(8)))
        let firstLine = try XCTUnwrap(lines.first { $0.contains(firstName) })
        let secondLine = try XCTUnwrap(lines.first { $0.contains(secondName) })
        let firstTime = try XCTUnwrap(Double(try XCTUnwrap(firstLine.components(separatedBy: " t=").last)))
        let secondTime = try XCTUnwrap(Double(try XCTUnwrap(secondLine.components(separatedBy: " t=").last)))
        XCTAssertLessThan(abs(secondTime - firstTime), 0.5, "Multiple chunks should start before the first deliberately delayed response completes")
    }

    func testSophonInstallLockSpansCommitRegistrationAndFinalization() async throws {
        let directory = try makeTemporaryDirectory().resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: directory) }
        let installer = SophonInstaller(session: try makeSophonInstallerSession(files: [
            "YuanShen.exe": Data("new executable".utf8)
        ]))
        let held = try await installer.acquireExclusiveAccess(destination: directory)
        defer { held.release() }
        let result = try await installer.run(game: .genshinImpact, destination: directory, mode: .install, holding: held) { _ in }
        let other = SophonInstaller()
        do {
            let unexpected = try await other.acquireExclusiveAccess(destination: directory)
            unexpected.release()
            XCTFail("The lock must survive file commit until registration")
        } catch { XCTAssertTrue(error.localizedDescription.contains("另一个 MiPlay")) }

        let bookmark = try directory.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        var stale = false
        let selected = try URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], relativeTo: nil, bookmarkDataIsStale: &stale)
        guard selected.startAccessingSecurityScopedResource() else {
            throw XCTSkip("测试宿主无法为临时目录取得原生 security scope")
        }
        selected.stopAccessingSecurityScopedResource()
        let fixture = try await makeScheduler()
        let registered = try await fixture.registry.locateGame(type: .genshinImpact, selectedURL: selected, installedVersion: result.version)
        XCTAssertEqual(registered.state, .installed)
        XCTAssertEqual(registered.version, result.version)
        do {
            let unexpected = try await other.acquireExclusiveAccess(destination: directory)
            unexpected.release()
            XCTFail("The lock must remain held after registration")
        } catch { XCTAssertTrue(error.localizedDescription.contains("另一个 MiPlay")) }
        try await installer.finalizeCommittedInstall(destination: directory, game: .genshinImpact, holding: held)
        held.release()
        let after = try await other.acquireExclusiveAccess(destination: directory)
        after.release()
    }

    func testSophonPendingTransactionBlocksOtherwiseReadyLaunch() async throws {
        let base = try makeTemporaryDirectory().resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let directory = base.appendingPathComponent("game", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = try seedSophonMainlandInstallation(at: directory)
        let support = base.appendingPathComponent("support", isDirectory: true)
        let fileSystem = GameFileSystemRepository(appSupportDirectory: support, bookmarkResolver: BookmarkResolver(
            resolve: { _ in .init(url: directory, isStale: false) }, refresh: { _, _ in Data([1]) },
            startAccessing: { _ in true }, stopAccessing: { _ in }
        ))
        let game = Game(id: GameType.genshinImpact.rawValue, type: .genshinImpact,
                        location: GameLocation(gameID: GameType.genshinImpact.rawValue, bookmarkData: Data([1]),
                                               lastKnownPath: directory.path, resolutionState: .resolvable),
                        state: .installed, version: "1.0.0", lastLaunchDate: nil, solutionApplications: [])
        let store = PersistenceStore(baseURL: base.appendingPathComponent("store", isDirectory: true))
        let pair = try makeFixedWineRuntimePair(appSupport: support)
        try await store.writeAppData(AppData(games: [game], managedWineRuntime: pair.runtime, sharedWinePrefix: pair.prefix))
        let process = ProcessManager()
        let logger = LogWriter(fileSystemRepository: fileSystem)
        let network = try makeMockNetwork(response: Data(), statusCode: 404)
        let wine = WineRuntimeProvider(processManager: process, fileSystemRepository: fileSystem)
        let manager = WineVersionManager(networkProvider: network, fileSystemRepository: fileSystem, persistenceStore: store,
                                         wineVersionDownloader: WineVersionDownloader(networkProvider: network, fileSystemRepository: fileSystem,
                                                                                      processManager: process, logWriter: logger),
                                         logWriter: logger, wineRuntimeProvider: wine)
        await manager.initialize()
        let validator = PreLaunchValidator(fileSystemRepository: fileSystem,
                                           systemDetector: SystemEnvironmentDetector { _ in (free: UInt64.max, total: UInt64.max) },
                                           wineRuntimeProvider: wine, wineVersionManager: manager)
        let ready = await validator.validate(game: game)
        XCTAssertTrue(ready.isPassed, "The executable and fake runtime should otherwise be launchable: \(ready.errors)")
        let transaction = directory.appendingPathComponent(SophonInstaller.transactionDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: transaction, withIntermediateDirectories: true)

        let blocked = await validator.validate(game: game)

        XCTAssertFalse(blocked.isPassed)
        XCTAssertTrue(blocked.errors.contains {
            if case .invalidFileState(_, let detail) = $0 { return detail.contains("事务") }
            return false
        }, "An existing executable must not bypass the transaction recovery guard")
        try FileManager.default.removeItem(at: transaction)
        let restored = await validator.validate(game: game)
        XCTAssertTrue(restored.isPassed)
    }

    func testSophonResumeSkipsVerifiedChunksAndFilesAfterCancellation() async throws {
        let base = try makeTemporaryDirectory().resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let destination = base.appendingPathComponent("game", isDirectory: true)
        try await createPartialSophonDownload(at: destination)
        let requests = base.appendingPathComponent("retry-requests.txt")
        try Data().write(to: requests)
        let evidence = SophonResumeProgressEvidence()
        let retry = SophonInstaller(session: try makeSophonInstallerSession(
            files: sophonResumeFiles, requests: requests, chunkSize: 8
        ))

        _ = try await retry.run(game: .genshinImpact, destination: destination, mode: .install) { evidence.record($0) }

        let requested = try String(contentsOf: requests, encoding: .utf8)
        for name in sophonVerifiedResumeChunks { XCTAssertFalse(requested.contains(name), "Verified cached chunk was downloaded twice: \(name)") }
        XCTAssertTrue(requested.contains(sophonChunkNames(sophonResumeExecutable)[4]), "The interrupted portion must still be fetched")
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("YuanShen.exe")), sophonResumeExecutable)
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("A-complete.bin")), sophonResumeCompleteFile)
        XCTAssertGreaterThan(try XCTUnwrap(evidence.downloadBytes.first), 0, "Retry progress must begin with verified cached work")
        let receipt = destination.appendingPathComponent(SophonInstaller.resumeDirectoryName)
            .appendingPathComponent("committed-install.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: receipt.path), "A committed install must remain recoverable until registration is acknowledged")
        try await retry.finalizeCommittedInstall(destination: destination, game: .genshinImpact)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent(SophonInstaller.resumeDirectoryName).path))
    }

    func testSophonCommittedReceiptResumesOfflineBeforeRegistration() async throws {
        let base = try makeTemporaryDirectory().resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let destination = base.appendingPathComponent("game", isDirectory: true)
        let executable = Data("verified executable awaiting registration".utf8)
        let original = SophonInstaller(session: try makeSophonInstallerSession(files: ["YuanShen.exe": executable]))
        _ = try await original.run(game: .genshinImpact, destination: destination, mode: .install) { _ in }
        let cache = destination.appendingPathComponent(SophonInstaller.resumeDirectoryName, isDirectory: true)
        let receipt = cache.appendingPathComponent("committed-install.json")
        XCTAssertTrue(FileManager.default.fileExists(atPath: receipt.path))
        let pending = await original.hasPendingTransaction(destination: destination)
        XCTAssertFalse(pending, "This specifically exercises the crash window after the commit journal was removed")
        let unknown = cache.appendingPathComponent("user-notes.txt")
        try Data("preserve unknown content".utf8).write(to: unknown)
        let requests = base.appendingPathComponent("restart-requests.txt")
        try Data().write(to: requests)
        let restarted = SophonInstaller(session: try makeSophonInstallerSession(files: [:], requests: requests))

        let recovered = try await restarted.run(game: .genshinImpact, destination: destination, mode: .install) { _ in }

        XCTAssertEqual(recovered.version, "9.9.0")
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("YuanShen.exe")), executable)
        XCTAssertEqual(try Data(contentsOf: requests).count, 0, "Receipt recovery must work without any metadata or chunk requests")
        XCTAssertTrue(FileManager.default.fileExists(atPath: receipt.path), "Returning an installation result must not acknowledge registry persistence")
        try await restarted.finalizeCommittedInstall(destination: destination, game: .genshinImpact)
        XCTAssertFalse(FileManager.default.fileExists(atPath: receipt.path))
        XCTAssertEqual(try String(contentsOf: unknown, encoding: .utf8), "preserve unknown content")
    }

    func testSophonCommittedReceiptRejectsMissingCorruptOrTamperedState() async throws {
        for scenario in ["missing", "corrupt", "forged", "changed-executable", "changed-config"] {
            let base = try makeTemporaryDirectory().resolvingSymlinksInPath()
            defer { try? FileManager.default.removeItem(at: base) }
            let destination = base.appendingPathComponent("game", isDirectory: true)
            let original = SophonInstaller(session: try makeSophonInstallerSession(files: ["YuanShen.exe": Data("verified executable".utf8)]))
            _ = try await original.run(game: .genshinImpact, destination: destination, mode: .install) { _ in }
            let receipt = destination.appendingPathComponent(SophonInstaller.resumeDirectoryName)
                .appendingPathComponent("committed-install.json")
            switch scenario {
            case "missing": try FileManager.default.removeItem(at: receipt)
            case "corrupt": try Data("corrupt receipt".utf8).write(to: receipt)
            case "forged":
                var value = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: receipt)) as? [String: Any])
                value["game"] = GameType.honkaiStarRail.rawValue
                try JSONSerialization.data(withJSONObject: value).write(to: receipt)
            case "changed-executable": try Data("user modified executable".utf8).write(to: destination.appendingPathComponent("YuanShen.exe"))
            default: try Data("[General]\r\ngame_version=1.0.0\r\n".utf8).write(to: destination.appendingPathComponent("config.ini"))
            }
            let executable = try Data(contentsOf: destination.appendingPathComponent("YuanShen.exe"))
            let config = try Data(contentsOf: destination.appendingPathComponent("config.ini"))
            let receiptBefore = try? Data(contentsOf: receipt)
            let unknown = destination.appendingPathComponent("user-save.dat")
            try Data("user save".utf8).write(to: unknown)
            let requests = base.appendingPathComponent("restart-requests.txt")
            try Data().write(to: requests)
            let restarted = SophonInstaller(session: try makeSophonInstallerSession(files: [:], requests: requests))

            do {
                _ = try await restarted.run(game: .genshinImpact, destination: destination, mode: .install) { _ in }
                XCTFail("Unverified receipt state must not become installation success: \(scenario)")
            } catch {}

            XCTAssertEqual(try? Data(contentsOf: receipt), receiptBefore, "Untrusted recovery evidence must be preserved")
            XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("YuanShen.exe")), executable)
            XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("config.ini")), config)
            XCTAssertEqual(try String(contentsOf: unknown, encoding: .utf8), "user save")
            XCTAssertEqual(try Data(contentsOf: requests).count, 0, "Recovery rejection should happen before any new download")
        }
    }

    func testSophonResumeAfterInterruptedJournalKeepsVerifiedDownloads() async throws {
        let base = try makeTemporaryDirectory().resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let destination = base.appendingPathComponent("game", isDirectory: true)
        try await createPartialSophonDownload(at: destination)
        let cacheFile = try sophonCachedFile(in: destination, startingWith: Data(sophonResumeExecutable.prefix(8)))
        let cachedBytes = try Data(contentsOf: cacheFile)
        let work = destination.appendingPathComponent(SophonInstaller.transactionDirectoryName, isDirectory: true)
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        let journal: [String: Any] = ["version": 1, "game": GameType.genshinImpact.rawValue,
                                    "destination": destination.standardizedFileURL.path, "committed": false,
                                    "operations": [], "createdDirectories": []]
        try JSONSerialization.data(withJSONObject: journal).write(to: work.appendingPathComponent("journal.json"))
        let requests = base.appendingPathComponent("retry-requests.txt")
        try Data().write(to: requests)
        let restarted = SophonInstaller(session: try makeSophonInstallerSession(files: sophonResumeFiles, requests: requests, chunkSize: 8))

        try await restarted.recover(destination: destination, game: .genshinImpact)
        XCTAssertEqual(try Data(contentsOf: cacheFile), cachedBytes, "Journal recovery must preserve independent verified download staging")
        _ = try await restarted.run(game: .genshinImpact, destination: destination, mode: .install) { _ in }

        let requested = try String(contentsOf: requests, encoding: .utf8)
        for name in sophonVerifiedResumeChunks { XCTAssertFalse(requested.contains(name), name) }
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("YuanShen.exe")), sophonResumeExecutable)
    }

    func testSophonResumeRedownloadsOnlyCorruptCachedChunk() async throws {
        let base = try makeTemporaryDirectory().resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let destination = base.appendingPathComponent("game", isDirectory: true)
        try await createPartialSophonDownload(at: destination)
        let cacheFile = try sophonCachedFile(in: destination, startingWith: Data(sophonResumeExecutable.prefix(8)))
        let handle = try FileHandle(forWritingTo: cacheFile)
        try handle.write(contentsOf: Data([sophonResumeExecutable[0] ^ 0xff]))
        try handle.synchronize()
        try handle.close()
        let requests = base.appendingPathComponent("retry-requests.txt")
        try Data().write(to: requests)
        let retry = SophonInstaller(session: try makeSophonInstallerSession(files: sophonResumeFiles, requests: requests, chunkSize: 8))

        _ = try await retry.run(game: .genshinImpact, destination: destination, mode: .install) { _ in }

        let requested = try String(contentsOf: requests, encoding: .utf8)
        let damaged = try XCTUnwrap(sophonChunkNames(sophonResumeExecutable).first)
        XCTAssertTrue(requested.contains(damaged), "A marked chunk must be checked against its MD5 again")
        for name in sophonVerifiedResumeChunks where name != damaged { XCTAssertFalse(requested.contains(name), name) }
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("YuanShen.exe")), sophonResumeExecutable)
    }

    func testSophonResumeDoesNotReuseCompletedFileFromChangedManifest() async throws {
        let base = try makeTemporaryDirectory().resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let destination = base.appendingPathComponent("game", isDirectory: true)
        try await createPartialSophonDownload(at: destination)
        var changedFiles = sophonResumeFiles
        let updated = Data("new-version-file".utf8)
        changedFiles["A-complete.bin"] = updated
        let requests = base.appendingPathComponent("retry-requests.txt")
        try Data().write(to: requests)
        let retry = SophonInstaller(session: try makeSophonInstallerSession(
            files: changedFiles, requests: requests, buildVersion: "9.9.1", branchVersion: "9.9.1", chunkSize: 8
        ))

        let result = try await retry.run(game: .genshinImpact, destination: destination, mode: .install) { _ in }

        XCTAssertEqual(result.version, "9.9.1")
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("A-complete.bin")), updated)
        let requested = try String(contentsOf: requests, encoding: .utf8)
        for name in sophonChunkNames(updated) { XCTAssertTrue(requested.contains(name), "An old completed file cannot satisfy new manifest content") }
        XCTAssertTrue(try String(contentsOf: destination.appendingPathComponent("config.ini"), encoding: .utf8).contains("game_version=9.9.1"))
    }

    func testSophonResumeUpdateRetainsCompletedFilesAndContinuesRemainingChunks() async throws {
        let base = try makeTemporaryDirectory().resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let destination = base.appendingPathComponent("game", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let config = try seedSophonMainlandInstallation(at: destination)
        try await createPartialSophonDownload(at: destination, mode: .update)
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("YuanShen.exe"), encoding: .utf8), "original executable")
        XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("config.ini"), encoding: .utf8), config)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.appendingPathComponent(SophonInstaller.transactionDirectoryName).path))
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("A-complete.bin")), sophonResumeCompleteFile)
        let requests = base.appendingPathComponent("retry-requests.txt")
        try Data().write(to: requests)
        let retry = SophonInstaller(session: try makeSophonInstallerSession(files: sophonResumeFiles, requests: requests, chunkSize: 8))

        _ = try await retry.run(game: .genshinImpact, destination: destination, mode: .update) { _ in }
        try await retry.finalizeCommittedUpdate(destination: destination, game: .genshinImpact)

        let requested = try String(contentsOf: requests, encoding: .utf8)
        for name in sophonVerifiedResumeChunks { XCTAssertFalse(requested.contains(name), name) }
        XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("YuanShen.exe")), sophonResumeExecutable)
        XCTAssertTrue(try String(contentsOf: destination.appendingPathComponent("config.ini"), encoding: .utf8).contains("game_version=9.9.0"))
    }

    func testSophonResumeRefusesLinkedCacheDataWithoutChangingExternalFile() async throws {
        for symbolic in [false, true] {
            let base = try makeTemporaryDirectory().resolvingSymlinksInPath()
            defer { try? FileManager.default.removeItem(at: base) }
            let destination = base.appendingPathComponent("game", isDirectory: true)
            try await createPartialSophonDownload(at: destination)
            let cacheFile = try sophonCachedFile(in: destination, startingWith: Data(sophonResumeExecutable.prefix(8)))
            let external = base.appendingPathComponent("external-user-data.bin")
            let original = try Data(contentsOf: cacheFile)
            if symbolic {
                try FileManager.default.moveItem(at: cacheFile, to: external)
                try FileManager.default.createSymbolicLink(at: cacheFile, withDestinationURL: external)
            } else { try FileManager.default.linkItem(at: cacheFile, to: external) }
            let retry = SophonInstaller(session: try makeSophonInstallerSession(files: sophonResumeFiles, chunkSize: 8))

            do {
                _ = try await retry.run(game: .genshinImpact, destination: destination, mode: .install) { _ in }
                XCTFail("A linked partial cache file must not be opened for writing")
            } catch {}

            XCTAssertEqual(try Data(contentsOf: external), original, "Resume must never write through an external inode alias")
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("YuanShen.exe").path))
        }
    }

    func testSophonResumePreservesDataWithoutValidCheckpoint() async throws {
        for missing in [false, true] {
            let base = try makeTemporaryDirectory().resolvingSymlinksInPath()
            defer { try? FileManager.default.removeItem(at: base) }
            let destination = base.appendingPathComponent("game", isDirectory: true)
            try await createPartialSophonDownload(at: destination)
            let cacheFile = try sophonCachedFile(in: destination, startingWith: Data(sophonResumeExecutable.prefix(8)))
            let checkpoint = cacheFile.deletingPathExtension().appendingPathExtension("json")
            if missing { try FileManager.default.removeItem(at: checkpoint) }
            else { try Data("invalid progress map".utf8).write(to: checkpoint) }
            let original = try Data(contentsOf: cacheFile)
            let retry = SophonInstaller(session: try makeSophonInstallerSession(files: sophonResumeFiles, chunkSize: 8))

            do {
                _ = try await retry.run(game: .genshinImpact, destination: destination, mode: .install) { _ in }
                XCTFail("A cache data file without trustworthy ownership metadata must be preserved")
            } catch {}

            XCTAssertEqual(try Data(contentsOf: cacheFile), original)
            XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("YuanShen.exe").path))
        }
    }

    func testSophonResumeAdoptsOnlyEmptyInterruptedCacheRoot() async throws {
        for hasUnknownContent in [false, true] {
            let base = try makeTemporaryDirectory().resolvingSymlinksInPath()
            defer { try? FileManager.default.removeItem(at: base) }
            let cache = base.appendingPathComponent(SophonInstaller.resumeDirectoryName, isDirectory: true)
            try FileManager.default.createDirectory(at: cache, withIntermediateDirectories: true)
            let unknown = cache.appendingPathComponent("user-notes.txt")
            if hasUnknownContent { try Data("user content".utf8).write(to: unknown) }
            let installer = SophonInstaller(session: try makeSophonInstallerSession(files: ["YuanShen.exe": Data("fixture".utf8)]))

            if hasUnknownContent {
                do {
                    _ = try await installer.run(game: .genshinImpact, destination: base, mode: .install) { _ in }
                    XCTFail("An unowned nonempty cache directory must not be adopted or deleted")
                } catch {}
                XCTAssertEqual(try String(contentsOf: unknown, encoding: .utf8), "user content")
            } else {
                _ = try await installer.run(game: .genshinImpact, destination: base, mode: .install) { _ in }
                XCTAssertEqual(try String(contentsOf: base.appendingPathComponent("YuanShen.exe"), encoding: .utf8), "fixture")
            }
        }
    }

    func testSophonCommittedInstallRecoveryValidatesTargetsAndReturnsResult() async throws {
        for scenario in ["valid", "changed-executable", "foreign-identity"] {
            let destination = try makeTemporaryDirectory().resolvingSymlinksInPath()
            defer { try? FileManager.default.removeItem(at: destination) }
            let executable = Data("verified installed executable".utf8)
            let config = Data("[General]\r\ngame_version=9.9.0\r\nchannel=1\r\nsub_channel=1\r\ncps=mihoyo\r\n".utf8)
            let marker = try JSONSerialization.data(withJSONObject: [
                "game": scenario == "foreign-identity" ? GameType.honkaiStarRail.rawValue : GameType.genshinImpact.rawValue,
                "region": "cn",
            ])
            let targets = ["YuanShen.exe": executable, "config.ini": config, ".miplay-sophon-install.json": marker]
            for (path, bytes) in targets { try bytes.write(to: destination.appendingPathComponent(path)) }
            if scenario == "changed-executable" {
                try Data("externally modified executable".utf8).write(to: destination.appendingPathComponent("YuanShen.exe"))
            }
            let operations: [[String: Any]] = targets.keys.sorted().map {
                ["path": $0, "hadExisting": false, "installedMD5": SophonMetadataClient.md5(targets[$0]!)]
            }
            let journal: [String: Any] = ["version": 1, "game": GameType.genshinImpact.rawValue,
                                        "destination": destination.standardizedFileURL.path, "committed": true,
                                        "installMode": "install", "targetVersion": "9.9.0",
                                        "operations": operations, "createdDirectories": []]
            let transaction = destination.appendingPathComponent(SophonInstaller.transactionDirectoryName, isDirectory: true)
            try FileManager.default.createDirectory(at: transaction, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: journal).write(to: transaction.appendingPathComponent("journal.json"))
            let installer = SophonInstaller(session: try makeSophonInstallerSession(files: [:]))

            if scenario == "valid" {
                let recovered = try await installer.recover(destination: destination, game: .genshinImpact)
                XCTAssertEqual(recovered?.version, "9.9.0", "A verified committed install should finish registration without downloading again")
                let pending = await installer.hasPendingTransaction(destination: destination)
                XCTAssertFalse(pending)
            } else {
                do {
                    _ = try await installer.recover(destination: destination, game: .genshinImpact)
                    XCTFail("A changed committed target or foreign game identity cannot become installation success")
                } catch {}
                let pending = await installer.hasPendingTransaction(destination: destination)
                XCTAssertTrue(pending, "Unverified committed state must remain recoverable")
                if scenario == "changed-executable" {
                    XCTAssertEqual(try String(contentsOf: destination.appendingPathComponent("YuanShen.exe"), encoding: .utf8), "externally modified executable")
                }
            }
        }
    }

    func testSophonCommittedInstallRecoveryRejectsIncompleteOrPreexistingInstallJournal() async throws {
        for missingVersion in [false, true] {
            let destination = try makeTemporaryDirectory().resolvingSymlinksInPath()
            defer { try? FileManager.default.removeItem(at: destination) }
            let targets = [
                "YuanShen.exe": Data("verified installed executable".utf8),
                "config.ini": Data("[General]\r\ngame_version=9.9.0\r\nchannel=1\r\nsub_channel=1\r\ncps=mihoyo\r\n".utf8),
                ".miplay-sophon-install.json": try JSONSerialization.data(withJSONObject: ["game": GameType.genshinImpact.rawValue, "region": "cn"]),
            ]
            for (path, bytes) in targets { try bytes.write(to: destination.appendingPathComponent(path)) }
            let operations: [[String: Any]] = targets.keys.sorted().map {
                ["path": $0, "hadExisting": !missingVersion && $0 == "YuanShen.exe",
                 "installedMD5": SophonMetadataClient.md5(targets[$0]!)]
            }
            var journal: [String: Any] = ["version": 1, "game": GameType.genshinImpact.rawValue,
                                         "destination": destination.standardizedFileURL.path, "committed": true,
                                         "installMode": "install", "operations": operations, "createdDirectories": []]
            if !missingVersion { journal["targetVersion"] = "9.9.0" }
            let transaction = destination.appendingPathComponent(SophonInstaller.transactionDirectoryName, isDirectory: true)
            try FileManager.default.createDirectory(at: transaction, withIntermediateDirectories: true)
            try JSONSerialization.data(withJSONObject: journal).write(to: transaction.appendingPathComponent("journal.json"))
            let installer = SophonInstaller(session: try makeSophonInstallerSession(files: [:]))

            do {
                _ = try await installer.recover(destination: destination, game: .genshinImpact)
                XCTFail("An install journal must declare its exact target version and cannot overwrite a preexisting executable")
            } catch {}

            let pending = await installer.hasPendingTransaction(destination: destination)
            XCTAssertTrue(pending, "An ambiguous committed install must remain available for recovery")
            for (path, bytes) in targets { XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent(path)), bytes) }
        }
    }

    func testSophonResumeRefusesCompletelyVerifiedSharedInode() async throws {
        let base = try makeTemporaryDirectory().resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: base) }
        let destination = base.appendingPathComponent("game", isDirectory: true)
        try await createPartialSophonDownload(at: destination)
        let complete = try sophonCachedFile(in: destination, startingWith: sophonResumeCompleteFile)
        XCTAssertEqual(try Data(contentsOf: complete), sophonResumeCompleteFile)
        let external = base.appendingPathComponent("external-user-file.bin")
        try FileManager.default.linkItem(at: complete, to: external)
        let retry = SophonInstaller(session: try makeSophonInstallerSession(files: sophonResumeFiles, chunkSize: 8))

        do {
            _ = try await retry.run(game: .genshinImpact, destination: destination, mode: .install) { _ in }
            XCTFail("A complete, correct cache file sharing a user inode cannot become a hard-linked installed file")
        } catch { XCTAssertTrue(error.localizedDescription.contains("缓存"), "\(error)") }

        XCTAssertEqual(try Data(contentsOf: external), sophonResumeCompleteFile)
        XCTAssertEqual(try Data(contentsOf: complete), sophonResumeCompleteFile)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("A-complete.bin").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.appendingPathComponent("YuanShen.exe").path))
        let pending = await retry.hasPendingTransaction(destination: destination)
        XCTAssertFalse(pending)
    }

    private var sophonResumeExecutable: Data { Data((0..<96).map { UInt8($0) }) }
    private var sophonResumeCompleteFile: Data { Data("already-finished".utf8) }
    private var sophonResumeFiles: [String: Data] {
        ["A-complete.bin": sophonResumeCompleteFile, "YuanShen.exe": sophonResumeExecutable]
    }
    private var sophonVerifiedResumeChunks: [String] {
        sophonChunkNames(sophonResumeCompleteFile) + Array(sophonChunkNames(sophonResumeExecutable).prefix(4))
    }

    private func sophonChunkNames(_ data: Data) -> [String] {
        stride(from: 0, to: data.count, by: 8).map {
            "chunk-" + SophonMetadataClient.md5(data.subdata(in: $0..<min($0 + 8, data.count)))
        }
    }

    private func createPartialSophonDownload(at destination: URL, mode: SophonInstallMode = .install) async throws {
        let paused = ObservationFlag()
        let installer = SophonInstaller(session: try makeSophonInstallerSession(
            files: sophonResumeFiles, chunkSize: 8, pauseAfterChunk: 4, pauseSignal: paused
        ))
        let operation = Task { try await installer.run(game: .genshinImpact, destination: destination, mode: mode) { _ in } }
        defer { operation.cancel() }
        let deadline = Date().addingTimeInterval(5)
        while !paused.isSet && Date() < deadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertTrue(paused.isSet, "The second batch must begin only after four chunks have been persisted")
        operation.cancel()
        do { _ = try await operation.value; XCTFail("Expected cancellation with reusable verified staging") }
        catch { XCTAssertTrue(error is CancellationError, "\(error)") }
        let partial = try sophonCachedFile(in: destination, startingWith: Data(sophonResumeExecutable.prefix(8)))
        XCTAssertEqual(Data(try Data(contentsOf: partial).prefix(32)), Data(sophonResumeExecutable.prefix(32)))
        let pending = await installer.hasPendingTransaction(destination: destination)
        switch mode {
        case .install:
            let complete = try sophonCachedFile(in: destination, startingWith: sophonResumeCompleteFile)
            XCTAssertEqual(try Data(contentsOf: complete), sophonResumeCompleteFile)
            XCTAssertFalse(pending, "Fresh installation retains verified downloads after rolling back its v1 transaction")
        case .update, .updateConfirmedMainland:
            XCTAssertEqual(try Data(contentsOf: destination.appendingPathComponent("A-complete.bin")), sophonResumeCompleteFile)
            XCTAssertTrue(pending, "Incremental updates retain their forward-resume journal and completed files")
        }
    }

    private func sophonCachedFile(in destination: URL, startingWith prefix: Data) throws -> URL {
        let root = destination.appendingPathComponent(SophonInstaller.resumeDirectoryName, isDirectory: true)
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []
        return try XCTUnwrap(files.first {
            guard $0.pathExtension == "data", let bytes = try? Data(contentsOf: $0) else { return false }
            return bytes.starts(with: prefix)
        }, "Expected persisted, verified download data")
    }

    private func seedSophonMainlandInstallation(at destination: URL) throws -> String {
        try Data("original executable".utf8).write(to: destination.appendingPathComponent("YuanShen.exe"))
        let config = "[General]\r\ngame_version=1.0.0\r\nchannel=1\r\nsub_channel=1\r\ncps=mihoyo\r\ncustom_setting=preserve-me\r\n"
        try config.write(to: destination.appendingPathComponent("config.ini"), atomically: true, encoding: .utf8)
        return config
    }

    private func makeSophonInstallerSession(files: [String: Data], corruptPath: String? = nil,
                                           requests: URL? = nil, deletions: [String: Data] = [:],
                                           otherVersionDeletions: [String: Data] = [:],
                                           branchGameID: String = "1Z8W5NHUQb", buildVersion: String = "9.9.0", branchVersion: String = "9.9.0",
                                           historicalFiles: [String: Data] = [:],
                                           historicalResponseVersion: String? = nil, chunkSize: Int? = nil,
                                           reverseChunkResponses: Bool = false, chunkStarted: ObservationFlag? = nil,
                                           pauseAfterChunk: Int? = nil, pauseSignal: ObservationFlag? = nil,
                                           preDownloadVersion: String? = nil) throws -> URLSession {
        var manifest = Data()
        var audioManifest = Data()
        var responses: [String: Data] = [:]
        var delays: [String: TimeInterval] = [:]
        var pausedChunks = Set<String>()
        var fixtureFiles = files
        fixtureFiles["Audio_Chinese_pkg_version"] = Data("fixture Chinese voice package".utf8)
        for path in fixtureFiles.keys.sorted() {
            let content = try XCTUnwrap(fixtureFiles[path])
            let size = max(1, chunkSize ?? content.count)
            let pieces = stride(from: 0, to: content.count, by: size).map { content.subdata(in: $0..<min($0 + size, content.count)) }
            var chunks = Data()
            var offset: UInt64 = 0
            for (index, piece) in pieces.enumerated() {
                let digest = SophonMetadataClient.md5(piece)
                let chunkName = "chunk-" + digest
                let compressed = sophonRawZstdFrame(piece)
                let chunk = sophonProtobufBytes(1, Data(chunkName.utf8))
                    + sophonProtobufBytes(2, Data(digest.utf8)) + sophonProtobufNumber(3, offset)
                    + sophonProtobufNumber(4, UInt64(compressed.count)) + sophonProtobufNumber(5, UInt64(piece.count))
                chunks.append(sophonProtobufBytes(2, chunk))
                offset += UInt64(piece.count)
                responses[chunkName] = path == corruptPath ? Data(compressed.dropLast()) : compressed
                if reverseChunkResponses { delays[chunkName] = Double(max(0, min(3, pieces.count - index - 1))) * 0.2 }
                if let pauseAfterChunk, path == "YuanShen.exe", index >= pauseAfterChunk {
                    pausedChunks.insert(chunkName)
                    delays[chunkName] = 2
                }
            }
            let file = sophonProtobufBytes(1, Data(path.utf8)) + chunks
                + sophonProtobufNumber(4, UInt64(content.count)) + sophonProtobufBytes(5, Data(SophonMetadataClient.md5(content).utf8))
            if path == "Audio_Chinese_pkg_version" { audioManifest.append(sophonProtobufBytes(1, file)) }
            else { manifest.append(sophonProtobufBytes(1, file)) }
        }
        let compressedManifest = sophonRawZstdFrame(manifest)
        let descriptor: [String: Any] = ["category_id": "fixture-game", "matching_field": "game",
                                        "type": "CATEGORY_TYPE_RESOURCE", "scenarios": ["CATEGORY_SCENARIO_FULL"]]
        let audioDescriptor: [String: Any] = ["category_id": "fixture-audio", "matching_field": "zh-cn",
                                            "type": "CATEGORY_TYPE_AUDIO", "scenarios": ["CATEGORY_SCENARIO_FULL"]]
        // Only deletion-specific fixtures advertise a direct diff. The
        // ordinary FULL fixtures must use the exact historical manifest
        // instead of pretending that a patch-capable branch exists.
        let diffTags = deletions.isEmpty && otherVersionDeletions.isEmpty ? [] : ["1.0.0"]
        var gameBranch: [String: Any] = [
            "game": ["id": branchGameID, "biz": "hk4e_cn"],
            "main": ["branch": "main", "tag": branchVersion, "package_id": "fixture", "password": "fixture",
                     "diff_tags": diffTags, "categories": [descriptor, audioDescriptor]],
        ]
        if let preDownloadVersion {
            gameBranch["pre_download"] = ["branch": "predownload", "tag": preDownloadVersion,
                                          "package_id": "fixture", "password": "fixture", "diff_tags": diffTags,
                                          "categories": [descriptor, audioDescriptor]]
        }
        let branches: [String: Any] = ["retcode": 0, "data": ["game_branches": [gameBranch]]]
        let manifestInfo: [String: Any] = [
            "category_id": "fixture-game", "matching_field": "game",
            "manifest": ["id": "fixture-manifest", "checksum": SophonMetadataClient.md5(manifest),
                         "uncompressed_size": String(manifest.count), "compressed_size": String(compressedManifest.count)],
            "manifest_download": ["encryption": 0, "compression": 1, "url_prefix": "https://autopatchcn.yuanshen.com/fixtures/manifests", "url_suffix": ""],
            "chunk_download": ["encryption": 0, "compression": 1, "url_prefix": "https://autopatchcn.yuanshen.com/fixtures/chunks", "url_suffix": ""],
        ]
        var audioInfo = manifestInfo
        audioInfo["category_id"] = "fixture-audio"
        audioInfo["matching_field"] = "zh-cn"
        audioInfo["manifest"] = ["id": "fixture-audio-manifest", "checksum": SophonMetadataClient.md5(audioManifest),
                                 "uncompressed_size": String(audioManifest.count)]
        var diffManifest = sophonDeletionManifest(version: "1.0.0", files: deletions)
        if !otherVersionDeletions.isEmpty {
            diffManifest.append(sophonDeletionManifest(version: "0.9.0", files: otherVersionDeletions))
        }
        var diffInfo = manifestInfo
        diffInfo["manifest"] = ["id": "fixture-diff-manifest", "checksum": SophonMetadataClient.md5(diffManifest),
                                "uncompressed_size": String(diffManifest.count),
                                "compressed_size": String(sophonRawZstdFrame(diffManifest).count)]
        diffInfo["diff_download"] = ["encryption": 0, "compression": 0,
                                     "url_prefix": "https://autopatchcn.yuanshen.com/fixtures/patches", "url_suffix": ""]
        let audioDiff = sophonDeletionManifest(version: "1.0.0", files: [:])
        var audioDiffInfo = audioInfo
        audioDiffInfo["manifest"] = ["id": "fixture-audio-diff-manifest", "checksum": SophonMetadataClient.md5(audioDiff),
                                     "uncompressed_size": String(audioDiff.count),
                                     "compressed_size": String(sophonRawZstdFrame(audioDiff).count)]
        audioDiffInfo["diff_download"] = diffInfo["diff_download"]
        var historicalManifest = Data()
        for path in historicalFiles.keys.sorted() {
            guard let content = historicalFiles[path] else { continue }
            let file = sophonProtobufBytes(1, Data(path.utf8)) + sophonProtobufNumber(4, UInt64(content.count))
                + sophonProtobufBytes(5, Data(SophonMetadataClient.md5(content).utf8))
            historicalManifest.append(sophonProtobufBytes(1, file))
        }
        var historicalInfo = manifestInfo
        historicalInfo["manifest"] = ["id": "fixture-historical-manifest", "checksum": SophonMetadataClient.md5(historicalManifest),
                                      "uncompressed_size": String(historicalManifest.count)]
        responses["getGameBranches"] = try JSONSerialization.data(withJSONObject: branches)
        responses["getBuild"] = try JSONSerialization.data(withJSONObject: ["retcode": 0, "data": ["tag": buildVersion, "manifests": [manifestInfo, audioInfo]]])
        responses["getPatchBuild"] = try JSONSerialization.data(withJSONObject: ["retcode": 0, "data": ["tag": buildVersion, "manifests": [diffInfo, audioDiffInfo]]])
        // Return the exact requested historical tag unless the test opts in
        // to a mismatched server response.
        for tag in ["0.9.0", "1.0.0"] {
            responses["historical-getBuild-\(tag)"] = try JSONSerialization.data(withJSONObject: [
                "retcode": 0, "data": ["tag": historicalResponseVersion ?? tag, "manifests": [historicalInfo, audioInfo]]
            ])
        }
        responses["fixture-manifest"] = compressedManifest
        responses["fixture-audio-manifest"] = sophonRawZstdFrame(audioManifest)
        responses["fixture-diff-manifest"] = sophonRawZstdFrame(diffManifest)
        responses["fixture-audio-diff-manifest"] = sophonRawZstdFrame(audioDiff)
        responses["fixture-historical-manifest"] = sophonRawZstdFrame(historicalManifest)
        let payloads = responses
        let responseDelays = delays
        let pausedNames = pausedChunks
        MockURLProtocol.configure { request in
            let tag = request.url.flatMap { URLComponents(url: $0, resolvingAgainstBaseURL: false) }?
                .queryItems?.first(where: { $0.name == "tag" })?.value
            if let requests, let handle = try? FileHandle(forWritingTo: requests) {
                defer { try? handle.close() }
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(((request.httpMethod ?? "GET") + " " + (request.url?.lastPathComponent ?? "unknown") + (tag.map { " tag=" + $0 } ?? "") + (reverseChunkResponses ? " t=\(ProcessInfo.processInfo.systemUptime)" : "") + "\n").utf8))
            }
            guard let name = request.url?.lastPathComponent else {
                return .init(data: Data(), statusCode: 404)
            }
            let key = name == "getBuild" ? tag.map { "historical-getBuild-\($0)" } ?? name : name
            guard let data = payloads[key] else {
                return .init(data: Data(), statusCode: 404)
            }
            if name == "getPatchBuild", request.httpMethod != "POST" {
                return .init(data: Data(), statusCode: 405)
            }
            if name.hasPrefix("chunk-") { chunkStarted?.mark() }
            if pausedNames.contains(name) { pauseSignal?.mark() }
            return .init(data: data, delay: responseDelays[name] ?? 0)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    private func sophonDeletionManifest(version: String, files: [String: Data]) -> Data {
        var entries = Data()
        for path in files.keys.sorted() {
            guard let content = files[path] else { continue }
            let file = sophonProtobufBytes(1, Data(path.utf8)) + sophonProtobufNumber(2, UInt64(content.count))
                + sophonProtobufBytes(3, Data(SophonMetadataClient.md5(content).utf8))
            entries.append(sophonProtobufBytes(1, file))
        }
        let group = sophonProtobufBytes(1, Data(version.utf8)) + sophonProtobufBytes(2, entries)
        return sophonProtobufBytes(2, group)
    }

    private func sophonRawZstdFrame(_ bytes: Data) -> Data {
        // A single-segment Zstandard frame with a raw block. Fixture payloads
        // are small; production decompression is exercised without a test CLI.
        precondition(bytes.count < 128 * 1024)
        var frame = Data([0x28, 0xb5, 0x2f, 0xfd, 0xa0])
        for shift in stride(from: 0, to: 32, by: 8) { frame.append(UInt8((UInt32(bytes.count) >> shift) & 0xff)) }
        let header = (UInt32(bytes.count) << 3) | 1
        for shift in stride(from: 0, to: 24, by: 8) { frame.append(UInt8((header >> shift) & 0xff)) }
        frame.append(bytes)
        return frame
    }

    private func sophonProtobufVarint(_ input: UInt64) -> Data {
        var value = input
        var bytes = Data()
        while value >= 128 { bytes.append(UInt8(value & 0x7f) | 0x80); value >>= 7 }
        bytes.append(UInt8(value))
        return bytes
    }

    private func sophonProtobufNumber(_ field: UInt64, _ value: UInt64) -> Data {
        sophonProtobufVarint(field << 3) + sophonProtobufVarint(value)
    }

    private func sophonProtobufBytes(_ field: UInt64, _ value: Data) -> Data {
        sophonProtobufVarint((field << 3) | 2) + sophonProtobufVarint(UInt64(value.count)) + value
    }

    func testCurrentGitHubWineReleaseAssetsAreDiscoverable() async throws {
        let network = try makeMockNetwork(response: Self.currentWineReleasesJSON(assetSize: 128))
        let fixture = try await makeScheduler(networkProvider: network)

        let versions = try await fixture.wineManager.fetchAvailableVersions()

        XCTAssertEqual(
            Set(versions.map(\.tagName)),
            [WineVersionManager.fixedRuntimeTag]
        )
        XCTAssertTrue(versions.allSatisfy { $0.assetName.contains("osx64") })
    }

    /// 设置页展示的「来源」仓库地址必须与下载用的 API 端点指向同一仓库。
    func testSourceRepositoryWebURLMatchesAPIEndpoint() {
        let source = BuiltInWineVersions.officialSource
        XCTAssertEqual(
            source.repositoryWebURL.absoluteString,
            "https://github.com/yaagl/anime-game-wine"
        )
        XCTAssertEqual(source.repositoryWebURL.host, source.allowedAssetHost)
        XCTAssertTrue(
            source.apiEndpoint.path.contains(source.repositoryWebURL.path),
            "API 端点与仓库地址必须指向同一仓库：\(source.apiEndpoint.path) vs \(source.repositoryWebURL.path)"
        )
    }

    func testWineCatalogDiagnosticsAndAllowlistGate() async throws {
        let forbidden = try await makeScheduler(networkProvider: makeWineNetwork(catalogStatus: 403))
        do {
            _ = try await forbidden.wineManager.fetchAvailableVersions()
            XCTFail("Expected GitHub API 403")
        } catch let error as WineVersionManager.VersionManagerError {
            guard case .apiForbidden(let sourceID, let detail) = error else {
                return XCTFail("Unexpected Wine catalog error: \(error)")
            }
            XCTAssertEqual(sourceID, BuiltInWineVersions.officialSource.sourceID)
            XCTAssertTrue(detail.lowercased().contains("forbidden"))
        }

        let rateLimited = try await makeScheduler(networkProvider: makeWineNetwork(catalogStatus: 429))
        let fallback429 = try await rateLimited.wineManager.fetchAvailableVersions()
        XCTAssertEqual(fallback429.first?.downloadURL, BuiltInWineVersions.fixedAssetURL)
        XCTAssertEqual(fallback429.first?.expectedSHA256, BuiltInWineVersions.fixedAssetSHA256)

        let rateLimitBody = Data("{\"message\":\"API rate limit exceeded\"}".utf8)
        let rateLimited403 = try await makeScheduler(networkProvider: makeMockNetwork(response: rateLimitBody, statusCode: 403))
        let fallback403 = try await rateLimited403.wineManager.fetchAvailableVersions()
        XCTAssertEqual(fallback403.first?.downloadURL, BuiltInWineVersions.fixedAssetURL)
        XCTAssertEqual(fallback403.first?.fileSize, BuiltInWineVersions.fixedAssetSize)
        XCTAssertEqual(fallback403.first?.expectedSHA256, BuiltInWineVersions.fixedAssetSHA256)

        let rejectedAsset = try await makeScheduler(
            networkProvider: makeWineNetwork(
                assetURL: "https://unapproved.example/wine-arm64.tar.xz"
            )
        )
        let versions = try await rejectedAsset.wineManager.fetchAvailableVersions()
        XCTAssertTrue(versions.isEmpty)
        let rejectedEntry = await rejectedAsset.wineManager.cachedAvailableVersion(
            tagName: WineVersionManager.fixedRuntimeTag
        )
        XCTAssertNil(rejectedEntry)

        let invalidVersion = WineVersionInfo(
            id: WineVersionManager.fixedRuntimeTag,
            tagName: WineVersionManager.fixedRuntimeTag,
            name: "Untrusted fixture",
            downloadURL: URL(string: "https://unapproved.example/wine-crossover-11.0-1-osx64-signed.tar.xz")!,
            fileSize: 1,
            publishedAt: Date(),
            assetName: "wine-crossover-11.0-1-osx64-signed.tar.xz"
        )
        let invalidPhases = await collectWinePhases(
            await rejectedAsset.wineManager.downloadAndInstall(version: invalidVersion)
        )
        XCTAssertTrue(invalidPhases.contains {
            if case .failed = $0 { return true }
            return false
        })
        XCTAssertFalse(invalidPhases.contains {
            if case .completed = $0 { return true }
            return false
        })
    }

    func testPinnedWineArchiveSHA256IsCheckedBeforeExtraction() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = try makeWineArchive(fillerBytes: 64)
        let network = try makeWineNetwork(archive: archive)
        let fileSystem = GameFileSystemRepository(appSupportDirectory: root)
        let logger = LogWriter(fileSystemRepository: fileSystem)
        let downloader = WineVersionDownloader(networkProvider: network, fileSystemRepository: fileSystem,
                                               processManager: ProcessManager(), logWriter: logger)
        let correctDigest = await fileSystem.calculateSHA256(of: archive)
        for expectedDigest in [String(repeating: "0", count: 64), correctDigest] {
            let stage = root.appendingPathComponent("WineVersions/.staging/\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: true)
            let staging = try WineVersionDownloader.ManagedStaging(rootURL: stage.deletingLastPathComponent(), directoryURL: stage)
            let asset = WineVersionDownloader.ApprovedAsset(
                sourceID: BuiltInWineVersions.officialSource.sourceID,
                tagName: WineVersionManager.fixedRuntimeTag,
                url: BuiltInWineVersions.fixedAssetURL,
                assetName: BuiltInWineVersions.fixedAssetName,
                fileSize: Int64(archive.count), expectedSHA256: expectedDigest
            )
            let phases = await collectWinePhases(await downloader.downloadAndExtract(asset: asset, staging: staging))
            if expectedDigest == correctDigest {
                XCTAssertTrue(phases.contains { if case .completed = $0 { return true }; return false }, "\(phases)")
            } else {
                XCTAssertTrue(phases.contains { if case .failed(let detail) = $0 { return detail.contains("SHA-256") }; return false }, "\(phases)")
                XCTAssertFalse(phases.contains { if case .extracting = $0 { return true }; return false })
                XCTAssertFalse(FileManager.default.fileExists(atPath: stage.path))
            }
        }
    }

    func testWineDownloaderRejectsUnapprovedRedirectHost() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = try makeWineArchive(fillerBytes: 64)
        let network = try makeWineNetwork(
            archive: archive,
            downloadResponseURL: "https://unapproved.example/wine-arm64.tar.xz"
        )
        let fileSystem = GameFileSystemRepository(appSupportDirectory: root)
        let process = ProcessManager()
        let logger = LogWriter(fileSystemRepository: fileSystem)
        let downloader = WineVersionDownloader(
            networkProvider: network,
            fileSystemRepository: fileSystem,
            processManager: process,
            logWriter: logger
        )
        let asset = WineVersionDownloader.ApprovedAsset(
            sourceID: BuiltInWineVersions.officialSource.sourceID,
            tagName: WineVersionManager.fixedRuntimeTag,
            url: URL(string: "https://github.com/yaagl/anime-game-wine/releases/download/\(WineVersionManager.fixedRuntimeTag)/wine-crossover-11.0-1-osx64-signed.tar.xz")!,
            assetName: "wine-crossover-11.0-1-osx64-signed.tar.xz",
            fileSize: Int64(archive.count)
        )
        let staging = root.appendingPathComponent("staging", isDirectory: true)
        let phases = await collectWinePhases(
            await downloader.downloadArchive(for: asset, to: staging.path)
        )

        XCTAssertTrue(phases.contains {
            if case .failed(let detail) = $0 { return detail.contains("未批准来源") }
            return false
        }, "phases: \(phases)")
        XCTAssertFalse(phases.contains {
            if case .completed = $0 { return true }
            return false
        })
        XCTAssertFalse(FileManager.default.fileExists(atPath: staging.appendingPathComponent("wine.tar.xz").path))
    }

    func testNetworkDownloadRejectsNonHTTPResponse() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let network = try makeDownloadNetwork(
            response: .init(data: Data("payload".utf8), responseIsHTTP: false)
        )
        let destination = root.appendingPathComponent("payload.bin")
        let stream = await network.download(
            from: URL(string: "https://example.test/payload.bin")!,
            to: destination.path
        )

        let progress = await collectDownloadProgress(stream)
        XCTAssertTrue(progress.contains { $0.error == "下载失败: 未收到 HTTP 响应" })
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testNetworkDownloadRejectsMissingResponse() async throws {
        let root = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let network = try makeDownloadNetwork(
            response: .init(data: Data("payload".utf8), sendsResponse: false)
        )
        let destination = root.appendingPathComponent("payload.bin")
        let stream = await network.download(
            from: URL(string: "https://example.test/payload.bin")!,
            to: destination.path
        )

        let progress = await collectDownloadProgress(stream)
        XCTAssertTrue(progress.contains { $0.error != nil })
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
    }

    func testWineAsset403RemainsAccessDenied() async throws {
        try await assertWineAssetHTTPFailure(statusCode: 403)
    }

    func testWineAsset404RemainsResourceNotFound() async throws {
        try await assertWineAssetHTTPFailure(statusCode: 404)
    }

    func testWineAsset429RemainsRateLimited() async throws {
        try await assertWineAssetHTTPFailure(statusCode: 429)
    }

    func testWineAsset5xxRemainsServerError() async throws {
        try await assertWineAssetHTTPFailure(statusCode: 503)
    }

    func testWineRuntimeSetupHTTPFailureIsPersistedAsFailedTask() async throws {
        let fixture = try await makeScheduler(networkProvider: makeWineNetwork(assetStatus: 403))
        let setupReceipt = try await fixture.scheduler.enqueueReceipt(
            type: .wineRuntimeSetup,
            gameId: nil,
            context: ["runtimeIdentity": WineVersionManager.fixedRuntimeTag]
        )
        let result = try await waitForTask(setupReceipt.taskID, scheduler: fixture.scheduler)
        XCTAssertEqual(result.state, .failed)
        XCTAssertTrue(result.error?.contains("403") == true, "error: \(result.error ?? "nil")")
        XCTAssertFalse(result.error?.contains("networkUnavailable") == true)
        XCTAssertNotEqual(result.outcome, "runtimePairReady")
    }

    @MainActor
    func testPerformanceOptionsArePerGameAndPersist() async throws {
        let baseURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: baseURL) }
        let store = PersistenceStore(baseURL: baseURL)
        try await store.writeAppData(AppData())
        let manager = PerformanceOptionManager(
            persistenceStore: store,
            logWriter: LogWriter(fileSystemRepository: GameFileSystemRepository())
        )
        await manager.loadOptions()

        let genshin = GameType.genshinImpact.rawValue
        let starRail = GameType.honkaiStarRail.rawValue
        let zzz = GameType.zenlessZoneZero.rawValue

        // Metal HUD 三款都可用；解锁帧率只对原神/星铁开放（绝区零原生无限帧率）。
        XCTAssertTrue(manager.getOptions(for: genshin).contains { $0.id == "metal_hud" })
        XCTAssertTrue(manager.getOptions(for: zzz).contains { $0.id == "metal_hud" })
        XCTAssertTrue(manager.getOptions(for: genshin).contains { $0.id == "fps_unlock" })
        XCTAssertTrue(manager.getOptions(for: starRail).contains { $0.id == "fps_unlock" })
        XCTAssertFalse(manager.getOptions(for: zzz).contains { $0.id == "fps_unlock" })

        // 每游戏独立：只打开原神的 Metal HUD。
        try await manager.setOption(gameId: genshin, optionId: "metal_hud", enabled: true)
        XCTAssertEqual(manager.getOption(gameId: genshin, optionId: "metal_hud")?.isEnabled, true)
        XCTAssertEqual(manager.getOption(gameId: zzz, optionId: "metal_hud")?.isEnabled, false)

        // 该选项已搁置（用户指令：Metal HUD 等移到「通用设置」的应用级开关）：
        // 即使每游戏开关仍为 true，也不会进入启动清单；HUD 现由
        // `GameEnvironmentSettings.environmentVariables` 在启动时注入。
        XCTAssertTrue(manager.getOptionsForLaunch(gameId: genshin).isEmpty)
        XCTAssertEqual(
            GameEnvironmentSettings(metalHUD: true).environmentVariables["MTL_HUD_ENABLED"],
            "1"
        )

        let persisted = try await store.readAppData()
        XCTAssertEqual(
            persisted.performanceOptions[genshin]?.first(where: { $0.id == "metal_hud" })?.isEnabled,
            true
        )
        XCTAssertEqual(
            persisted.performanceOptions[zzz]?.first(where: { $0.id == "metal_hud" })?.isEnabled,
            false
        )
    }

    @MainActor
    func testSettingsProjectsAssetHTTPFailureWithoutNetworkUnavailableFallback() async throws {
        let fixture = try await makeScheduler(networkProvider: makeWineNetwork(assetStatus: 404))
        let viewModel = SettingsViewModel(
            systemDetector: SystemEnvironmentDetector(),
            wineVersionManager: fixture.wineManager,
            gameRegistry: fixture.registry,
            fileSystemRepository: GameFileSystemRepository(appSupportDirectory: try makeTemporaryDirectory()),
            taskScheduler: fixture.scheduler,
            performanceOptionManager: PerformanceOptionManager(
                persistenceStore: fixture.persistence,
                logWriter: fixture.logger
            )
        )

        await viewModel.loadSettings()
        await viewModel.setupWineRuntime()
        let downloadDeadline = Date().addingTimeInterval(3)
        while Date() < downloadDeadline {
            if viewModel.wineDownloadTask?.state == .failed, viewModel.errorMessage != nil { break }
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertEqual(viewModel.wineDownloadTask?.state, .failed)
        XCTAssertTrue(viewModel.errorMessage?.contains("404") == true, "error: \(viewModel.errorMessage ?? "nil")")
        XCTAssertFalse(viewModel.errorMessage?.contains("networkUnavailable") == true)
    }

    @MainActor
    func testSettingsProjectsOnlyTheFixedWineRuntime() async throws {
        let fixture = try await makeScheduler()
        let viewModel = SettingsViewModel(
            systemDetector: SystemEnvironmentDetector(),
            wineVersionManager: fixture.wineManager,
            gameRegistry: fixture.registry,
            fileSystemRepository: GameFileSystemRepository(appSupportDirectory: try makeTemporaryDirectory()),
            taskScheduler: fixture.scheduler,
            performanceOptionManager: PerformanceOptionManager(
                persistenceStore: fixture.persistence,
                logWriter: fixture.logger
            )
        )

        await viewModel.loadSettings()
        XCTAssertEqual(viewModel.fixedRuntimeTag, WineVersionManager.fixedRuntimeTag)
        XCTAssertFalse(viewModel.sharedPrefixReady)
        XCTAssertTrue(viewModel.sharedPrefixPath.isEmpty)
    }

    func testPerGameSettingsRemainIsolatedAcrossPersistenceRoundTrip() async throws {
        let baseURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: baseURL) }
        let store = PersistenceStore(baseURL: baseURL)
        let genshinID = GameType.genshinImpact.rawValue
        let starRailID = GameType.honkaiStarRail.rawValue
        try await store.writeAppData(AppData(perGameSettings: [
            genshinID: PerGameSettings(gameID: genshinID, metadataDisplayEnabled: false),
            starRailID: PerGameSettings(gameID: starRailID, metadataDisplayEnabled: true)
        ]))

        var data = try await store.readAppData()
        data.perGameSettings[genshinID]?.lastFailure = "metadata conflict"
        try await store.writeAppData(data)

        let restored = try await store.readAppData()
        XCTAssertFalse(restored.perGameSettings[genshinID]?.metadataDisplayEnabled ?? true)
        XCTAssertEqual(restored.perGameSettings[genshinID]?.lastFailure, "metadata conflict")
        XCTAssertTrue(restored.perGameSettings[starRailID]?.metadataDisplayEnabled ?? false)
        XCTAssertNil(restored.perGameSettings[starRailID]?.lastFailure)
    }

    // MARK: - I-1 background cache fingerprint

    func testBackgroundRetentionPreferencesAreIndependentPerGame() async throws {
        let baseURL = try makeTemporaryDirectory()
        let supportURL = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: baseURL)
            try? FileManager.default.removeItem(at: supportURL)
        }
        let cache = MediaCacheManager(baseURL: supportURL)
        let genshin = GameType.genshinImpact.rawValue
        let starRail = GameType.honkaiStarRail.rawValue
        for gameID in [genshin, starRail] {
            try await seedBackgroundCache(cache: cache, gameID: gameID, groupID: "current")
            try await seedBackgroundCache(cache: cache, gameID: gameID, groupID: "outdated")
            try await writeFingerprint(cache: cache, gameID: gameID, groupIDs: ["outdated"])
        }
        let store = PersistenceStore(baseURL: baseURL)
        try await store.writeAppData(AppData(backgroundModes: [
            genshin: BackgroundMediaService.BackgroundMode.static.rawValue,
            starRail: BackgroundMediaService.BackgroundMode.static.rawValue
        ]))
        let defaults = makeBackgroundDefaults(retainOutdated: true)
        let genshinKey = BackgroundMediaService.retentionPreferenceKey(forGameID: genshin)
        let starRailKey = BackgroundMediaService.retentionPreferenceKey(forGameID: starRail)
        XCTAssertNotEqual(genshinKey, starRailKey)
        defaults.set(false, forKey: genshinKey)
        let service = try makeBackgroundService(cacheBase: supportURL, store: store,
            network: makeBackgroundDownloadNetwork(metadata: multiGameBackgroundResponse()), userDefaults: defaults)
        await service.loadSettings()
        XCTAssertFalse(service.retainsOutdatedBackgrounds(for: genshin))
        XCTAssertTrue(service.retainsOutdatedBackgrounds(for: starRail), "A missing per-game preference preserves the existing enabled behavior")

        await service.loadMedia(for: genshin)
        await service.loadMedia(for: starRail)
        await service.waitForRetainedBackgrounds(for: genshin)
        await service.waitForRetainedBackgrounds(for: starRail)
        let genshinOther = await cache.cachedFileURL(forKey: "background.webp", inDirectory: "\(genshin)/other")
        let starRailOther = await cache.cachedFileURL(forKey: "background.webp", inDirectory: "\(starRail)/other")
        XCTAssertFalse(FileManager.default.fileExists(atPath: genshinOther.path))
        XCTAssertEqual(try Data(contentsOf: starRailOther), Data("media fixture".utf8))
        let genshinGroups = try await cache.groupDirectoryNames(forGameId: genshin)
        let starRailGroups = try await cache.groupDirectoryNames(forGameId: starRail)
        XCTAssertFalse(genshinGroups.contains("outdated"), "Disabled retention prunes this game's old group")
        XCTAssertTrue(starRailGroups.contains("outdated"), "Another game's enabled history must remain")
        for gameID in [genshin, starRail] {
            guard case .ready(let path, let isVideo) = service.getMediaState(for: gameID) else {
                return XCTFail("Expected selected background for \(gameID)")
            }
            XCTAssertFalse(isVideo)
            XCTAssertTrue(path.hasSuffix("/current/background.png"))
        }

        defaults.set(true, forKey: genshinKey)
        service.retentionSettingDidChange(forGameID: genshin)
        await service.waitForRetainedBackgrounds(for: genshin)
        XCTAssertEqual(try Data(contentsOf: genshinOther), Data("media fixture".utf8),
                       "Enabling one game should fill already fetched groups without reloading the foreground")

        defaults.set(false, forKey: BackgroundMediaService.retainOutdatedBackgroundsKey)
        service.retentionSettingDidChange()
        XCTAssertFalse(service.retainsOutdatedBackgrounds(for: genshin))
        XCTAssertFalse(service.retainsOutdatedBackgrounds(for: starRail))
        XCTAssertTrue(defaults.bool(forKey: genshinKey), "The master switch must not erase an individual preference")
        defaults.set(true, forKey: BackgroundMediaService.retainOutdatedBackgroundsKey)
        defaults.set(false, forKey: starRailKey)
        XCTAssertTrue(service.retainsOutdatedBackgrounds(for: genshin))
        XCTAssertFalse(service.retainsOutdatedBackgrounds(for: starRail))
    }

    func testDisablingOneBackgroundRetentionCancelsOnlyItsOwnTask() async throws {
        let baseURL = try makeTemporaryDirectory()
        let supportURL = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: baseURL)
            try? FileManager.default.removeItem(at: supportURL)
        }
        let cache = MediaCacheManager(baseURL: supportURL)
        let genshin = GameType.genshinImpact.rawValue
        let starRail = GameType.honkaiStarRail.rawValue
        for gameID in [genshin, starRail] {
            try await seedBackgroundCache(cache: cache, gameID: gameID, groupID: "current")
        }
        let metadata = multiGameBackgroundResponse()
        let genshinProbe = BackgroundRetentionRequestProbe()
        let starRailProbe = BackgroundRetentionRequestProbe()
        MockURLProtocol.configure { request in
            switch request.url?.lastPathComponent {
            case "getAllGameBasicInfo": return .init(data: metadata)
            case "genshin-other.webp":
                genshinProbe.record()
                return .init(data: Data("genshin retained".utf8), delay: 1.5)
            case "star-other.webp":
                starRailProbe.record()
                return .init(data: Data("star retained".utf8), delay: 1.5)
            default: return .init(data: Data("media fixture".utf8))
            }
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let store = PersistenceStore(baseURL: baseURL)
        try await store.writeAppData(AppData(backgroundModes: [
            genshin: BackgroundMediaService.BackgroundMode.static.rawValue,
            starRail: BackgroundMediaService.BackgroundMode.static.rawValue
        ]))
        let defaults = makeBackgroundDefaults(retainOutdated: true)
        let service = try makeBackgroundService(cacheBase: supportURL, store: store,
            network: NetworkDownloadProvider(session: URLSession(configuration: config)), userDefaults: defaults)
        await service.loadSettings()
        await service.loadMedia(for: genshin)
        await service.loadMedia(for: starRail)
        for _ in 0..<150 {
            if genshinProbe.hasRequest && starRailProbe.hasRequest { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(genshinProbe.hasRequest)
        XCTAssertTrue(starRailProbe.hasRequest)
        let oldGenshinTask = try XCTUnwrap(service.backgroundRetentionTasks[genshin])
        XCTAssertNotNil(service.backgroundRetentionTasks[starRail])

        let genshinKey = BackgroundMediaService.retentionPreferenceKey(forGameID: genshin)
        defaults.set(false, forKey: genshinKey)
        service.retentionSettingDidChange(forGameID: genshin)
        XCTAssertNotNil(service.backgroundRetentionTasks[starRail], "Another game's download must not be cancelled")
        defaults.set(true, forKey: genshinKey)
        service.retentionSettingDidChange(forGameID: genshin)
        XCTAssertNotNil(service.backgroundRetentionTasks[genshin])
        await oldGenshinTask.value
        XCTAssertNotNil(service.backgroundRetentionTasks[genshin], "Canceled work must not unregister its replacement")
        await service.waitForRetainedBackgrounds(for: genshin)
        await service.waitForRetainedBackgrounds(for: starRail)
        let genshinOther = await cache.cachedFileURL(forKey: "background.webp", inDirectory: "\(genshin)/other")
        let starRailOther = await cache.cachedFileURL(forKey: "background.webp", inDirectory: "\(starRail)/other")
        XCTAssertEqual(try Data(contentsOf: genshinOther), Data("genshin retained".utf8))
        XCTAssertEqual(try Data(contentsOf: starRailOther), Data("star retained".utf8))
    }

    private func multiGameBackgroundResponse() -> Data {
        Data("""
        {"retcode":0,"message":"OK","data":{"game_info_list":[
          {"game":{"id":"hk4e","biz":"hk4e_cn"},"backgrounds":[
            {"id":"current","type":"BACKGROUND_TYPE_STATIC","background":{"url":"https://example.com/genshin-current.webp"}},
            {"id":"other","type":"BACKGROUND_TYPE_STATIC","background":{"url":"https://example.com/genshin-other.webp"}}
          ]},
          {"game":{"id":"hkrpg","biz":"hkrpg_cn"},"backgrounds":[
            {"id":"current","type":"BACKGROUND_TYPE_STATIC","background":{"url":"https://example.com/star-current.webp"}},
            {"id":"other","type":"BACKGROUND_TYPE_STATIC","background":{"url":"https://example.com/star-other.webp"}}
          ]}
        ]}}
        """.utf8)
    }

    /// The retention option saves every resource in every API group, while
    /// presentation remains tied to the first group with a video URL.
    func testBackgroundRetentionCachesAllGroupsWithoutChangingPresentedGroup() async throws {
        for mode in [BackgroundMediaService.BackgroundMode.dynamic, .static] {
            let baseURL = try makeTemporaryDirectory()
            let supportURL = try makeTemporaryDirectory()
            defer {
                try? FileManager.default.removeItem(at: baseURL)
                try? FileManager.default.removeItem(at: supportURL)
            }
            let cache = MediaCacheManager(baseURL: supportURL)
            let gameID = GameType.genshinImpact.rawValue
            try await seedBackgroundCache(cache: cache, gameID: gameID, groupID: "bg-video", includeVideo: true)
            let selectedTheme = await cache.cachedFileURL(forKey: "theme.png", inDirectory: "\(gameID)/bg-video")
            try Data("selected theme".utf8).write(to: selectedTheme)
            let store = PersistenceStore(baseURL: baseURL)
            try await store.writeAppData(AppData(backgroundModes: [gameID: mode.rawValue]))
            let metadata = richBackgroundResponse()
            let service = try makeBackgroundService(
                cacheBase: supportURL,
                store: store,
                network: makeBackgroundDownloadNetwork(metadata: metadata),
                userDefaults: makeBackgroundDefaults(retainOutdated: true)
            )
            await service.loadSettings()

            await service.loadMedia(for: gameID)
            await service.waitForRetainedBackgrounds(for: gameID)

            guard case .ready(let path, let isVideo) = service.getMediaState(for: gameID) else {
                return XCTFail("Selected background should remain ready in \(mode)")
            }
            XCTAssertEqual(isVideo, mode == .dynamic)
            XCTAssertTrue(path.hasSuffix(mode == .dynamic ? "/bg-video/video.mp4" : "/bg-video/background.png"))
            XCTAssertEqual(service.getThemeImagePath(for: gameID), selectedTheme.path,
                           "Caching a different group's theme must not replace the displayed theme")
            for (group, files) in [
                "bg-still": ["background.webp", "theme.webp", "icon.webp", "icon-hover.webp"],
                "bg-video": ["background.webp", "video.webm", "theme.webp"],
                "bg-other": ["background.webp", "video.webm"]
            ] {
                for file in files {
                    let cached = await cache.cachedFileURL(forKey: file, inDirectory: "\(gameID)/\(group)")
                    XCTAssertEqual(try Data(contentsOf: cached), Data("media fixture".utf8),
                                   "Missing API asset \(group)/\(file) in \(mode) mode")
                }
            }
        }
    }

    func testBackgroundRetentionDisabledDoesNotFetchOtherGroups() async throws {
        let baseURL = try makeTemporaryDirectory()
        let supportURL = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: baseURL)
            try? FileManager.default.removeItem(at: supportURL)
        }
        let cache = MediaCacheManager(baseURL: supportURL)
        let gameID = GameType.genshinImpact.rawValue
        try await seedBackgroundCache(cache: cache, gameID: gameID, groupID: "bg-video", includeVideo: true)
        let store = PersistenceStore(baseURL: baseURL)
        try await store.writeAppData(AppData())
        let service = try makeBackgroundService(
            cacheBase: supportURL, store: store,
            network: makeBackgroundDownloadNetwork(metadata: richBackgroundResponse()),
            userDefaults: makeBackgroundDefaults(retainOutdated: false)
        )

        await service.loadMedia(for: gameID)
        await service.waitForRetainedBackgrounds(for: gameID)

        guard case .ready(let path, let isVideo) = service.getMediaState(for: gameID) else {
            return XCTFail("Expected selected video to remain available")
        }
        XCTAssertTrue(isVideo)
        XCTAssertTrue(path.hasSuffix("/bg-video/video.mp4"))
        let still = await cache.cachedFileURL(forKey: "background.webp", inDirectory: "\(gameID)/bg-still")
        let other = await cache.cachedFileURL(forKey: "video.webm", inDirectory: "\(gameID)/bg-other")
        XCTAssertFalse(FileManager.default.fileExists(atPath: still.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: other.path))
    }

    func testBackgroundRetentionRunsInBackgroundAndCanBeStoppedAndRetried() async throws {
        let baseURL = try makeTemporaryDirectory()
        let supportURL = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: baseURL)
            try? FileManager.default.removeItem(at: supportURL)
        }
        let cache = MediaCacheManager(baseURL: supportURL)
        let gameID = GameType.genshinImpact.rawValue
        try await seedBackgroundCache(cache: cache, gameID: gameID, groupID: "bg-video", includeVideo: true)
        let metadata = richBackgroundResponse()
        let probe = BackgroundRetentionRequestProbe()
        MockURLProtocol.configure { request in
            if request.url?.lastPathComponent == "getAllGameBasicInfo" { return .init(data: metadata) }
            if request.url?.lastPathComponent == "still.webp" {
                probe.record()
                return .init(data: Data("late fixture".utf8), delay: 1)
            }
            return .init(data: Data("media fixture".utf8))
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let store = PersistenceStore(baseURL: baseURL)
        try await store.writeAppData(AppData())
        let defaults = makeBackgroundDefaults(retainOutdated: true)
        let service = try makeBackgroundService(cacheBase: supportURL, store: store,
            network: NetworkDownloadProvider(session: URLSession(configuration: config)), userDefaults: defaults)
        let settings = try await backgroundSettingsViewModel(service: service, store: store, supportURL: supportURL)

        await service.loadMedia(for: gameID)

        guard case .ready(let path, let isVideo) = service.getMediaState(for: gameID) else {
            return XCTFail("Selected media should be ready before optional downloads complete")
        }
        XCTAssertTrue(isVideo)
        XCTAssertTrue(path.hasSuffix("/bg-video/video.mp4"))
        let still = await cache.cachedFileURL(forKey: "background.webp", inDirectory: "\(gameID)/bg-still")
        XCTAssertFalse(FileManager.default.fileExists(atPath: still.path),
                       "Slow nonselected downloads must not delay loadMedia completion")
        for _ in 0..<100 {
            if probe.hasRequest { break }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTAssertTrue(probe.hasRequest, "Expected the optional download to start")
        let inFlight = service.backgroundRetentionTasks[gameID]
        XCTAssertNotNil(inFlight)
        defaults.set(false, forKey: BackgroundMediaService.retainOutdatedBackgroundsKey)
        settings.backgroundRetentionSettingDidChange()
        defaults.set(true, forKey: BackgroundMediaService.retainOutdatedBackgroundsKey)
        settings.backgroundRetentionSettingDidChange()
        XCTAssertNotNil(service.backgroundRetentionTasks[gameID], "Re-enabling must schedule a replacement task")
        await inFlight?.value
        XCTAssertFalse(FileManager.default.fileExists(atPath: still.path),
                       "Disabling retention must not publish the canceled download")
        XCTAssertNotNil(service.backgroundRetentionTasks[gameID],
                        "Completion of a canceled task must not remove its replacement")
        await service.waitForRetainedBackgrounds(for: gameID)
        XCTAssertEqual(try Data(contentsOf: still), Data("late fixture".utf8),
                       "Enabling retention again must retry the unfinished asset")
        guard case .ready(let after, _) = service.getMediaState(for: gameID) else {
            return XCTFail("Optional caching must not interrupt the selected background")
        }
        XCTAssertEqual(after, path)
    }

    func testEnablingBackgroundRetentionAfterLoadStartsCachingOtherGroups() async throws {
        let baseURL = try makeTemporaryDirectory()
        let supportURL = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: baseURL)
            try? FileManager.default.removeItem(at: supportURL)
        }
        let cache = MediaCacheManager(baseURL: supportURL)
        let gameID = GameType.genshinImpact.rawValue
        try await seedBackgroundCache(cache: cache, gameID: gameID, groupID: "bg-video", includeVideo: true)
        let store = PersistenceStore(baseURL: baseURL)
        try await store.writeAppData(AppData())
        let defaults = makeBackgroundDefaults(retainOutdated: false)
        let service = try makeBackgroundService(cacheBase: supportURL, store: store,
            network: makeBackgroundDownloadNetwork(metadata: richBackgroundResponse()), userDefaults: defaults)
        let settings = try await backgroundSettingsViewModel(service: service, store: store, supportURL: supportURL)

        await service.loadMedia(for: gameID)

        let still = await cache.cachedFileURL(forKey: "background.webp", inDirectory: "\(gameID)/bg-still")
        XCTAssertFalse(FileManager.default.fileExists(atPath: still.path))
        defaults.set(true, forKey: BackgroundMediaService.retainOutdatedBackgroundsKey)
        settings.backgroundRetentionSettingDidChange()
        await service.waitForRetainedBackgrounds(for: gameID)
        XCTAssertEqual(try Data(contentsOf: still), Data("media fixture".utf8))
        guard case .ready(let path, let isVideo) = service.getMediaState(for: gameID) else {
            return XCTFail("The previously selected background must stay visible")
        }
        XCTAssertTrue(isVideo)
        XCTAssertTrue(path.hasSuffix("/bg-video/video.mp4"))
    }

    func testBackgroundRetentionRetriesFailedOtherGroupWithoutHidingSelectedMedia() async throws {
        let baseURL = try makeTemporaryDirectory()
        let supportURL = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: baseURL)
            try? FileManager.default.removeItem(at: supportURL)
        }
        let cache = MediaCacheManager(baseURL: supportURL)
        let gameID = GameType.genshinImpact.rawValue
        try await seedBackgroundCache(cache: cache, gameID: gameID, groupID: "bg-video", includeVideo: true)
        let metadata = richBackgroundResponse()
        MockURLProtocol.configure { request in
            if request.url?.lastPathComponent == "getAllGameBasicInfo" { return .init(data: metadata) }
            if request.url?.lastPathComponent == "still.webp" { return .init(data: Data(), statusCode: 503) }
            return .init(data: Data("media fixture".utf8))
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [MockURLProtocol.self]
        let store = PersistenceStore(baseURL: baseURL)
        try await store.writeAppData(AppData())
        let service = try makeBackgroundService(
            cacheBase: supportURL, store: store,
            network: NetworkDownloadProvider(session: URLSession(configuration: config)),
            userDefaults: makeBackgroundDefaults(retainOutdated: true)
        )

        await service.loadMedia(for: gameID)
        await service.waitForRetainedBackgrounds(for: gameID)

        guard case .ready(let selectedPath, let isVideo) = service.getMediaState(for: gameID) else {
            return XCTFail("A nonselected asset failure must not hide the current background")
        }
        XCTAssertTrue(isVideo)
        XCTAssertTrue(selectedPath.hasSuffix("/bg-video/video.mp4"))
        let failed = await cache.cachedFileURL(forKey: "background.webp", inDirectory: "\(gameID)/bg-still")
        XCTAssertFalse(FileManager.default.fileExists(atPath: failed.path))
        let successful = await cache.cachedFileURL(forKey: "video.webm", inDirectory: "\(gameID)/bg-other")
        XCTAssertTrue(FileManager.default.fileExists(atPath: successful.path))

        MockURLProtocol.configure { request in
            if request.url?.lastPathComponent == "getAllGameBasicInfo" { return .init(data: metadata) }
            return .init(data: Data("recovered fixture".utf8))
        }
        await service.loadMedia(for: gameID)
        await service.waitForRetainedBackgrounds(for: gameID)
        XCTAssertEqual(try Data(contentsOf: failed), Data("recovered fixture".utf8))
        XCTAssertEqual(try Data(contentsOf: successful), Data("media fixture".utf8),
                       "Retry should keep assets that already succeeded")
        guard case .ready(let after, _) = service.getMediaState(for: gameID) else {
            return XCTFail("Selected background should still be ready after retry")
        }
        XCTAssertEqual(after, selectedPath)
    }

    func testBackgroundRetentionArchivesAllAssetsWhenNonselectedURLChanges() async throws {
        let baseURL = try makeTemporaryDirectory()
        let supportURL = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: baseURL)
            try? FileManager.default.removeItem(at: supportURL)
        }
        let cache = MediaCacheManager(baseURL: supportURL)
        let gameID = GameType.genshinImpact.rawValue
        try await seedBackgroundCache(cache: cache, gameID: gameID, groupID: "bg-video", includeVideo: true)
        let store = PersistenceStore(baseURL: baseURL)
        try await store.writeAppData(AppData())
        let service = try makeBackgroundService(
            cacheBase: supportURL, store: store,
            network: makeBackgroundDownloadNetwork(metadata: richBackgroundResponse()),
            userDefaults: makeBackgroundDefaults(retainOutdated: true)
        )
        await service.loadMedia(for: gameID)
        await service.waitForRetainedBackgrounds(for: gameID)

        let newMetadata = richBackgroundResponse(stillURL: "https://example.com/still-v2.webp")
        MockURLProtocol.configure { request in
            if request.url?.lastPathComponent == "getAllGameBasicInfo" { return .init(data: newMetadata) }
            return .init(data: Data("new media fixture".utf8))
        }
        await service.refreshCache(for: gameID)
        await service.waitForRetainedBackgrounds(for: gameID)

        let refreshed = await cache.cachedFileURL(forKey: "background.webp", inDirectory: "\(gameID)/bg-still")
        XCTAssertEqual(try Data(contentsOf: refreshed), Data("new media fixture".utf8))
        let archive = await cache.cacheMetadataURL(forGameId: gameID, filename: ".archive")
        let archived = FileManager.default.enumerator(at: archive, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []
        XCTAssertTrue(archived.contains { $0.lastPathComponent == "background.webp" && (try? Data(contentsOf: $0)) == Data("media fixture".utf8) },
                      "The prior raw resource must remain archived after its URL changes")
        guard case .ready(let path, let isVideo) = service.getMediaState(for: gameID) else {
            return XCTFail("The selected background must remain available")
        }
        XCTAssertTrue(isVideo)
        XCTAssertTrue(path.hasSuffix("/bg-video/video.mp4"))
    }

    func testBackgroundRetentionMigratesLegacyFingerprintAndArchivesIconChange() async throws {
        let baseURL = try makeTemporaryDirectory()
        let supportURL = try makeTemporaryDirectory()
        defer {
            try? FileManager.default.removeItem(at: baseURL)
            try? FileManager.default.removeItem(at: supportURL)
        }
        let cache = MediaCacheManager(baseURL: supportURL)
        let gameID = GameType.genshinImpact.rawValue
        try await seedBackgroundCache(cache: cache, gameID: gameID, groupID: "bg-still")
        try await seedBackgroundCache(cache: cache, gameID: gameID, groupID: "bg-video", includeVideo: true)
        let legacy = Data("""
        {"sourceID":"hoyoPlay","groups":[{"groupID":"bg-still","type":"BACKGROUND_TYPE_STATIC","version":"bg-still","backgroundIdentity":"https://example.com/still.webp","themeIdentity":"https://example.com/still-theme.webp"}]}
        """.utf8)
        try await cache.writeCacheMetadata(legacy, forGameId: gameID, filename: ".background-fingerprint.json")
        let store = PersistenceStore(baseURL: baseURL)
        try await store.writeAppData(AppData())
        let service = try makeBackgroundService(
            cacheBase: supportURL, store: store,
            network: makeBackgroundDownloadNetwork(metadata: richBackgroundResponse()),
            userDefaults: makeBackgroundDefaults(retainOutdated: true)
        )

        await service.loadMedia(for: gameID)
        await service.waitForRetainedBackgrounds(for: gameID)

        let stillPNG = await cache.cachedFileURL(forKey: "background.png", inDirectory: "\(gameID)/bg-still")
        XCTAssertEqual(try Data(contentsOf: stillPNG), Data("background fixture".utf8),
                       "Adding optional icon metadata must not archive an otherwise unchanged legacy group")
        let icon = await cache.cachedFileURL(forKey: "icon.webp", inDirectory: "\(gameID)/bg-still")
        XCTAssertEqual(try Data(contentsOf: icon), Data("media fixture".utf8))

        let newMetadata = richBackgroundResponse(iconURL: "https://example.com/still-icon-v2.webp")
        MockURLProtocol.configure { request in
            if request.url?.lastPathComponent == "getAllGameBasicInfo" { return .init(data: newMetadata) }
            return .init(data: Data("updated icon fixture".utf8))
        }
        await service.refreshCache(for: gameID)
        await service.waitForRetainedBackgrounds(for: gameID)

        XCTAssertEqual(try Data(contentsOf: icon), Data("updated icon fixture".utf8))
        let archive = await cache.cacheMetadataURL(forGameId: gameID, filename: ".archive")
        let archived = FileManager.default.enumerator(at: archive, includingPropertiesForKeys: nil)?.allObjects as? [URL] ?? []
        XCTAssertTrue(archived.contains { $0.lastPathComponent == "icon.webp" && (try? Data(contentsOf: $0)) == Data("media fixture".utf8) },
                      "Changing only the icon URL must preserve the previous icon in history")
    }

    private func backgroundSettingsViewModel(service: BackgroundMediaService, store: PersistenceStore,
                                             supportURL: URL) async throws -> SettingsViewModel {
        let fixture = try await makeScheduler(store: store)
        return SettingsViewModel(
            systemDetector: SystemEnvironmentDetector(), wineVersionManager: fixture.wineManager,
            gameRegistry: fixture.registry, fileSystemRepository: GameFileSystemRepository(appSupportDirectory: supportURL),
            taskScheduler: fixture.scheduler,
            performanceOptionManager: PerformanceOptionManager(persistenceStore: store, logWriter: fixture.logger),
            backgroundMediaService: service
        )
    }

    private func richBackgroundResponse(stillURL: String = "https://example.com/still.webp",
                                        iconURL: String = "https://example.com/still-icon.webp") -> Data {
        Data("""
        {"retcode":0,"message":"OK","data":{"game_info_list":[{"game":{"id":"hk4e","biz":"hk4e_cn"},"backgrounds":[
          {"id":"bg-still","type":"BACKGROUND_TYPE_STATIC","background":{"url":"\(stillURL)"},"theme":{"url":"https://example.com/still-theme.webp"},"icon":{"url":"\(iconURL)","hover_url":"https://example.com/still-hover.webp"}},
          {"id":"bg-video","type":"BACKGROUND_TYPE_VIDEO","background":{"url":"https://example.com/video-bg.webp"},"video":{"url":"https://example.com/video.webm"},"theme":{"url":"https://example.com/video-theme.webp"}},
          {"id":"bg-other","type":"BACKGROUND_TYPE_VIDEO","background":{"url":"https://example.com/other.webp"},"video":{"url":"https://example.com/other.webm"}}
        ]}]}}
        """.utf8)
    }

    func testBackgroundPrefersVideoGroupOverCachedFirstStill() async throws {
        let baseURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: baseURL) }
        let supportURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: supportURL) }
        let cache = MediaCacheManager(baseURL: supportURL)
        let gameID = GameType.genshinImpact.rawValue
        try await seedBackgroundCache(cache: cache, gameID: gameID, groupID: "bg-still")
        try await seedBackgroundCache(
            cache: cache, gameID: gameID, groupID: "bg-video", includeVideo: true
        )

        let store = PersistenceStore(baseURL: baseURL)
        try await store.writeAppData(AppData())
        let service = try makeBackgroundService(
            cacheBase: supportURL,
            store: store,
            network: makeMockNetwork(response: Self.mixedBackgroundResponseJSON())
        )

        await service.loadMedia(for: gameID)

        guard case .ready(let path, let isVideo) = service.getMediaState(for: gameID) else {
            return XCTFail("Expected the video group to be ready")
        }
        XCTAssertTrue(isVideo)
        XCTAssertTrue(path.hasSuffix("/bg-video/video.mp4"))
        XCTAssertTrue(service.getBackgroundStillImagePath(for: gameID)?.hasSuffix("/bg-video/background.png") == true)
    }

    func testBackgroundWithoutVideoFallsBackToFirstGroup() async throws {
        let baseURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: baseURL) }
        let supportURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: supportURL) }
        let cache = MediaCacheManager(baseURL: supportURL)
        let gameID = GameType.genshinImpact.rawValue
        try await seedBackgroundCache(cache: cache, gameID: gameID, groupID: "bg-1")
        try await seedBackgroundCache(cache: cache, gameID: gameID, groupID: "bg-2")
        let store = PersistenceStore(baseURL: baseURL)
        try await store.writeAppData(AppData())
        let service = try makeBackgroundService(
            cacheBase: supportURL,
            store: store,
            network: makeMockNetwork(response: Self.backgroundResponseJSON())
        )

        await service.loadMedia(for: gameID)

        guard case .ready(let path, let isVideo) = service.getMediaState(for: gameID) else {
            return XCTFail("Expected the first still-image group to be ready")
        }
        XCTAssertFalse(isVideo)
        XCTAssertTrue(path.hasSuffix("/bg-1/background.png"))
    }

    func testBackgroundUsesFirstNonemptyVideoURLRegardlessOfType() async throws {
        let baseURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: baseURL) }
        let supportURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: supportURL) }
        let cache = MediaCacheManager(baseURL: supportURL)
        let gameID = GameType.genshinImpact.rawValue
        try await seedBackgroundCache(cache: cache, gameID: gameID, groupID: "bg-empty-video")
        for groupID in ["bg-first-video", "bg-second-video"] {
            try await seedBackgroundCache(
                cache: cache, gameID: gameID, groupID: groupID, includeVideo: true
            )
        }
        let response = Self.backgroundResponseJSON(
            groupIDs: ["bg-empty-video", "bg-first-video", "bg-second-video"],
            videoURLs: [
                "bg-empty-video": "",
                "bg-first-video": "https://example.com/bg-first-video.webm",
                "bg-second-video": "https://example.com/bg-second-video.webm",
            ],
            types: ["bg-first-video": "BACKGROUND_TYPE_STATIC"]
        )
        let store = PersistenceStore(baseURL: baseURL)
        try await store.writeAppData(AppData())
        let service = try makeBackgroundService(
            cacheBase: supportURL, store: store, network: makeMockNetwork(response: response)
        )

        await service.loadMedia(for: gameID)

        guard case .ready(let path, let isVideo) = service.getMediaState(for: gameID) else {
            return XCTFail("Expected the first group with a nonempty video URL")
        }
        XCTAssertTrue(isVideo)
        XCTAssertTrue(path.hasSuffix("/bg-first-video/video.mp4"))
        XCTAssertNil(service.resolveCurrentBackground(from: []))
    }

    func testStaticBackgroundUsesPreferredVideoGroupsStillImage() async throws {
        let baseURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: baseURL) }
        let supportURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: supportURL) }
        let cache = MediaCacheManager(baseURL: supportURL)
        let gameID = GameType.genshinImpact.rawValue
        try await seedBackgroundCache(cache: cache, gameID: gameID, groupID: "bg-still")
        try await seedBackgroundCache(
            cache: cache, gameID: gameID, groupID: "bg-video", includeVideo: true
        )
        let store = PersistenceStore(baseURL: baseURL)
        try await store.writeAppData(AppData(
            backgroundModes: [gameID: BackgroundMediaService.BackgroundMode.static.rawValue]
        ))
        let service = try makeBackgroundService(
            cacheBase: supportURL,
            store: store,
            network: makeMockNetwork(response: Self.mixedBackgroundResponseJSON())
        )
        await service.loadSettings()

        await service.loadMedia(for: gameID)

        guard case .ready(let path, let isVideo) = service.getMediaState(for: gameID) else {
            return XCTFail("Expected the preferred video group's still image")
        }
        XCTAssertFalse(isVideo, "Static mode must remain static when the group's MP4 is cached")
        XCTAssertTrue(path.hasSuffix("/bg-video/background.png"))
        XCTAssertEqual(service.getBackgroundStillImagePath(for: gameID), path)
    }

    func testBackgroundDownloadsPreferredVideoWhenOnlyFirstStillIsCached() async throws {
        let baseURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: baseURL) }
        let supportURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: supportURL) }
        let cache = MediaCacheManager(baseURL: supportURL)
        let gameID = GameType.genshinImpact.rawValue
        try await seedBackgroundCache(cache: cache, gameID: gameID, groupID: "bg-still")
        // Deliberately inconsistent type: the actual video URL determines priority
        // and must also reach the video download path when no MP4 is cached.
        let response = Self.backgroundResponseJSON(
            groupIDs: ["bg-still", "bg-video"],
            videoURLs: ["bg-video": "https://example.com/bg-video.webm"],
            types: ["bg-video": "BACKGROUND_TYPE_STATIC"]
        )
        MockURLProtocol.configure { request in
            switch request.url?.lastPathComponent {
            case "getAllGameBasicInfo": return .init(data: response)
            case "bg-video.webp", "bg-video.webm": return .init(data: Data("media fixture".utf8))
            default: return .init(data: Data(), statusCode: 404)
            }
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let store = PersistenceStore(baseURL: baseURL)
        try await store.writeAppData(AppData())
        let service = try makeBackgroundService(
            cacheBase: supportURL,
            store: store,
            network: NetworkDownloadProvider(session: URLSession(configuration: configuration)),
            ffmpegPath: makeStubFFmpeg(in: baseURL, exitCode: 0).path
        )

        await service.loadMedia(for: gameID)

        guard case .ready(let path, let isVideo) = service.getMediaState(for: gameID) else {
            return XCTFail("Expected the uncached preferred video to be downloaded and transcoded")
        }
        XCTAssertTrue(isVideo)
        XCTAssertTrue(path.hasSuffix("/bg-video/video.mp4"))
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "stub-transcode")
        let stillPath = try XCTUnwrap(service.getBackgroundStillImagePath(for: gameID))
        XCTAssertTrue(stillPath.hasSuffix("/bg-video/background.png"))
        XCTAssertEqual(try String(contentsOfFile: stillPath, encoding: .utf8), "stub-transcode")
    }

    func testBackgroundCachePrunesRemovedGroupsWhenRetentionDisabled() async throws {
        let baseURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: baseURL) }
        let supportURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: supportURL) }
        let cache = MediaCacheManager(baseURL: supportURL)
        let gameID = GameType.genshinImpact.rawValue
        try await seedBackgroundCache(cache: cache, gameID: gameID, groupID: "bg-1")
        try await seedBackgroundCache(cache: cache, gameID: gameID, groupID: "bg-2")
        try await writeFingerprint(
            cache: cache,
            gameID: gameID,
            groupIDs: ["bg-1"]
        )

        let store = PersistenceStore(baseURL: baseURL)
        try await store.writeAppData(AppData())
        let service = try makeBackgroundService(
            cacheBase: supportURL,
            store: store,
            network: makeMockNetwork(response: Self.backgroundResponseJSON(groupIDs: ["bg-2"])),
            userDefaults: makeBackgroundDefaults(retainOutdated: false)
        )

        await service.loadMedia(for: gameID)

        let groups = try await cache.groupDirectoryNames(forGameId: gameID)
        XCTAssertEqual(groups, ["bg-2"])
        let persisted = try await cache.readCacheMetadata(
            forGameId: gameID,
            filename: ".background-fingerprint.json"
        )
        XCTAssertNotNil(persisted)
    }

    func testBackgroundCachePrunesChangedResourcesWhenRetentionDisabled() async throws {
        let baseURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: baseURL) }
        let supportURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: supportURL) }
        let cache = MediaCacheManager(baseURL: supportURL)
        let gameID = GameType.genshinImpact.rawValue
        let backgroundFile = await cache.cachedFileURL(
            forKey: "background.png",
            inDirectory: "\(gameID)/bg-1"
        )
        try Data("old cached resource".utf8).write(to: backgroundFile)
        try await writeFingerprint(
            cache: cache,
            gameID: gameID,
            groupIDs: ["bg-1"],
            resourceURLs: ["bg-1": "https://example.com/bg-1-old.webp"]
        )

        let store = PersistenceStore(baseURL: baseURL)
        try await store.writeAppData(AppData(
            backgroundModes: [gameID: BackgroundMediaService.BackgroundMode.static.rawValue]
        ))
        let service = try makeBackgroundService(
            cacheBase: supportURL,
            store: store,
            network: makeMockNetwork(
                response: Self.backgroundResponseJSON(
                    groupIDs: ["bg-1"],
                    resourceURLs: ["bg-1": "https://example.com/bg-1-new.webp"]
                )
            ),
            userDefaults: makeBackgroundDefaults(retainOutdated: false)
        )
        await service.loadSettings()
        await service.loadMedia(for: gameID)

        XCTAssertFalse(FileManager.default.fileExists(atPath: backgroundFile.path))
        let fingerprint = await service.loadPersistedCollectionFingerprint(for: gameID)
        XCTAssertEqual(
            fingerprint?.groups.first?.backgroundIdentity,
            "https://example.com/bg-1-new.webp"
        )
    }

    func testRefreshMetadataDoesNotDeleteDiagnosticCachedGroup() async throws {
        let baseURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: baseURL) }
        let supportURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: supportURL) }
        let cache = MediaCacheManager(baseURL: supportURL)
        let gameID = GameType.genshinImpact.rawValue
        let backgroundFile = await cache.cachedFileURL(
            forKey: "background.png",
            inDirectory: "\(gameID)/bg-1"
        )
        try Data("cached resource".utf8).write(to: backgroundFile)

        let store = PersistenceStore(baseURL: baseURL)
        try await store.writeAppData(AppData(
            backgroundModes: [gameID: BackgroundMediaService.BackgroundMode.static.rawValue],
            lastCachedBackgroundIds: [gameID: "bg-1"]
        ))
        let service = try makeBackgroundService(
            cacheBase: supportURL,
            store: store,
            network: makeMockNetwork(response: Self.backgroundResponseJSON(groupIDs: ["bg-1"]))
        )
        await service.loadSettings()
        await service.refreshCache(for: gameID)

        XCTAssertTrue(FileManager.default.fileExists(atPath: backgroundFile.path))
        guard case .ready(let localPath, let isVideo) = service.getMediaState(for: gameID) else {
            return XCTFail("Expected cached static background to remain ready")
        }
        XCTAssertEqual(localPath, backgroundFile.path)
        XCTAssertFalse(isVideo)
    }

    func testMissingBackgroundFingerprintNeverPrunesCaches() async throws {
        let baseURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: baseURL) }
        let supportURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: supportURL) }
        let cache = MediaCacheManager(baseURL: supportURL)
        let gameID = GameType.genshinImpact.rawValue
        try await seedBackgroundCache(cache: cache, gameID: gameID, groupID: "bg-1")
        try await seedBackgroundCache(cache: cache, gameID: gameID, groupID: "bg-obsolete")

        let store = PersistenceStore(baseURL: baseURL)
        try await store.writeAppData(AppData())
        let service = try makeBackgroundService(
            cacheBase: supportURL,
            store: store,
            network: makeMockNetwork(response: Self.backgroundResponseJSON(groupIDs: ["bg-1"])),
            userDefaults: makeBackgroundDefaults(retainOutdated: false)
        )

        await service.loadMedia(for: gameID)

        let groups = try await cache.groupDirectoryNames(forGameId: gameID)
        XCTAssertEqual(Set(groups), ["bg-1", "bg-obsolete"])
    }

    func testBackgroundRetentionDefaultsToOffAndHonorsSavedPreferences() throws {
        let baseURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: baseURL) }
        let defaults = makeBackgroundDefaults()
        let key = BackgroundMediaService.retainOutdatedBackgroundsKey
        let service = try makeBackgroundService(
            cacheBase: baseURL,
            store: PersistenceStore(baseURL: baseURL),
            network: makeMockNetwork(response: Data()),
            userDefaults: defaults
        )

        XCTAssertNil(defaults.object(forKey: key))
        XCTAssertFalse(BackgroundMediaService.retainOutdatedBackgroundsDefault)
        XCTAssertFalse(service.retainOutdatedBackgrounds)
        XCTAssertNil(defaults.object(forKey: key), "Reading the default must not overwrite a preference")

        defaults.set(true, forKey: key)
        XCTAssertTrue(service.retainOutdatedBackgrounds, "Previously enabled settings must remain enabled")
        defaults.set(false, forKey: key)
        XCTAssertFalse(service.retainOutdatedBackgrounds, "Explicitly disabled settings must remain disabled")
    }

    func testBackgroundCacheRetainsRemovedGroupsWhenEnabled() async throws {
        let baseURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: baseURL) }
        let supportURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: supportURL) }
        let cache = MediaCacheManager(baseURL: supportURL)
        let gameID = GameType.genshinImpact.rawValue
        for groupID in ["bg-old", "bg-current"] {
            try await seedBackgroundCache(cache: cache, gameID: gameID, groupID: groupID)
        }
        try await writeFingerprint(cache: cache, gameID: gameID, groupIDs: ["bg-old"])
        let store = PersistenceStore(baseURL: baseURL)
        try await store.writeAppData(AppData())
        let defaults = makeBackgroundDefaults(retainOutdated: true)
        let service = try makeBackgroundService(
            cacheBase: supportURL,
            store: store,
            network: makeMockNetwork(response: Self.backgroundResponseJSON(groupIDs: ["bg-current"])),
            userDefaults: defaults
        )
        XCTAssertEqual(defaults.object(forKey: BackgroundMediaService.retainOutdatedBackgroundsKey) as? Bool, true)
        XCTAssertTrue(service.retainOutdatedBackgrounds)

        await service.loadMedia(for: gameID)

        let groups = try await cache.groupDirectoryNames(forGameId: gameID)
        XCTAssertEqual(Set(groups), ["bg-old", "bg-current"])
        let oldFile = await cache.cachedFileURL(forKey: "background.png", inDirectory: "\(gameID)/bg-old")
        XCTAssertEqual(try String(contentsOf: oldFile, encoding: .utf8), "background fixture")
        guard case .ready(let path, _) = service.getMediaState(for: gameID) else {
            return XCTFail("Expected the current group to remain usable while old files are retained")
        }
        XCTAssertTrue(path.hasSuffix("/bg-current/background.png"))
    }

    func testBackgroundCacheArchivesReplacedResourcesAndLoadsFreshFiles() async throws {
        let baseURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: baseURL) }
        let supportURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: supportURL) }
        let cache = MediaCacheManager(baseURL: supportURL)
        let gameID = GameType.genshinImpact.rawValue
        try await seedBackgroundCache(cache: cache, gameID: gameID, groupID: "bg-1")
        let oldResource = "https://example.com/bg-1-old.webp"
        let newResource = "https://example.com/bg-1-new.webp"
        try await writeFingerprint(
            cache: cache, gameID: gameID, groupIDs: ["bg-1"], resourceURLs: ["bg-1": oldResource]
        )
        let store = PersistenceStore(baseURL: baseURL)
        try await store.writeAppData(AppData())
        let service = try makeBackgroundService(
            cacheBase: supportURL,
            store: store,
            network: makeBackgroundDownloadNetwork(metadata: Self.backgroundResponseJSON(
                groupIDs: ["bg-1"], resourceURLs: ["bg-1": newResource]
            )),
            ffmpegPath: makeStubFFmpeg(in: baseURL, exitCode: 0).path,
            userDefaults: makeBackgroundDefaults(retainOutdated: true)
        )

        await service.loadMedia(for: gameID)

        let archivedFiles = await archivedBackgroundURLs(cache: cache, gameID: gameID)
        let archived = try XCTUnwrap(archivedFiles.first)
        XCTAssertEqual(archivedFiles.count, 1)
        XCTAssertEqual(try String(contentsOf: archived, encoding: .utf8), "background fixture")
        let archivedIdentity = try JSONDecoder().decode(
            BackgroundMediaService.BackgroundGroupFingerprint.self,
            from: Data(contentsOf: archived.deletingLastPathComponent().appendingPathComponent(".background-group.json"))
        )
        XCTAssertEqual(archivedIdentity.backgroundIdentity, oldResource)
        guard case .ready(let path, let isVideo) = service.getMediaState(for: gameID) else {
            return XCTFail("Expected updated resources to be loaded instead of reusing the archived files")
        }
        XCTAssertFalse(isVideo)
        XCTAssertTrue(path.hasSuffix("/bg-1/background.png"))
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "stub-transcode")
        let currentIdentity = await service.loadGroupFingerprint(for: gameID, backgroundId: "bg-1")
        XCTAssertEqual(currentIdentity?.backgroundIdentity, newResource)
        let groups = try await cache.groupDirectoryNames(forGameId: gameID)
        XCTAssertEqual(groups, ["bg-1"], "Archive directories must not be listed as active background groups")
    }

    func testBackgroundCacheDetectsChangedResourcesWhenRetainedGroupReappears() async throws {
        let baseURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: baseURL) }
        let supportURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: supportURL) }
        let cache = MediaCacheManager(baseURL: supportURL)
        let gameID = GameType.genshinImpact.rawValue
        for groupID in ["bg-returning", "bg-current"] {
            try await seedBackgroundCache(cache: cache, gameID: gameID, groupID: groupID)
        }
        let store = PersistenceStore(baseURL: baseURL)
        try await store.writeAppData(AppData())
        let original = try makeBackgroundService(
            cacheBase: supportURL,
            store: store,
            network: makeMockNetwork(response: Self.backgroundResponseJSON(groupIDs: ["bg-returning"])),
            userDefaults: makeBackgroundDefaults(retainOutdated: true)
        )
        await original.loadMedia(for: gameID)
        let absent = try makeBackgroundService(
            cacheBase: supportURL,
            store: store,
            network: makeMockNetwork(response: Self.backgroundResponseJSON(groupIDs: ["bg-current"])),
            userDefaults: makeBackgroundDefaults(retainOutdated: true)
        )
        await absent.loadMedia(for: gameID)
        let absentFingerprint = await absent.loadPersistedCollectionFingerprint(for: gameID)
        XCTAssertEqual(absentFingerprint?.groups.map(\.groupID), ["bg-current"])
        let updatedURL = "https://example.com/bg-returning-updated.webp"
        let returning = try makeBackgroundService(
            cacheBase: supportURL,
            store: store,
            network: makeBackgroundDownloadNetwork(metadata: Self.backgroundResponseJSON(
                groupIDs: ["bg-returning"], resourceURLs: ["bg-returning": updatedURL]
            )),
            ffmpegPath: makeStubFFmpeg(in: baseURL, exitCode: 0).path,
            userDefaults: makeBackgroundDefaults(retainOutdated: true)
        )

        await returning.loadMedia(for: gameID)

        let archivedFiles = await archivedBackgroundURLs(cache: cache, gameID: gameID)
        XCTAssertEqual(archivedFiles.count, 1)
        XCTAssertEqual(try String(contentsOf: XCTUnwrap(archivedFiles.first), encoding: .utf8), "background fixture")
        guard case .ready(let path, _) = returning.getMediaState(for: gameID) else {
            return XCTFail("Expected the returning group to load its updated resource")
        }
        XCTAssertTrue(path.hasSuffix("/bg-returning/background.png"))
        XCTAssertEqual(try String(contentsOfFile: path, encoding: .utf8), "stub-transcode")
    }

    func testDisablingBackgroundRetentionPersistsAndPrunesUnchangedCollection() async throws {
        let baseURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: baseURL) }
        let supportURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: supportURL) }
        let suiteName = "MiPlayBackgroundRetentionTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        defaults.set(true, forKey: BackgroundMediaService.retainOutdatedBackgroundsKey)
        let cache = MediaCacheManager(baseURL: supportURL)
        let gameID = GameType.genshinImpact.rawValue
        for groupID in ["bg-old", "bg-current", "bg-archived"] {
            try await seedBackgroundCache(cache: cache, gameID: gameID, groupID: groupID)
        }
        let archivedDirectory = try await cache.archiveCache(forGameId: gameID, backgroundId: "bg-archived")
        let archive = try XCTUnwrap(archivedDirectory)
        try await writeFingerprint(cache: cache, gameID: gameID, groupIDs: ["bg-old"])
        let store = PersistenceStore(baseURL: baseURL)
        try await store.writeAppData(AppData())
        let metadata = Self.backgroundResponseJSON(groupIDs: ["bg-current"])
        let retained = try makeBackgroundService(
            cacheBase: supportURL, store: store,
            network: makeMockNetwork(response: metadata), userDefaults: defaults
        )
        await retained.loadMedia(for: gameID)
        let oldFile = await cache.cachedFileURL(forKey: "background.png", inDirectory: "\(gameID)/bg-old")
        XCTAssertTrue(FileManager.default.fileExists(atPath: oldFile.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: archive.path))
        let before = await retained.loadPersistedCollectionFingerprint(for: gameID)
        defaults.set(false, forKey: BackgroundMediaService.retainOutdatedBackgroundsKey)
        let restarted = try makeBackgroundService(
            cacheBase: supportURL, store: store,
            network: makeMockNetwork(response: metadata),
            userDefaults: XCTUnwrap(UserDefaults(suiteName: suiteName))
        )
        XCTAssertFalse(restarted.retainOutdatedBackgrounds)

        await restarted.loadMedia(for: gameID)

        let after = await restarted.loadPersistedCollectionFingerprint(for: gameID)
        XCTAssertEqual(before, after, "Cleanup must also run when only the retention setting changed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldFile.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: archive.path))
        let groups = try await cache.groupDirectoryNames(forGameId: gameID)
        XCTAssertEqual(groups, ["bg-current"])
    }

    func testBackgroundArchiveFailurePreservesOldFilesAndFingerprint() async throws {
        let baseURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: baseURL) }
        let supportURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: supportURL) }
        let cache = MediaCacheManager(baseURL: supportURL)
        let gameID = GameType.genshinImpact.rawValue
        try await seedBackgroundCache(cache: cache, gameID: gameID, groupID: "bg-1")
        let oldResource = "https://example.com/bg-1-old.webp"
        try await writeFingerprint(
            cache: cache, gameID: gameID, groupIDs: ["bg-1"], resourceURLs: ["bg-1": oldResource]
        )
        let archiveRoot = await cache.cacheMetadataURL(forGameId: gameID, filename: ".archive")
        try Data("blocks archive directory creation".utf8).write(to: archiveRoot)
        let store = PersistenceStore(baseURL: baseURL)
        try await store.writeAppData(AppData())
        let service = try makeBackgroundService(
            cacheBase: supportURL,
            store: store,
            network: makeBackgroundDownloadNetwork(metadata: Self.backgroundResponseJSON(
                groupIDs: ["bg-1"], resourceURLs: ["bg-1": "https://example.com/bg-1-new.webp"]
            )),
            ffmpegPath: makeStubFFmpeg(in: baseURL, exitCode: 0).path,
            userDefaults: makeBackgroundDefaults(retainOutdated: true)
        )

        await service.loadMedia(for: gameID)

        guard case .failed = service.getMediaState(for: gameID) else {
            return XCTFail("Archive failure must stop the load before replacing old resources")
        }
        let oldFile = await cache.cachedFileURL(forKey: "background.png", inDirectory: "\(gameID)/bg-1")
        XCTAssertEqual(try String(contentsOf: oldFile, encoding: .utf8), "background fixture")
        let fingerprint = await service.loadPersistedCollectionFingerprint(for: gameID)
        XCTAssertEqual(fingerprint?.groups.first?.backgroundIdentity, oldResource)
    }

    func testBackgroundMetadataFailureStopsBeforeUnreconciledRetry() async throws {
        let baseURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: baseURL) }
        let supportURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: supportURL) }
        let cache = MediaCacheManager(baseURL: supportURL)
        let gameID = GameType.genshinImpact.rawValue
        try await seedBackgroundCache(cache: cache, gameID: gameID, groupID: "bg-1")
        try await writeFingerprint(
            cache: cache, gameID: gameID, groupIDs: ["bg-1"],
            resourceURLs: ["bg-1": "https://example.com/bg-1-old.webp"]
        )
        let firstRequest = baseURL.appendingPathComponent("first-request")
        let secondRequest = baseURL.appendingPathComponent("unexpected-second-request")
        let recoveredResponse = Self.backgroundResponseJSON(
            groupIDs: ["bg-1"], resourceURLs: ["bg-1": "https://example.com/bg-1-new.webp"]
        )
        MockURLProtocol.configure { _ in
            if FileManager.default.fileExists(atPath: firstRequest.path) {
                try? Data("requested".utf8).write(to: secondRequest)
                return .init(data: recoveredResponse)
            }
            try? Data("requested".utf8).write(to: firstRequest)
            return .init(data: Data(), statusCode: 500)
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        let store = PersistenceStore(baseURL: baseURL)
        try await store.writeAppData(AppData())
        let service = try makeBackgroundService(
            cacheBase: supportURL, store: store,
            network: NetworkDownloadProvider(session: URLSession(configuration: configuration))
        )
        let before = await service.loadPersistedCollectionFingerprint(for: gameID)

        await service.loadMedia(for: gameID)

        guard case .failed = service.getMediaState(for: gameID) else {
            return XCTFail("The failed metadata request must stop the load before another fetch bypasses reconciliation")
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: firstRequest.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: secondRequest.path))
        let oldFile = await cache.cachedFileURL(forKey: "background.png", inDirectory: "\(gameID)/bg-1")
        XCTAssertEqual(try String(contentsOf: oldFile, encoding: .utf8), "background fixture")
        let after = await service.loadPersistedCollectionFingerprint(for: gameID)
        XCTAssertEqual(after, before)
    }

    // MARK: - 转码原子性与缓存门槛

    func testTranscodeFailureLeavesNoPartialOutput() async throws {
        let baseURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: baseURL) }
        let stub = try makeStubFFmpeg(in: baseURL, exitCode: 1)
        let fileSystem = GameFileSystemRepository(appSupportDirectory: baseURL)
        let logger = LogWriter(fileSystemRepository: fileSystem)
        let transcoder = MediaTranscoder(
            processManager: ProcessManager(),
            logWriter: logger,
            ffmpegPath: stub.path
        )
        let inputURL = baseURL.appendingPathComponent("video.webm")
        let outputURL = baseURL.appendingPathComponent("video.mp4")
        try Data("webm fixture".utf8).write(to: inputURL)

        do {
            _ = try await transcoder.transcodeWebMToMP4(
                inputPath: inputURL.path,
                outputPath: outputURL.path
            )
            XCTFail("Expected stub transcode failure")
        } catch {}

        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path + ".part"))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: MediaTranscoder.temporaryOutputPath(for: outputURL.path)
            ),
            "视频临时文件（video.part.mp4）必须被清理"
        )
    }

    func testTranscodeSuccessReplacesOutputAtomically() async throws {
        let baseURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: baseURL) }
        let stub = try makeStubFFmpeg(in: baseURL, exitCode: 0)
        let fileSystem = GameFileSystemRepository(appSupportDirectory: baseURL)
        let logger = LogWriter(fileSystemRepository: fileSystem)
        let transcoder = MediaTranscoder(
            processManager: ProcessManager(),
            logWriter: logger,
            ffmpegPath: stub.path
        )
        let inputURL = baseURL.appendingPathComponent("background.webp")
        let outputURL = baseURL.appendingPathComponent("background.png")
        try Data("webp fixture".utf8).write(to: inputURL)
        try Data("stale output".utf8).write(to: outputURL)

        let result = try await transcoder.transcodeWebPToPNG(
            inputPath: inputURL.path,
            outputPath: outputURL.path
        )

        XCTAssertEqual(result, outputURL.path)
        XCTAssertEqual(try String(contentsOf: outputURL, encoding: .utf8), "stub-transcode")
        XCTAssertFalse(FileManager.default.fileExists(atPath: outputURL.path + ".part"))
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: MediaTranscoder.temporaryOutputPath(for: outputURL.path)
            ),
            "图片临时文件（background.part.png）必须被清理"
        )
    }

    func testCacheGateRejectsZeroByteArtifacts() async throws {
        let baseURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: baseURL) }
        let supportURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: supportURL) }
        let cache = MediaCacheManager(baseURL: supportURL)
        let gameID = GameType.genshinImpact.rawValue
        let artifactURL = await cache.cachedFileURL(
            forKey: "background.png",
            inDirectory: "\(gameID)/bg-1"
        )
        try Data().write(to: artifactURL)

        let store = PersistenceStore(baseURL: baseURL)
        try await store.writeAppData(AppData())
        let service = try makeBackgroundService(
            cacheBase: supportURL,
            store: store,
            network: makeMockNetwork(response: Self.backgroundResponseJSON())
        )

        let rejected = await service.hasSubCache(
            for: gameID,
            backgroundId: "bg-1",
            type: .background,
            ext: "png"
        )
        XCTAssertFalse(rejected)

        try Data("background fixture".utf8).write(to: artifactURL)
        let accepted = await service.hasSubCache(
            for: gameID,
            backgroundId: "bg-1",
            type: .background,
            ext: "png"
        )
        XCTAssertTrue(accepted)
    }

    func testVideoCacheRequiresCurrentEncodingQuality() async throws {
        let baseURL = try makeTemporaryDirectory()
        let supportURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: baseURL) }
        defer { try? FileManager.default.removeItem(at: supportURL) }
        let cache = MediaCacheManager(baseURL: supportURL)
        let gameID = GameType.genshinImpact.rawValue
        let videoURL = await cache.cachedFileURL(forKey: "video.mp4", inDirectory: "\(gameID)/bg-1")
        try Data("previous video".utf8).write(to: videoURL)
        let service = try makeBackgroundService(
            cacheBase: supportURL,
            store: PersistenceStore(baseURL: baseURL),
            network: makeMockNetwork(response: Self.backgroundResponseJSON())
        )
        var accepted = await service.hasSubCache(for: gameID, backgroundId: "bg-1", type: .video, ext: "mp4")
        XCTAssertFalse(accepted, "Old videos must be regenerated after the quality change")
        try "h264-crf18-slow".write(toFile: videoURL.path + ".quality", atomically: true, encoding: .utf8)
        accepted = await service.hasSubCache(for: gameID, backgroundId: "bg-1", type: .video, ext: "mp4")
        XCTAssertFalse(accepted)
        try MediaTranscoder.videoQualityProfile.write(toFile: videoURL.path + ".quality", atomically: true, encoding: .utf8)
        accepted = await service.hasSubCache(for: gameID, backgroundId: "bg-1", type: .video, ext: "mp4")
        XCTAssertTrue(accepted)
        try Data().write(to: videoURL)
        accepted = await service.hasSubCache(for: gameID, backgroundId: "bg-1", type: .video, ext: "mp4")
        XCTAssertFalse(accepted, "A quality marker cannot make an empty video valid")
    }

    private func makeStubFFmpeg(in directory: URL, exitCode: Int32) throws -> URL {
        let scriptURL = directory.appendingPathComponent("stub-ffmpeg-\(exitCode).sh")
        // 与真实 ffmpeg 一致：输出路径必须以可识别的扩展名结尾，否则无法选择
        // 封装器（`video.mp4.part` 这类写法必须被这里抓住）。
        let script = """
        #!/bin/sh
        for last; do :; done
        case "$last" in
          *.mp4|*.png) ;;
          *) printf "Unable to choose an output format for '%s'\\n" "$last" >&2; exit 234 ;;
        esac
        printf 'stub-transcode' > "$last"
        exit \(exitCode)
        """
        try Data(script.utf8).write(to: scriptURL)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: scriptURL.path
        )
        return scriptURL
    }

    private func makeBackgroundService(
        cacheBase: URL,
        store: PersistenceStore,
        network: NetworkDownloadProvider,
        ffmpegPath: String? = nil,
        userDefaults: UserDefaults? = nil
    ) throws -> BackgroundMediaService {
        let fileSystem = GameFileSystemRepository(appSupportDirectory: cacheBase)
        let logger = LogWriter(fileSystemRepository: fileSystem)
        return BackgroundMediaService(
            mediaTranscoder: MediaTranscoder(processManager: ProcessManager(), logWriter: logger, ffmpegPath: ffmpegPath),
            mediaCacheManager: MediaCacheManager(baseURL: cacheBase),
            networkProvider: network,
            persistenceStore: store,
            logWriter: logger,
            userDefaults: userDefaults ?? makeBackgroundDefaults()
        )
    }

    private func makeBackgroundDefaults(retainOutdated: Bool? = nil) -> UserDefaults {
        let suiteName = "MiPlayBackgroundTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        if let retainOutdated {
            defaults.set(retainOutdated, forKey: BackgroundMediaService.retainOutdatedBackgroundsKey)
        }
        addTeardownBlock {
            UserDefaults(suiteName: suiteName)?.removePersistentDomain(forName: suiteName)
        }
        return defaults
    }

    private func makeBackgroundDownloadNetwork(metadata: Data) -> NetworkDownloadProvider {
        MockURLProtocol.configure { request in
            if request.url?.lastPathComponent == "getAllGameBasicInfo" {
                return .init(data: metadata)
            }
            return .init(data: Data("media fixture".utf8))
        }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        return NetworkDownloadProvider(session: URLSession(configuration: configuration))
    }

    private func archivedBackgroundURLs(cache: MediaCacheManager, gameID: String) async -> [URL] {
        let root = await cache.cacheMetadataURL(forGameId: gameID, filename: ".archive")
        let files = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.allObjects as? [URL]
        return files?.filter { $0.lastPathComponent == "background.png" } ?? []
    }

    private func seedBackgroundCache(
        cache: MediaCacheManager,
        gameID: String,
        groupID: String,
        includeVideo: Bool = false
    ) async throws {
        let url = await cache.cachedFileURL(
            forKey: "background.png",
            inDirectory: "\(gameID)/\(groupID)"
        )
        try Data("background fixture".utf8).write(to: url)
        if includeVideo {
            let videoURL = await cache.cachedFileURL(
                forKey: "video.mp4",
                inDirectory: "\(gameID)/\(groupID)"
            )
            try Data("video fixture".utf8).write(to: videoURL)
            try MediaTranscoder.videoQualityProfile.write(
                toFile: videoURL.path + ".quality", atomically: true, encoding: .utf8
            )
        }
    }

    private func writeFingerprint(
        cache: MediaCacheManager,
        gameID: String,
        groupIDs: [String],
        resourceURLs: [String: String] = [:]
    ) async throws {
        let groups = groupIDs.map { groupID in
            BackgroundMediaService.BackgroundGroupFingerprint(
                groupID: groupID,
                type: "BACKGROUND_TYPE_STATIC",
                version: groupID,
                backgroundIdentity: resourceURLs[groupID] ?? "https://example.com/\(groupID).webp",
                videoIdentity: nil,
                themeIdentity: nil
            )
        }
        let fingerprint = BackgroundMediaService.BackgroundCollectionFingerprint(
            sourceID: "hoyoPlay",
            groups: groups
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(fingerprint)
        try await cache.writeCacheMetadata(
            data,
            forGameId: gameID,
            filename: ".background-fingerprint.json"
        )
    }

    @MainActor
    func testMetalFXOptionExpandsValueIntoLaunchEnvironment() throws {
        let option = try XCTUnwrap(
            PerformanceOptionManager.defaultOptions.first { $0.id == "metalfx_spatial_upscale" }
        )
        XCTAssertTrue(option.requiresValue)
        XCTAssertEqual(option.displayValue, "2")

        // `launchEnvironment()` 只负责展开模板，不判断启用状态：未启用的选项由
        // `getOptionsForLaunch` 过滤，不会进入启动清单。默认系数 2 会展开进
        // `DXMT_CONFIG`，与界面显示保持一致。
        XCTAssertEqual(
            option.launchEnvironment(),
            [
                "DXMT_METALFX_SPATIAL_SWAPCHAIN": "1",
                "DXMT_CONFIG": "d3d11.metalSpatialUpscaleFactor=2;",
            ]
        )

        // 开启 + 自定义系数：开关与 `d3d11.metalSpatialUpscaleFactor` 同时下发。
        var enabled = option
        enabled.isEnabled = true
        enabled.value = "1.33"
        let environment = enabled.launchEnvironment()
        XCTAssertEqual(environment["DXMT_METALFX_SPATIAL_SWAPCHAIN"], "1")
        XCTAssertEqual(environment["DXMT_CONFIG"], "d3d11.metalSpatialUpscaleFactor=1.33;")
        XCTAssertNil(environment["DXMT_CONFIG_FILE"], "系数走 DXMT_CONFIG，不写配置文件路径")

        // 越界/缺失的值不会下发成非法系数：夹取到 1.0–2.0，缺失回落默认 2。
        var outOfRange = option
        outOfRange.value = "5"
        XCTAssertEqual(outOfRange.launchEnvironment()["DXMT_CONFIG"], "d3d11.metalSpatialUpscaleFactor=2;")
        var missingValue = option
        missingValue.value = nil
        XCTAssertEqual(missingValue.launchEnvironment()["DXMT_CONFIG"], "d3d11.metalSpatialUpscaleFactor=2;")
    }

    @MainActor
    func testLaunchEnvironmentMergesOptionsWithLaterOptionsWinning() throws {
        var upscale = try XCTUnwrap(
            PerformanceOptionManager.defaultOptions.first { $0.id == "metalfx_spatial_upscale" }
        )
        upscale.isEnabled = true
        upscale.value = "1.5"
        var hud = try XCTUnwrap(
            PerformanceOptionManager.defaultOptions.first { $0.id == "metal_hud" }
        )
        hud.isEnabled = true

        let environment = PerformanceOption.launchEnvironment(for: [hud, upscale])
        XCTAssertEqual(environment["MTL_HUD_ENABLED"], "1")
        // 不再覆盖面板元素与尺寸：使用 Metal HUD 的系统默认（Lite）布局。
        XCTAssertNil(environment["MTL_HUD_ELEMENTS"])
        XCTAssertNil(environment["MTL_HUD_SCALE"])
        XCTAssertEqual(environment["DXMT_METALFX_SPATIAL_SWAPCHAIN"], "1")
        XCTAssertEqual(environment["DXMT_CONFIG"], "d3d11.metalSpatialUpscaleFactor=1.5;")

        // 关闭的选项不产生任何环境变量。
        XCTAssertTrue(PerformanceOption.launchEnvironment(for: []).isEmpty)
    }

    @MainActor
    func testPerformanceOptionNormalizesFactorIntoSupportedRange() {
        XCTAssertEqual(PerformanceOption.normalizedValue("2"), "2")
        XCTAssertEqual(PerformanceOption.normalizedValue(" 1.5 "), "1.5")
        XCTAssertEqual(PerformanceOption.normalizedValue("1.33"), "1.33")
        XCTAssertEqual(PerformanceOption.normalizedValue("1,33"), "1.33", "小数逗号应被接受")
        // 越界夹取到 DXMT 支持的 1.0–2.0。
        XCTAssertEqual(PerformanceOption.normalizedValue("5"), "2")
        XCTAssertEqual(PerformanceOption.normalizedValue("0.5"), "1")
        // 不可解析的输入被拒绝。
        XCTAssertNil(PerformanceOption.normalizedValue(""))
        XCTAssertNil(PerformanceOption.normalizedValue("abc"))
        XCTAssertNil(PerformanceOption.normalizedValue("1.5x"))
    }

    @MainActor
    func testMetalFXOptionValuePersistsPerGameButDoesNotApplyWhileSuspended() async throws {
        let baseURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: baseURL) }
        let store = PersistenceStore(baseURL: baseURL)
        try await store.writeAppData(AppData())
        let manager = PerformanceOptionManager(
            persistenceStore: store,
            logWriter: LogWriter(fileSystemRepository: GameFileSystemRepository())
        )
        await manager.loadOptions()

        let genshin = GameType.genshinImpact.rawValue
        let zzz = GameType.zenlessZoneZero.rawValue

        try await manager.setOption(gameId: genshin, optionId: "metalfx_spatial_upscale", enabled: true)
        try await manager.setValue(gameId: genshin, optionId: "metalfx_spatial_upscale", value: "1.33")

        // 每游戏独立：绝区零保持关闭与默认系数。
        XCTAssertEqual(manager.getOption(gameId: zzz, optionId: "metalfx_spatial_upscale")?.isEnabled, false)
        XCTAssertEqual(manager.getOption(gameId: zzz, optionId: "metalfx_spatial_upscale")?.displayValue, "2")

        // 启动环境：选项已搁置（`isSuspended`），即使 AppData 里仍是启用状态，
        // 也不会把 DXMT 变量注入启动环境；持久化的开关与系数保留，恢复功能后可用。
        let launchEnvironment = PerformanceOption.launchEnvironment(
            for: manager.getOptionsForLaunch(gameId: genshin)
        )
        XCTAssertNil(launchEnvironment["DXMT_CONFIG"])
        XCTAssertNil(launchEnvironment["DXMT_METALFX_SPATIAL_SWAPCHAIN"])
        XCTAssertTrue(manager.getOptionsForLaunch(gameId: zzz).isEmpty)

        // 持久化：重新加载后系数与开关都保留。
        let persisted = try await store.readAppData()
        let saved = try XCTUnwrap(
            persisted.performanceOptions[genshin]?.first { $0.id == "metalfx_spatial_upscale" }
        )
        XCTAssertTrue(saved.isEnabled)
        XCTAssertEqual(saved.value, "1.33")

        let reloaded = PerformanceOptionManager(
            persistenceStore: store,
            logWriter: LogWriter(fileSystemRepository: GameFileSystemRepository())
        )
        await reloaded.loadOptions()
        XCTAssertEqual(
            reloaded.getOption(gameId: genshin, optionId: "metalfx_spatial_upscale")?.displayValue,
            "1.33"
        )
    }

    @MainActor
    func testPerformanceOptionRejectsUnparsableValueAndKeepsPrevious() async throws {
        let baseURL = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: baseURL) }
        let store = PersistenceStore(baseURL: baseURL)
        try await store.writeAppData(AppData())
        let manager = PerformanceOptionManager(
            persistenceStore: store,
            logWriter: LogWriter(fileSystemRepository: GameFileSystemRepository())
        )
        await manager.loadOptions()

        let genshin = GameType.genshinImpact.rawValue
        try await manager.setValue(gameId: genshin, optionId: "metalfx_spatial_upscale", value: "1.5")
        do {
            try await manager.setValue(gameId: genshin, optionId: "metalfx_spatial_upscale", value: "abc")
            XCTFail("非法参数应被拒绝")
        } catch let error as PerformanceOptionManager.OptionError {
            guard case .invalidValue = error else {
                return XCTFail("错误类型应为 invalidValue，实际 \(error)")
            }
        }

        // 被拒绝的输入不改变内存状态，也不写入持久化。
        XCTAssertEqual(manager.getOption(gameId: genshin, optionId: "metalfx_spatial_upscale")?.displayValue, "1.5")
        let persisted = try await store.readAppData()
        XCTAssertEqual(
            persisted.performanceOptions[genshin]?.first { $0.id == "metalfx_spatial_upscale" }?.value,
            "1.5"
        )
    }

    @MainActor
    func testSettingsViewModelPersistsMetalFXFactorAndReportsInvalidInput() async throws {
        let fixture = try await makeScheduler()
        let viewModel = SettingsViewModel(
            systemDetector: SystemEnvironmentDetector(),
            wineVersionManager: fixture.wineManager,
            gameRegistry: fixture.registry,
            fileSystemRepository: GameFileSystemRepository(appSupportDirectory: try makeTemporaryDirectory()),
            taskScheduler: fixture.scheduler,
            performanceOptionManager: PerformanceOptionManager(
                persistenceStore: fixture.persistence,
                logWriter: fixture.logger
            )
        )
        await viewModel.loadSettings()

        let genshin = GameType.genshinImpact.rawValue
        await viewModel.setPerformanceOption(
            gameID: genshin,
            optionID: "metalfx_spatial_upscale",
            enabled: true
        )
        await viewModel.setPerformanceOptionValue(
            gameID: genshin,
            optionID: "metalfx_spatial_upscale",
            value: "1.33"
        )

        XCTAssertEqual(
            viewModel.performanceOption(gameID: genshin, optionID: "metalfx_spatial_upscale")?.displayValue,
            "1.33"
        )
        XCTAssertTrue(
            viewModel.options(for: genshin).contains { $0.id == "metalfx_spatial_upscale" && $0.isEnabled }
        )

        // 其它游戏不受影响。
        let zzz = GameType.zenlessZoneZero.rawValue
        XCTAssertEqual(
            viewModel.performanceOption(gameID: zzz, optionID: "metalfx_spatial_upscale")?.isEnabled,
            false
        )

        // 不可解析的输入被拒绝并回报给设置窗口的错误呈现。
        await viewModel.setPerformanceOptionValue(
            gameID: genshin,
            optionID: "metalfx_spatial_upscale",
            value: "abc"
        )
        XCTAssertNotNil(viewModel.errorMessage)
        XCTAssertEqual(
            viewModel.performanceOption(gameID: genshin, optionID: "metalfx_spatial_upscale")?.displayValue,
            "1.33"
        )
    }

    /// 设置窗口的开关依赖 `@Observable` 的失效通知重绘。若开关状态要等异步
    /// 持久化完成才更新，SwiftUI 在 setter 返回后立刻读到的仍是旧值，开关会
    /// 弹回原位（用户实测症状）。因此这里复现 Toggle 的读写时序。
    @MainActor
    func testPerformanceOptionToggleAppliesSynchronouslyAndInvalidatesObservers() async throws {
        let fixture = try await makeScheduler()
        let viewModel = SettingsViewModel(
            systemDetector: SystemEnvironmentDetector(),
            wineVersionManager: fixture.wineManager,
            gameRegistry: fixture.registry,
            fileSystemRepository: GameFileSystemRepository(appSupportDirectory: try makeTemporaryDirectory()),
            taskScheduler: fixture.scheduler,
            performanceOptionManager: PerformanceOptionManager(
                persistenceStore: fixture.persistence,
                logWriter: fixture.logger
            )
        )
        await viewModel.loadSettings()

        let genshin = GameType.genshinImpact.rawValue
        XCTAssertFalse(
            viewModel.options(for: genshin).contains { $0.id == "metal_hud" && $0.isEnabled }
        )

        let observedChange = ObservationFlag()
        withObservationTracking {
            _ = viewModel.performanceOption(gameID: genshin, optionID: "metal_hud")?.isEnabled
        } onChange: {
            observedChange.mark()
        }

        // Toggle 的 setter：必须同步落到界面读到的状态上。
        let accepted = viewModel.applyPerformanceOptionChange(
            gameID: genshin,
            optionID: "metal_hud",
            enabled: true
        )
        XCTAssertTrue(accepted)
        XCTAssertTrue(observedChange.isSet, "同步应用必须触发观察者失效，否则界面不会重绘")
        XCTAssertEqual(
            viewModel.performanceOption(gameID: genshin, optionID: "metal_hud")?.isEnabled,
            true,
            "setter 返回后立刻读取必须已是新值，否则开关会回弹"
        )

        // 后台持久化完成后仍然一致，且写入磁盘。
        try await waitForOptionPersisted(
            gameID: genshin,
            optionID: "metal_hud",
            isEnabled: true,
            store: fixture.persistence
        )
        XCTAssertEqual(
            viewModel.performanceOption(gameID: genshin, optionID: "metal_hud")?.isEnabled,
            true
        )
    }

    /// 等待后台持久化把开关写入 AppData。
    @MainActor
    private func waitForOptionPersisted(
        gameID: String,
        optionID: String,
        isEnabled: Bool,
        store: PersistenceStore
    ) async throws {
        let deadline = Date().addingTimeInterval(3)
        while Date() < deadline {
            let persisted = try await store.readAppData()
            let saved = persisted.performanceOptions[gameID]?.first { $0.id == optionID }
            if saved?.isEnabled == isEnabled { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        XCTFail("性能选项未在超时前持久化")
    }

}

private final class SophonPatchRangeFixture: @unchecked Sendable {
    private let lock = NSLock()
    private let payload: Data
    private var failLast: Bool
    private var requests: [String] = []
    init(payload: Data, failLast: Bool = true) { self.payload = payload; self.failLast = failLast }
    func fetch(_ request: URLRequest) throws -> (Data, HTTPURLResponse) {
        lock.lock(); defer { lock.unlock() }
        let value = request.value(forHTTPHeaderField: "Range") ?? ""
        requests.append(value)
        let parts = value.dropFirst("bytes=".count).split(separator: "-")
        guard parts.count == 2, let start = Int(parts[0]), let end = Int(parts[1]),
              start >= 0, end >= start, end < payload.count, let url = request.url else { throw URLError(.badURL) }
        if failLast && start > 0 {
            failLast = false
            return (Data(), HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: [:])!)
        }
        return (payload.subdata(in: start..<(end + 1)), HTTPURLResponse(url: url, statusCode: 206, httpVersion: nil,
            headerFields: ["Content-Range": "bytes \(start)-\(end)/\(payload.count)"])!)
    }
    var ranges: [String] { lock.lock(); defer { lock.unlock() }; return requests }
}

@MainActor extension MiPlayCoreTests {
    func testSophonPatchManifestValidatesRangesPathsAndVersions() throws {
        func entry(path: String = "data/target.bin", source: String = "data/old.bin", offset: UInt64 = 2, length: UInt64 = 3) -> Data {
            let digest = Data("0123456789abcdef0123456789abcdef".utf8)
            let info = sophonProtobufBytes(1, Data("0123456789abcdef_0123456789abcdef0123456789abcdef".utf8))
                + sophonProtobufBytes(2, Data("7.1.0".utf8)) + sophonProtobufNumber(4, 10)
                + sophonProtobufNumber(6, offset) + sophonProtobufNumber(7, length)
                + sophonProtobufBytes(8, Data(source.utf8)) + sophonProtobufNumber(9, 8) + sophonProtobufBytes(10, digest)
            let patch = sophonProtobufBytes(1, Data("7.1.0".utf8)) + sophonProtobufBytes(2, info)
            let file = sophonProtobufBytes(1, Data(path.utf8)) + sophonProtobufNumber(2, 15)
                + sophonProtobufBytes(3, digest) + sophonProtobufBytes(4, patch)
            return sophonProtobufBytes(1, file)
        }
        let data = entry()
        let decoded = try SophonPatchDecoder.decode(data, version: "7.1.0")
        XCTAssertEqual(decoded.count, 1)
        XCTAssertEqual(decoded[0].path, "data/target.bin")
        XCTAssertEqual(decoded[0].offset, 2)
        XCTAssertEqual(decoded[0].length, 3)
        XCTAssertEqual(decoded[0].originalPath, "data/old.bin")
        XCTAssertTrue(try SophonPatchDecoder.decode(data, version: "7.0.0").isEmpty)
        XCTAssertThrowsError(try SophonPatchDecoder.decode(entry(path: "../escape"), version: "7.1.0"))
        XCTAssertThrowsError(try SophonPatchDecoder.decode(entry(source: "/escape"), version: "7.1.0"))
        XCTAssertThrowsError(try SophonPatchDecoder.decode(entry(offset: 9, length: 2), version: "7.1.0"))
        XCTAssertThrowsError(try SophonPatchDecoder.decode(data + data, version: "7.1.0"))
        XCTAssertThrowsError(try SophonPatchDecoder.decode(Data([0x0a, 0x80]), version: "7.1.0"))
    }

    func testSophonPatchCacheResumesRechecksAndRejectsLinks() async throws {
        let root = try makeTemporaryDirectory().resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = Data(repeating: 0x42, count: Int(SophonPatchCache.segmentSize) + 17)
        let fixture = SophonPatchRangeFixture(payload: payload)
        let object = SophonPatchObject(id: "object", size: UInt64(payload.count), prefix: URL(string: "https://example.com/patch")!)
        let cache = SophonPatchCache(root: root, fetch: { try fixture.fetch($0) })
        do { try await cache.download(object); XCTFail("A server ignoring Range must be rejected") }
        catch {}
        try await cache.download(object)
        XCTAssertEqual(fixture.ranges.filter { $0.hasPrefix("bytes=0-") }.count, 1)
        XCTAssertEqual(fixture.ranges.count, 3)
        let outputURL = root.appendingPathComponent("result")
        XCTAssertTrue(FileManager.default.createFile(atPath: outputURL.path, contents: nil))
        let output = try FileHandle(forWritingTo: outputURL)
        try await cache.copy(object, to: output)
        try output.close()
        XCTAssertEqual(try Data(contentsOf: outputURL), payload)

        let segment = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
            .first { $0.lastPathComponent.hasSuffix("-0.part") })
        try Data(repeating: 0, count: Int(SophonPatchCache.segmentSize) + 32).write(to: segment)
        try await cache.download(object)
        XCTAssertEqual(fixture.ranges.filter { $0.hasPrefix("bytes=0-") }.count, 2)
        try FileManager.default.removeItem(at: segment)
        XCTAssertEqual(mkfifo(segment.path, mode_t(0o600)), 0)
        do { try await cache.download(object); XCTFail("A FIFO must be rejected without blocking") }
        catch {}
        try FileManager.default.removeItem(at: segment)
        let victim = root.appendingPathComponent("victim")
        try Data("preserved".utf8).write(to: victim)
        try FileManager.default.createSymbolicLink(at: segment, withDestinationURL: victim)
        do { try await cache.download(object); XCTFail("A cache symlink must be rejected") }
        catch {}
        XCTAssertEqual(try String(contentsOf: victim, encoding: .utf8), "preserved")
    }
}

@MainActor extension MiPlayCoreTests {
    func testSophonPatchCacheDownloadsOnlyNeededSegmentsAndInvalidates() async throws {
        let root = try makeTemporaryDirectory().resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let size = Int(SophonPatchCache.segmentSize) + 17
        let payload = Data(repeating: 0x23, count: size)
        let fixture = SophonPatchRangeFixture(payload: payload)
        let object = SophonPatchObject(id: "object", size: UInt64(size), prefix: URL(string: "https://example.com/patch")!)
        let cache = SophonPatchCache(root: root, fetch: { try fixture.fetch($0) })
        let first = SophonPatchCache.segmentSize
        let range = (first + 3)..<(first + 8)
        let initialBytes = try await cache.estimatedRemainingBytes(object, ranges: [range])
        XCTAssertEqual(initialBytes, 17 + 32)
        do { try await cache.download(object, ranges: [range, range]); XCTFail("Expected fixture failure") } catch {}
        try await cache.download(object, ranges: [range, range])
        XCTAssertEqual(fixture.ranges.count, 2)
        XCTAssertTrue(fixture.ranges.allSatisfy { $0.hasPrefix("bytes=\(first)-") })
        let completedBytes = try await cache.estimatedRemainingBytes(object, ranges: [range])
        XCTAssertEqual(completedBytes, 0)
        let outputURL = root.appendingPathComponent("partial")
        XCTAssertTrue(FileManager.default.createFile(atPath: outputURL.path, contents: nil))
        let output = try FileHandle(forWritingTo: outputURL)
        try await cache.copy(object, range: range, to: output)
        try output.close()
        XCTAssertEqual(try Data(contentsOf: outputURL), Data(repeating: 0x23, count: 5))
        try await cache.invalidate(object, ranges: [range])
        do {
            try await cache.download(object, ranges: [range], beforeWrite: { _ in throw URLError(.cannotWriteToFile) })
            XCTFail("A failed disk-space check must prevent writes")
        } catch {}
        let remaining = try await cache.estimatedRemainingBytes(object, ranges: [range])
        XCTAssertEqual(remaining, 17 + 32)
        try await cache.download(object, ranges: [range])
        XCTAssertEqual(fixture.ranges.count, 4)
    }
}

@MainActor extension MiPlayCoreTests {
    /// Optional acceptance fetches only official metadata and compressed diff
    /// manifests; it never downloads a patch object or touches a game folder.
    func testLiveSophonPatchMetadataOnly() async throws {
        guard ProcessInfo.processInfo.environment["MIPLAY_LIVE_PATCH_METADATA"] == "1" else {
            throw XCTSkip("Set TEST_RUNNER_MIPLAY_LIVE_PATCH_METADATA=1 for the metadata-only check")
        }
        let candidate = try await SophonMetadataClient().fetchPreDownloadBuild(for: .genshinImpact)
        let build = try XCTUnwrap(candidate)
        let categories = try await SophonPatchClient().fetch(build: build, from: "7.1.0")
        XCTAssertTrue(categories.contains { $0.id == "game" && !$0.files.isEmpty })
        XCTAssertTrue(categories.contains { $0.id == "zh-cn" && !$0.files.isEmpty })
    }
}

private final class SophonPatchProtocolStub: URLProtocol {
    struct Reply: Sendable { let data: Data; let status: Int; let headers: [String: String] }
    private static let lock = NSLock()
    nonisolated(unsafe) private static var handler: (@Sendable (URLRequest) -> Reply)?
    static func configure(_ body: @escaping @Sendable (URLRequest) -> Reply) {
        lock.lock(); handler = body; lock.unlock()
    }
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        Self.lock.lock(); let reply = Self.handler?(request); Self.lock.unlock()
        guard let reply, let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse)); return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: reply.data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

@MainActor extension MiPlayCoreTests {
    func testSophonPatchCancellationRetainsCompletedSegments() async throws {
        let root = try makeTemporaryDirectory().resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = Data(repeating: 0x58, count: Int(SophonPatchCache.segmentSize) + 5)
        let fixture = SophonPatchRangeFixture(payload: payload, failLast: false)
        let object = SophonPatchObject(id: "object", size: UInt64(payload.count), prefix: URL(string: "https://example.com")!)
        let (events, signal) = AsyncStream<Void>.makeStream()
        let cache = SophonPatchCache(root: root, fetch: { request in
            if !(request.value(forHTTPHeaderField: "Range") ?? "").hasPrefix("bytes=0-") {
                signal.yield(())
                try await Task.sleep(for: .seconds(60))
            }
            return try fixture.fetch(request)
        })
        let task = Task { try await cache.download(object) }
        for await _ in events { break }
        task.cancel()
        do { try await task.value; XCTFail("Cancellation must stop the download") } catch {}
        signal.finish()
        let resumed = SophonPatchCache(root: root, fetch: { try fixture.fetch($0) })
        try await resumed.download(object)
        XCTAssertEqual(fixture.ranges.count, 2)
        XCTAssertEqual(fixture.ranges.filter { $0.hasPrefix("bytes=0-") }.count, 1)
    }

    func testSophonPatchProductionTransportValidatesResponseAndBoundsBody() async throws {
        let root = try makeTemporaryDirectory().resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [SophonPatchProtocolStub.self]
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }
        let cache = SophonPatchCache(root: root, session: session)
        let object = SophonPatchObject(id: "object", size: 5, prefix: URL(string: "https://example.com")!)
        SophonPatchProtocolStub.configure { _ in .init(data: Data("abcde".utf8), status: 200, headers: [:]) }
        do { try await cache.download(object); XCTFail("Server ignoring Range must fail") } catch {}
        SophonPatchProtocolStub.configure { _ in .init(data: Data("abcde".utf8), status: 206, headers: ["Content-Range": "bytes 0-4/6"]) }
        do { try await cache.download(object); XCTFail("Incorrect Content-Range must fail") } catch {}
        SophonPatchProtocolStub.configure { _ in .init(data: Data(count: Int(SophonPatchCache.segmentSize) + 1), status: 206,
                                                        headers: ["Content-Range": "bytes 0-4/5"]) }
        do { try await cache.download(object); XCTFail("Oversized body must be stopped") } catch {}
        SophonPatchProtocolStub.configure { _ in .init(data: Data("abcde".utf8), status: 206, headers: ["Content-Range": "bytes 0-4/5"]) }
        try await cache.download(object)
        let outputURL = root.appendingPathComponent("result")
        XCTAssertTrue(FileManager.default.createFile(atPath: outputURL.path, contents: nil))
        let output = try FileHandle(forWritingTo: outputURL)
        try await cache.copy(object, to: output)
        try output.close()
        XCTAssertEqual(try Data(contentsOf: outputURL), Data("abcde".utf8))
    }
}

@MainActor extension MiPlayCoreTests {
    func testSophonPatchCleanupRemovesOnlyCommittedObjectAndItsSegments() async throws {
        let root = try makeTemporaryDirectory().resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let fixture = SophonPatchRangeFixture(payload: Data("abcde".utf8), failLast: false)
        let cache = SophonPatchCache(root: root, fetch: { try fixture.fetch($0) })
        let prefix = URL(string: "https://example.com")!
        let a = SophonPatchObject(id: "object-a", size: 5, prefix: prefix)
        let b = SophonPatchObject(id: "object-b", size: 5, prefix: prefix)
        try await cache.download(a)
        try await cache.download(b)
        let removedFirst = try await cache.cleanup(objects: [a, a])
        XCTAssertFalse(removedFirst, "另一个对象的缓存必须保留")
        let existing = try FileManager.default.contentsOfDirectory(atPath: root.path)
        XCTAssertEqual(existing.filter { $0.hasSuffix(".part") }.count, 1)
        XCTAssertEqual(existing.filter { $0.hasSuffix(".lock") }.count, 1)
        let outputURL = root.appendingPathComponent("other-result")
        XCTAssertTrue(FileManager.default.createFile(atPath: outputURL.path, contents: nil))
        let output = try FileHandle(forWritingTo: outputURL)
        try await cache.copy(b, to: output)
        try output.close()
        XCTAssertEqual(try Data(contentsOf: outputURL), Data("abcde".utf8))
        try FileManager.default.removeItem(at: outputURL)
        let removedLast = try await cache.cleanup(objects: [b])
        XCTAssertTrue(removedLast)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    }

    func testSophonPatchCleanupPreservesUnknownCorruptAndLinkedFiles() async throws {
        let root = try makeTemporaryDirectory().resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let payload = Data(repeating: 0x51, count: Int(SophonPatchCache.segmentSize) + 5)
        let fixture = SophonPatchRangeFixture(payload: payload, failLast: false)
        let cache = SophonPatchCache(root: root, fetch: { try fixture.fetch($0) })
        let object = SophonPatchObject(id: "object", size: UInt64(payload.count), prefix: URL(string: "https://example.com")!)
        try await cache.download(object)
        let files = try FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)
        let corrupt = try XCTUnwrap(files.first { $0.lastPathComponent.hasSuffix("-0.part") })
        let linked = try XCTUnwrap(files.first { $0.lastPathComponent.hasSuffix("-1.part") })
        let corruptData = Data("unknown content".utf8)
        try corruptData.write(to: corrupt)
        try FileManager.default.removeItem(at: linked)
        let victim = root.appendingPathComponent("victim")
        try Data("preserve".utf8).write(to: victim)
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: victim)
        let other = root.appendingPathComponent("unrecognized")
        try Data("other".utf8).write(to: other)
        let removed = try await cache.cleanup(objects: [object])
        XCTAssertFalse(removed)
        XCTAssertEqual(try Data(contentsOf: corrupt), corruptData)
        XCTAssertEqual(try String(contentsOf: victim, encoding: .utf8), "preserve")
        XCTAssertEqual(try String(contentsOf: other, encoding: .utf8), "other")
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: linked.path)[.type] as? FileAttributeType, .typeSymbolicLink)
    }
}

private actor SophonPatchProgressValues {
    private var values: [UInt64] = []
    func record(_ value: UInt64) { values.append(value) }
    func snapshot() -> [UInt64] { values }
}

@MainActor extension MiPlayCoreTests {
    func testSophonPatchProgressIncludesResumedBytesAndDeduplicatesRanges() async throws {
        let root = try makeTemporaryDirectory().resolvingSymlinksInPath()
        defer { try? FileManager.default.removeItem(at: root) }
        let part = SophonPatchCache.segmentSize
        let payload = Data(repeating: 0x73, count: Int(part) + 17)
        let fixture = SophonPatchRangeFixture(payload: payload)
        let object = SophonPatchObject(id: "progress", size: UInt64(payload.count), prefix: URL(string: "https://example.com")!)
        let cache = SophonPatchCache(root: root, fetch: { try fixture.fetch($0) })
        let full = try await cache.selectedBytes(object, ranges: [0..<2, 1..<(part + 1), part..<(part + 17)])
        XCTAssertEqual(full, part + 17)
        let tail = try await cache.selectedBytes(object, ranges: [(part + 1)..<(part + 2), part..<(part + 17)])
        XCTAssertEqual(tail, 17)
        do { try await cache.download(object); XCTFail("Expected fixture failure") } catch {}
        let observed = SophonPatchProgressValues()
        try await cache.download(object, progress: { value in await observed.record(value) })
        let values = await observed.snapshot()
        XCTAssertEqual(values, [part, part + 17])
        XCTAssertEqual(fixture.ranges.filter { $0.hasPrefix("bytes=0-") }.count, 1)
    }
}
