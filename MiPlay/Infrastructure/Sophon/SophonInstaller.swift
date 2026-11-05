import Foundation
import CryptoKit
import Darwin

nonisolated public enum SophonInstallMode: Sendable { case install, update, updateConfirmedMainland }
nonisolated public struct SophonProgress: Sendable {
    public let fractionCompleted: Double?
    public let message: String
    public let bytesCompleted: Int64
    public let bytesTotal: Int64?
}
nonisolated public struct SophonInstallResult: Sendable { public let version: String }

private actor SophonPatchProgressCounter {
    private var completed: UInt64 = 0
    func record(_ value: UInt64) { completed = max(completed, value) }
    func value() -> UInt64 { completed }
}

/// Installs current mainland game resources into an authorized directory.
/// Fresh installs retain the original all-or-nothing transaction. Updates use
/// a durable per-file transaction and continue forward after interruption.
public actor SophonInstaller {
    nonisolated public static let transactionDirectoryName = ".miplay-sophon-transaction"
    nonisolated public static let resumeDirectoryName = SophonResumeCache.directoryName
    nonisolated static let preDownloadSpaceReserve: UInt64 = 2 * 1024 * 1024 * 1024
    let metadata: SophonMetadataClient
    let patchClient: SophonPatchClient
    let session: URLSession
    let preDownloadAvailableBytes: @Sendable (URL) throws -> UInt64
    let fm = FileManager.default
    let transactionName = SophonInstaller.transactionDirectoryName
    var incrementalReceiptDigest: String?
    private let installReceiptName = "committed-install.json"
    private struct ReceiptAuthorization {
        let destination: String
        let game: GameType
        let digest: String
    }
    private var receiptAuthorization: ReceiptAuthorization?

    public init(session: URLSession = .shared, preDownloadAvailableBytes: (@Sendable (URL) throws -> UInt64)? = nil) {
        self.metadata = SophonMetadataClient(session: session)
        self.patchClient = SophonPatchClient(session: session)
        self.session = session
        self.preDownloadAvailableBytes = preDownloadAvailableBytes ?? { url in
            let attrs = try FileManager.default.attributesOfFileSystem(forPath: url.path)
            guard let free = (attrs[.systemFreeSize] as? NSNumber)?.uint64Value else {
                throw SophonProtocolError.unsupported("无法读取预下载目标磁盘的可用空间")
            }
            return free
        }
    }

    /// The caller retains the token through transaction and registration work.
    internal func acquireExclusiveAccess(destination: URL) throws -> SophonDirectoryLock {
        let root = try canonicalDestination(destination)
        try validateRoot(root)
        return try SophonDirectoryLock.acquire(at: root)
    }

    func operationLock(at root: URL, holding supplied: SophonDirectoryLock?) throws -> SophonDirectoryLock {
        if let supplied {
            try supplied.validate(at: root)
            return supplied
        }
        return try SophonDirectoryLock.acquire(at: root)
    }

    private struct Operation: Codable {
        let path: String
        let hadExisting: Bool
        let installedMD5: String
        let deletion: Bool?
        let originalMD5: String?
    }
    private struct Journal: Codable {
        let version: Int
        let game: GameType
        let destination: String
        var committed: Bool
        var operations: [Operation]
        var createdDirectories: [String]
        let installMode: String?
        let targetVersion: String?
    }
    private struct ResumeIdentity: Encodable {
        let game: GameType
        let region: String
        let mode: String
        let sourceVersion: String
        let targetVersion: String
        let manifests: [String]
    }

    /// True means the directory must not be launched or modified until recovery.
    public func hasPendingTransaction(destination: URL) -> Bool {
        fm.fileExists(atPath: destination.appendingPathComponent(transactionName).path)
    }

    /// Identifies a transaction without changing any files. A directory with
    /// no trustworthy journal must not be claimed as one of our transactions.
    public func hasRecoverableTransaction(destination: URL, game: GameType) throws -> Bool {
        let root = try canonicalDestination(destination)
        try validateRoot(root)
        let work = root.appendingPathComponent(transactionName, isDirectory: true)
        var status = stat()
        guard lstat(work.path, &status) == 0 else {
            if errno == ENOENT { return false }
            throw SophonProtocolError.corrupt("无法检查安装事务，请保留目录并重试")
        }
        if try incrementalJournal(at: root, game: game) == nil {
            _ = try trustedJournal(work: work, root: root, game: game)
        }
        return true
    }

    private func trustedJournal(work: URL, root: URL, game: GameType) throws -> Journal {
        let workAttributes = try fm.attributesOfItem(atPath: work.path)
        guard workAttributes[.type] as? FileAttributeType == .typeDirectory else {
            throw SophonProtocolError.corrupt("安装事务目录无效，请保留目录并进行人工恢复")
        }
        let journalURL = work.appendingPathComponent("journal.json")
        guard let attributes = try? fm.attributesOfItem(atPath: journalURL.path),
              attributes[.type] as? FileAttributeType == .typeRegular else {
            throw SophonProtocolError.corrupt("安装事务缺少有效恢复记录，请保留目录并进行人工恢复")
        }
        let journal = try JSONDecoder().decode(Journal.self, from: Data(contentsOf: journalURL))
        guard journal.version == 1, journal.game == game,
              try canonicalDestination(URL(fileURLWithPath: journal.destination, isDirectory: true)).path == root.path else {
            throw SophonProtocolError.corrupt("安装事务与游戏目录不匹配")
        }
        return journal
    }

    /// Roll back an interrupted transaction. Never removes an unrecognized file.
    @discardableResult
    public func recover(destination: URL, game: GameType, holding suppliedLock: SophonDirectoryLock? = nil) throws -> SophonInstallResult? {
        let root = try canonicalDestination(destination)
        try validateRoot(root)
        guard fm.fileExists(atPath: root.path) else { return nil }
        let directoryLock = try operationLock(at: root, holding: suppliedLock)
        defer { if suppliedLock == nil { directoryLock.release() } }
        if var journal = try incrementalJournal(at: root, game: game) {
            return try recoverIncrementalUpdate(&journal, root: root)
        }
        let work = root.appendingPathComponent(transactionName, isDirectory: true)
        guard fm.fileExists(atPath: work.path) else { return nil }
        let journal = try trustedJournal(work: work, root: root, game: game)
        var completedInstall: SophonInstallResult?
        if journal.committed, journal.installMode == "install" {
            guard let version = journal.targetVersion else {
                throw SophonProtocolError.corrupt("已提交安装缺少版本记录，已保留恢复事务")
            }
            try verifyCommittedInstall(journal, root: root, game: game, version: version)
            try publishCommittedInstallReceipt(journal, root: root, game: game)
            completedInstall = SophonInstallResult(version: version)
        }
        if !journal.committed {
            let stagedRoot = work.appendingPathComponent("staged", isDirectory: true)
            let backupRoot = work.appendingPathComponent("backup", isDirectory: true)
            for op in journal.operations.reversed() {
                let target = try safeURL(root: root, path: op.path)
                let staged = try safeURL(root: stagedRoot, path: op.path)
                let backup = try safeURL(root: backupRoot, path: op.path)
                if fm.fileExists(atPath: backup.path) {
                    if fm.fileExists(atPath: target.path) {
                        guard op.deletion != true else {
                            throw SophonProtocolError.corrupt("恢复时发现删除路径已被占用：\(op.path)")
                        }
                        guard try fileMD5(target, honorCancellation: false) == op.installedMD5 else {
                            throw SophonProtocolError.corrupt("恢复时发现已修改的文件：\(op.path)")
                        }
                        try fm.removeItem(at: target)
                    }
                    try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fm.moveItem(at: backup, to: target)
                } else if !op.hadExisting && !fm.fileExists(atPath: staged.path) && fm.fileExists(atPath: target.path) {
                    guard try fileMD5(target, honorCancellation: false) == op.installedMD5 else {
                        throw SophonProtocolError.corrupt("恢复时发现已修改的文件：\(op.path)")
                    }
                    try fm.removeItem(at: target)
                } else if op.deletion == true && !fm.fileExists(atPath: target.path) {
                    throw SophonProtocolError.corrupt("恢复时缺少已删除文件的备份：\(op.path)")
                } else if op.hadExisting && op.deletion != true && !fm.fileExists(atPath: staged.path) {
                    throw SophonProtocolError.corrupt("恢复时缺少原始文件备份：\(op.path)")
                }
            }
            // Remove only directories which the transaction planned to create,
            // and only while empty; unrelated user files are never removed.
            for path in journal.createdDirectories.sorted(by: { $0.count > $1.count }) {
                let directory = try safeURL(root: root, path: path)
                var isDirectory: ObjCBool = false
                if fm.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue,
                   try fm.contentsOfDirectory(atPath: directory.path).isEmpty {
                    try fm.removeItem(at: directory)
                }
            }
        }
        try fm.removeItem(at: work)
        return completedInstall
    }

    public func run(game: GameType, destination: URL, mode: SophonInstallMode, holding suppliedLock: SophonDirectoryLock? = nil,
                    progress: @escaping @Sendable (SophonProgress) async -> Void) async throws -> SophonInstallResult {
        if case .install = mode {} else {
            return try await runIncrementalUpdate(game: game, destination: destination, mode: mode,
                                                  holding: suppliedLock, progress: progress)
        }
        let capabilities = game.definition.contentCapabilities
        switch mode {
        case .install:
            guard capabilities.sophonInstall else { throw SophonProtocolError.unsupported("此游戏暂不支持 Sophon 安装") }
        case .update, .updateConfirmedMainland:
            guard capabilities.sophonUpdate else { throw SophonProtocolError.unsupported("此游戏暂不支持 Sophon 更新") }
        }
        let root = try canonicalDestination(destination)
        try validateRoot(root)
        if case .install = mode, !fm.fileExists(atPath: root.path) {
            guard suppliedLock == nil else {
                throw SophonProtocolError.corrupt("游戏目录已变化，无法使用已有下载锁")
            }
            try fm.createDirectory(at: root, withIntermediateDirectories: true)
        }
        let directoryLock = try operationLock(at: root, holding: suppliedLock)
        defer { if suppliedLock == nil { directoryLock.release() } }
        guard !hasPendingTransaction(destination: root) else {
            throw SophonProtocolError.corrupt("发现未完成的安装事务，必须先恢复")
        }
        if case .install = mode, let completed = try readCommittedInstallReceipt(root: root, game: game) {
            return completed
        }
        switch mode {
        case .install:
            if fm.fileExists(atPath: root.path) {
                let contents = try fm.contentsOfDirectory(atPath: root.path)
                if !contents.isEmpty {
                    guard contents == [Self.resumeDirectoryName], try SophonResumeCache.isOwned(at: root, game: game) else {
                        throw SophonProtocolError.unsupported("安装目录必须为空")
                    }
                }
            } else { try fm.createDirectory(at: root, withIntermediateDirectories: true) }
        case .update, .updateConfirmedMainland:
            let confirmed: Bool
            if case .updateConfirmedMainland = mode { confirmed = true } else { confirmed = false }
            try verifyMainlandInstallation(game: game, root: root, confirmedMainland: confirmed)
        }
        await progress(.init(fractionCompleted: nil, message: "正在获取官方游戏清单", bytesCompleted: 0, bytesTotal: nil))
        let audioLanguages: Set<String>
        switch mode {
        case .install: audioLanguages = ["zh-cn"]
        case .update, .updateConfirmedMainland: audioLanguages = try installedAudioLanguages(game: game, root: root)
        }
        let build = try await metadata.fetchBuild(for: game, audioLanguages: audioLanguages)
        let (files, byPath) = try await loadFiles(build: build, root: root)
        var deletedFiles: [SophonDeletedFile] = []
        var sourceVersion = ""
        switch mode {
        case .install: break
        case .update, .updateConfirmedMainland:
            sourceVersion = try installedVersion(at: root)
            await progress(.init(fractionCompleted: nil, message: "正在检查旧版本资源", bytesCompleted: 0, bytesTotal: nil))
            deletedFiles = try await metadata.fetchDeletions(for: build, from: sourceVersion)
        }
        let work = root.appendingPathComponent(transactionName, isDirectory: true)
        let stagedRoot = work.appendingPathComponent("staged", isDirectory: true)
        let backupRoot = work.appendingPathComponent("backup", isDirectory: true)
        try fm.createDirectory(at: stagedRoot, withIntermediateDirectories: true)
        let operationMode: String
        if case .install = mode { operationMode = "install" } else { operationMode = "update" }
        var journal = Journal(version: 1, game: game, destination: root.path, committed: false,
                              operations: [], createdDirectories: [], installMode: operationMode, targetVersion: build.version)
        do { try saveJournal(journal, work: work) }
        catch { try? fm.removeItem(at: work); throw error }
        do {
        await progress(.init(fractionCompleted: nil, message: "正在检查已有游戏文件", bytesCompleted: 0, bytesTotal: nil))
        var needs: [(SophonFile, SophonCategory)] = []
        var originalHashes: [String: String] = [:]
        for (file, category) in files {
            try Task.checkCancellation()
            let target = try safeURL(root: root, path: file.path)
            if fm.fileExists(atPath: target.path) {
                let hash = try fileMD5(target)
                if hash == file.md5.lowercased() { continue }
                originalHashes[file.path] = hash
            }
            needs.append((file, category))
        }
        var obsolete: [SophonDeletedFile] = []
        var obsoleteByPath: [String: SophonDeletedFile] = [:]
        for file in deletedFiles {
            let key = file.path.lowercased()
            guard key != "config.ini", key != ".miplay-sophon-install.json", isMD5(file.md5) else {
                throw SophonProtocolError.corrupt("差分清单包含无效的删除目标")
            }
            let target = try safeURL(root: root, path: file.path)
            if byPath[key] != nil { continue }
            if let previous = obsoleteByPath[key] {
                guard previous == file else { throw SophonProtocolError.corrupt("差分清单包含冲突的删除目标") }
                continue
            }
            obsoleteByPath[key] = file
            guard fm.fileExists(atPath: target.path) else { continue }
            let attributes = try fm.attributesOfItem(atPath: target.path)
            guard (attributes[.size] as? NSNumber)?.uint64Value == file.size,
                  try fileMD5(target) == file.md5.lowercased() else {
                throw SophonProtocolError.corrupt("待删除的旧游戏文件已改变：\(file.path)")
            }
            obsolete.append(file)
        }
        let contextIdentity = try resumeContextIdentity(game: game, mode: operationMode, sourceVersion: sourceVersion, build: build)
        let cache = try SophonResumeCache.open(destination: root, game: game, identity: contextIdentity,
                                               filePaths: files.map { $0.0.path })
        var fullNeeds = needs
        var patchObjects: [SophonPatchObject] = []
        var patchBytes: UInt64 = 0
        if operationMode == "update", build.diffTags.contains(sourceVersion) {
            let patches = try await stageAvailablePatches(needs: needs, build: build, sourceVersion: sourceVersion,
                                                           cache: cache, root: root, work: work, stagedRoot: stagedRoot,
                                                           progress: progress)
            patchObjects = patches.objects
            patchBytes = patches.completedBytes
            fullNeeds.removeAll { patches.staged.contains($0.0.path.lowercased()) }
        }
        var total: Int64 = 0
        for (file, _) in fullNeeds { for chunk in file.chunks {
            guard chunk.compressedSize <= UInt64(Int64.max), total <= Int64.max - Int64(chunk.compressedSize) else { throw SophonProtocolError.corrupt("资源大小溢出") }
            total += Int64(chunk.compressedSize)
        }}
        let ownedCacheKeys = try await cacheDownloads(fullNeeds, cache: cache, stagedRoot: stagedRoot, total: total,
                                                      message: !patchObjects.isEmpty ? "正在下载完整资源（阶段进度）" : "正在下载游戏资源", progress: progress)
        guard patchBytes <= UInt64(Int64.max - total) else { throw SophonProtocolError.corrupt("资源大小溢出") }
        let completedTotal = total + Int64(patchBytes)
        let originalConfig: Data?
        switch mode {
        case .install: originalConfig = nil
        case .update, .updateConfirmedMainland:
            originalConfig = try Data(contentsOf: safeURL(root: root, path: "config.ini"))
        }
        let config = try updatedConfig(mode: mode, version: build.version,
                                       sourceVersion: sourceVersion, existing: originalConfig)
        let configStaged = try safeURL(root: stagedRoot, path: "config.ini")
        try config.write(to: configStaged, options: .atomic)
        var pending = needs.map { ($0.0.path, $0.0.md5.lowercased()) } + [("config.ini", SophonMetadataClient.md5(config))]
        if case .install = mode {
            let marker = try JSONEncoder().encode(InstallIdentity(game: game, region: "cn"))
            let markerPath = ".miplay-sophon-install.json"
            try marker.write(to: safeURL(root: stagedRoot, path: markerPath), options: .atomic)
            pending.append((markerPath, SophonMetadataClient.md5(marker)))
        }
        for (path, md5) in pending {
            let target = try safeURL(root: root, path: path)
            let original: String?
            if path == "config.ini" { original = originalConfig.map(SophonMetadataClient.md5) }
            else { original = originalHashes[path] }
            // A file which appeared during the download is user-owned until
            // proven otherwise; never promote it to an overwrite target.
            guard fm.fileExists(atPath: target.path) == (original != nil) else {
                throw SophonProtocolError.corrupt("目标文件在下载期间发生变化：\(path)")
            }
            journal.operations.append(Operation(path: path, hadExisting: original != nil, installedMD5: md5, deletion: nil, originalMD5: original))
            let parts = path.split(separator: "/")
            if parts.count > 1 {
                for count in 1..<parts.count {
                    let directory = parts.prefix(count).joined(separator: "/")
                    let url = try safeURL(root: root, path: directory)
                    if !fm.fileExists(atPath: url.path), !journal.createdDirectories.contains(directory) {
                        journal.createdDirectories.append(directory)
                    }
                }
            }
        }
        // Config must be last, so place transactional deletions immediately before it.
        let configIndex = journal.operations.firstIndex(where: { $0.path == "config.ini" }) ?? journal.operations.count
        journal.operations.insert(contentsOf: obsolete.map {
            Operation(path: $0.path, hadExisting: true, installedMD5: "", deletion: true, originalMD5: $0.md5.lowercased())
        }, at: configIndex)
        try saveJournal(journal, work: work)
        await progress(.init(fractionCompleted: 0, message: ScheduledTask.sophonCommitPhaseDescription,
                             bytesCompleted: 0, bytesTotal: nil))
        // Cancellation requested before this boundary must still roll back the
        // staged transaction. After it, the commit must run to completion.
        try Task.checkCancellation()
        // Commit intentionally has no cancellation point: cancellation between a
        // backup move and replacement would otherwise leave a partially updated game.
        do {
            var reportedPercent = 0
            for (index, op) in journal.operations.enumerated() {
                let target = try safeURL(root: root, path: op.path)
                let staged = try safeURL(root: stagedRoot, path: op.path)
                let backup = try safeURL(root: backupRoot, path: op.path)
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                if op.deletion != true {
                    guard try fileMD5(staged, honorCancellation: false, noFollow: true) == op.installedMD5 else {
                        throw SophonProtocolError.corrupt("暂存文件在提交前发生变化：\(op.path)")
                    }
                }
                if op.hadExisting {
                    if let original = op.originalMD5, try fileMD5(target, honorCancellation: false, noFollow: true) != original {
                        throw SophonProtocolError.corrupt("原游戏文件在提交前发生变化：\(op.path)")
                    }
                    try fm.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try fm.moveItem(at: target, to: backup)
                } else if fm.fileExists(atPath: target.path) {
                    throw SophonProtocolError.corrupt("目标路径在下载期间被占用：\(op.path)")
                }
                if op.deletion != true { try fm.moveItem(at: staged, to: target) }
                // Keep 100% for the final result: journal publication and
                // cache cleanup still follow the last file replacement.
                let percent = min(99, (index + 1) * 99 / journal.operations.count)
                if percent > reportedPercent {
                    reportedPercent = percent
                    await progress(.init(fractionCompleted: Double(percent) / 100,
                                         message: ScheduledTask.sophonCommitPhaseDescription,
                                         bytesCompleted: 0, bytesTotal: nil))
                }
            }
            journal.committed = true
            try saveJournal(journal, work: work)
            if case .install = mode { try publishCommittedInstallReceipt(journal, root: root, game: game) }
            try fm.removeItem(at: work)
            if !patchObjects.isEmpty, let patchCache = try? openPatchCache(cache) {
                _ = try? await patchCache.cleanup(objects: patchObjects)
            }
            try? cache.cleanup(ownedKeys: ownedCacheKeys)
        } catch {
            do { try recover(destination: root, game: game, holding: directoryLock) }
            catch { throw SophonProtocolError.corrupt("安装提交失败且自动恢复未完成：\(error.localizedDescription)") }
            throw error
        }
        // The scheduler still needs to persist the installed version and task
        // result. Keep cancellation disabled until that work is complete.
        await progress(.init(fractionCompleted: 0.99, message: ScheduledTask.sophonCommitPhaseDescription,
                             bytesCompleted: completedTotal, bytesTotal: completedTotal))
        return SophonInstallResult(version: build.version)
        } catch {
            do { try recover(destination: root, game: game, holding: directoryLock) }
            catch { throw SophonProtocolError.corrupt("下载失败且恢复未完成：\(error.localizedDescription)") }
            throw error
        }
    }

    /// Download a future release into the verified resume cache only. This is
    /// intentionally not a transaction: the live installation, its config and
    /// its current-version registration stay untouched until a later update.
    public func preDownload(game: GameType, destination: URL, confirmedMainland: Bool = false,
                            expectedVersion: String, holding suppliedLock: SophonDirectoryLock? = nil,
                            progress: @escaping @Sendable (SophonProgress) async -> Void) async throws -> SophonInstallResult {
        guard game.definition.contentCapabilities.sophonPredownload else {
            throw SophonProtocolError.unsupported("此游戏暂不支持 Sophon 预下载")
        }
        let root = try canonicalDestination(destination)
        try validateRoot(root)
        let directoryLock = try operationLock(at: root, holding: suppliedLock)
        defer { if suppliedLock == nil { directoryLock.release() } }
        guard !hasPendingTransaction(destination: root) else {
            throw SophonProtocolError.corrupt("游戏存在未完成的下载事务，请先恢复")
        }
        try verifyMainlandInstallation(game: game, root: root, confirmedMainland: confirmedMainland)
        let sourceVersion = try installedVersion(at: root)
        let audio = try installedAudioLanguages(game: game, root: root)
        await progress(.init(fractionCompleted: nil, message: "正在获取预下载清单", bytesCompleted: 0, bytesTotal: nil))
        guard let build = try await metadata.fetchPreDownloadBuild(for: game, audioLanguages: audio) else {
            throw SophonProtocolError.unsupported("当前没有可用的预下载版本")
        }
        guard build.version == expectedVersion,
              try SophonMetadataClient.compareVersions(build.version, sourceVersion) == .orderedDescending else {
            throw SophonProtocolError.unsupported("预下载版本已变化或已安装，请重新检查")
        }
        let (files, _) = try await loadFiles(build: build, root: root)
        await progress(.init(fractionCompleted: nil, message: "正在检查已有游戏文件（0/\(files.count)）", bytesCompleted: 0, bytesTotal: nil))
        var needs: [(SophonFile, SophonCategory)] = []
        var total: Int64 = 0
        var lastScanProgress = Date.distantPast
        for (index, entry) in files.enumerated() {
            let (file, category) = entry
            try Task.checkCancellation()
            let target = try safeURL(root: root, path: file.path)
            var matches = false
            if fm.fileExists(atPath: target.path) {
                do {
                    let attributes = try fm.attributesOfItem(atPath: target.path)
                    guard attributes[.type] as? FileAttributeType == .typeRegular,
                          let size = (attributes[.size] as? NSNumber)?.uint64Value else {
                        throw SophonProtocolError.unsupported("目标不是普通文件：\(file.path)")
                    }
                    // A different size can never match the official file;
                    // avoid reading many gigabytes that must be replaced.
                    if size == file.size { matches = try fileMD5(target) == file.md5.lowercased() }
                } catch is CancellationError {
                    throw CancellationError()
                } catch {
                    // A running launcher may temporarily move a file while it
                    // prepares the game. If it actually disappeared, cache
                    // the official replacement; preserve other errors.
                    guard !fm.fileExists(atPath: target.path) else { throw error }
                }
            }
            if !matches {
                needs.append((file, category))
                for chunk in file.chunks {
                    guard chunk.compressedSize <= UInt64(Int64.max), total <= Int64.max - Int64(chunk.compressedSize) else {
                        throw SophonProtocolError.corrupt("资源大小溢出")
                    }
                    total += Int64(chunk.compressedSize)
                }
            }
            let completed = index + 1
            if completed == files.count || Date().timeIntervalSince(lastScanProgress) >= 0.5 {
                lastScanProgress = Date()
                await progress(.init(fractionCompleted: nil, message: "正在检查已有游戏文件（\(completed)/\(files.count)）", bytesCompleted: 0, bytesTotal: nil))
            }
        }
        guard !needs.isEmpty else {
            await progress(.init(fractionCompleted: 1, message: "预下载资源已就绪", bytesCompleted: 0, bytesTotal: 0))
            return SophonInstallResult(version: build.version)
        }
        let identity = try resumeContextIdentity(game: game, mode: "update", sourceVersion: sourceVersion, build: build)
        let cache = try SophonResumeCache.open(destination: root, game: game, identity: identity,
                                               filePaths: files.map { $0.0.path })
        await progress(.init(fractionCompleted: nil, message: "正在检查可用差分资源", bytesCompleted: 0, bytesTotal: nil))
        let groups = try await planPatches(needs: needs, build: build, sourceVersion: sourceVersion, cache: cache, root: root)
        let patchCache = groups.isEmpty ? nil : try openPatchCache(cache)
        let plannedPaths = Set(groups.values.flatMap { $0.1.map { $0.file.path.lowercased() } })
        var estimatedRemaining: UInt64 = 0
        for (file, _) in needs where !plannedPaths.contains(file.path.lowercased()) {
            let remaining = try cache.estimatedRemainingBytes(for: file)
            guard estimatedRemaining <= UInt64.max - remaining else { throw SophonProtocolError.corrupt("预下载资源大小溢出") }
            estimatedRemaining += remaining
        }
        if let patchCache {
            for (_, (object, candidates)) in groups {
                let ranges = candidates.map { $0.patch.offset..<($0.patch.offset + $0.patch.length) }
                let remaining = try await patchCache.estimatedRemainingBytes(object, ranges: ranges)
                guard estimatedRemaining <= UInt64.max - remaining else { throw SophonProtocolError.corrupt("预下载资源大小溢出") }
                estimatedRemaining += remaining
            }
        }
        if estimatedRemaining > 0 { try checkPreDownloadSpace(at: root, required: estimatedRemaining) }
        var prepared = Set<String>()
        var patchBytes: UInt64 = 0
        if let patchCache {
            let plan = try await patchDownloadPlan(groups: groups, cache: patchCache)
            let availableBytes = preDownloadAvailableBytes
            var patchCompleted: UInt64 = 0
            for (index, group) in plan.groups.enumerated() {
                try Task.checkCancellation()
                let groupSize = group.selectedBytes
                let completedBefore = patchCompleted
                let totalBytes = plan.totalBytes
                let message = "正在预下载差分资源（阶段进度，\(index + 1)/\(plan.groups.count) 组）"
                await progress(.init(fractionCompleted: totalBytes == 0 ? nil : Double(completedBefore) / Double(totalBytes),
                                     message: message, bytesCompleted: Int64(completedBefore), bytesTotal: Int64(totalBytes)))
                let counter = SophonPatchProgressCounter()
                try await patchCache.download(group.object, ranges: group.ranges, beforeWrite: { required in
                        let free = try availableBytes(root)
                        guard free >= Self.preDownloadSpaceReserve,
                              required <= free - Self.preDownloadSpaceReserve else {
                            throw SophonProtocolError.unsupported("磁盘可用空间不足，预下载需要额外空间并保留至少 2 GiB；已下载的资源可以稍后继续")
                        }
                    }, progress: { completed in
                        await counter.record(min(completed, groupSize))
                        let current = completedBefore + min(completed, groupSize)
                        await progress(.init(fractionCompleted: totalBytes == 0 ? nil : Double(current) / Double(totalBytes),
                                             message: message, bytesCompleted: Int64(current), bytesTotal: Int64(totalBytes)))
                    })
                prepared.formUnion(group.candidates.map { $0.file.path.lowercased() })
                patchCompleted += await counter.value()
            }
            patchBytes = patchCompleted
        }
        let fullNeeds = needs.filter { !prepared.contains($0.0.path.lowercased()) }
        var fullRemaining: UInt64 = 0
        total = 0
        for (file, _) in fullNeeds {
            let remaining = try cache.estimatedRemainingBytes(for: file)
            guard fullRemaining <= UInt64.max - remaining else { throw SophonProtocolError.corrupt("预下载资源大小溢出") }
            fullRemaining += remaining
            for chunk in file.chunks {
                guard chunk.compressedSize <= UInt64(Int64.max), total <= Int64.max - Int64(chunk.compressedSize) else { throw SophonProtocolError.corrupt("资源大小溢出") }
                total += Int64(chunk.compressedSize)
            }
        }
        if fullRemaining > 0 { try checkPreDownloadSpace(at: root, required: fullRemaining) }
        _ = try await cacheDownloads(fullNeeds, cache: cache, stagedRoot: nil, total: total,
                                     message: !groups.isEmpty ? "正在预下载完整资源（阶段进度）" : "正在预下载游戏资源", progress: progress)
        guard patchBytes <= UInt64(Int64.max - total) else { throw SophonProtocolError.corrupt("资源大小溢出") }
        let completedTotal = total + Int64(patchBytes)
        await progress(.init(fractionCompleted: 1, message: "预下载缓存已就绪，正式更新时将校验资源", bytesCompleted: completedTotal, bytesTotal: completedTotal))
        return SophonInstallResult(version: build.version)
    }

    func installedVersion(at root: URL) throws -> String {
        let config = try String(contentsOf: safeURL(root: root, path: "config.ini"), encoding: .utf8)
        let values = config.components(separatedBy: .newlines).compactMap { line -> String? in
            let pair = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            return pair.count == 2 && pair[0].lowercased() == "game_version" ? pair[1] : nil
        }
        guard values.count == 1, !values[0].isEmpty else { throw SophonProtocolError.corrupt("游戏配置缺少唯一版本号") }
        return values[0]
    }

    func resumeContextIdentity(game: GameType, mode: String, sourceVersion: String, build: SophonBuild) throws -> String {
        let identity = ResumeIdentity(game: game, region: "cn", mode: mode, sourceVersion: sourceVersion,
                                      targetVersion: build.version,
                                      manifests: build.categories.map { "\($0.categoryID):\($0.manifestMD5)" }.sorted())
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let value = String(data: try encoder.encode(identity), encoding: .utf8) else {
            throw SophonProtocolError.corrupt("无法生成续传上下文")
        }
        return value
    }

    func loadFiles(build: SophonBuild, root: URL) async throws -> ([(SophonFile, SophonCategory)], [String: SophonFile]) {
        var files: [(SophonFile, SophonCategory)] = []
        var byPath: [String: SophonFile] = [:]
        for category in build.categories {
            try Task.checkCancellation()
            let manifest = try await metadata.downloadManifest(category)
            for file in manifest {
                _ = try safeURL(root: root, path: file.path)
                guard file.flags == 0 || file.flags == 64 else { throw SophonProtocolError.unsupported("未知文件类型：\(file.path)") }
                if file.flags == 64 { continue }
                try validateFile(file)
                let key = file.path.lowercased()
                if let existing = byPath[key] {
                    guard existing == file else { throw SophonProtocolError.corrupt("资源分类中的文件冲突：\(file.path)") }
                } else {
                    byPath[key] = file
                    files.append((file, category))
                }
            }
        }
        guard !files.isEmpty else { throw SophonProtocolError.corrupt("游戏清单为空") }
        guard byPath["config.ini"] == nil, byPath[".miplay-sophon-install.json"] == nil else {
            throw SophonProtocolError.corrupt("游戏清单包含受保护的配置文件")
        }
        return (files, byPath)
    }

    private struct PatchCandidate {
        let file: SophonFile
        let patch: SophonPatchFile
    }
    private typealias PatchGroups = [String: (SophonPatchObject, [PatchCandidate])]

    private struct PatchDownloadGroup {
        let object: SophonPatchObject
        let candidates: [PatchCandidate]
        let ranges: [Range<UInt64>]
        let selectedBytes: UInt64
    }

    private struct PatchDownloadPlan {
        let groups: [PatchDownloadGroup]
        let totalBytes: UInt64
    }

    /// Sort and size the selected cache segments identically for pre-download
    /// and update. Overlapping ranges are counted once by the cache.
    private func patchDownloadPlan(groups: PatchGroups, cache: SophonPatchCache) async throws -> PatchDownloadPlan {
        var planned: [PatchDownloadGroup] = []
        var total: UInt64 = 0
        for (_, (object, candidates)) in groups.sorted(by: { $0.key < $1.key }) {
            let ranges = candidates.map { $0.patch.offset..<($0.patch.offset + $0.patch.length) }
            let size = try await cache.selectedBytes(object, ranges: ranges)
            guard size <= UInt64(Int64.max), total <= UInt64(Int64.max) - size else {
                throw SophonProtocolError.corrupt("差分资源大小溢出")
            }
            total += size
            planned.append(PatchDownloadGroup(object: object, candidates: candidates, ranges: ranges, selectedBytes: size))
        }
        return PatchDownloadPlan(groups: planned, totalBytes: total)
    }

    /// Both pre-download and update use the same source and FULL manifest
    /// validation and the same cache identity. A complete FULL cache wins.
    private func planPatches(needs: [(SophonFile, SophonCategory)], build: SophonBuild,
                             sourceVersion: String, cache: SophonResumeCache, root: URL) async throws -> PatchGroups {
        guard build.diffTags.contains(sourceVersion) else { return [:] }
        // A fully verified FULL cache needs no patch metadata. In particular,
        // a temporary patch service failure must not prevent its reuse.
        var uncached: [(SophonFile, SophonCategory)] = []
        for entry in needs {
            try Task.checkCancellation()
            if try !hasVerifiedFullCache(entry.0, cache: cache) { uncached.append(entry) }
        }
        guard !uncached.isEmpty else { return [:] }
        // Failure to fetch or validate a declared patch is not evidence that
        // a FULL download is necessary. Surface it so retry can reuse cache
        // instead of silently increasing the user's network traffic.
        let categories = try await patchClient.fetch(build: build, from: sourceVersion)
        var byCategory: [String: [String: SophonPatchFile]] = [:]
        for category in categories {
            guard byCategory[category.id] == nil else { throw SophonProtocolError.corrupt("差分资源分类重复") }
            byCategory[category.id] = Dictionary(uniqueKeysWithValues: category.files.map { ($0.path.lowercased(), $0) })
        }
        var groups: PatchGroups = [:]
        for (file, category) in uncached {
            try Task.checkCancellation()
            guard let patchCategory = categories.first(where: { $0.id == category.id }),
                  let patch = byCategory[category.id]?[file.path.lowercased()],
                  patch.size == file.size, patch.md5.lowercased() == file.md5.lowercased() else { continue }
            if let original = patch.originalPath {
                let protected = original.lowercased()
                guard protected != "config.ini", protected != ".miplay-sophon-install.json" else { continue }
                let source = try safeURL(root: root, path: original)
                guard fm.fileExists(atPath: source.path) else { continue }
                let attrs = try fm.attributesOfItem(atPath: source.path)
                guard (attrs[.size] as? NSNumber)?.uint64Value == patch.originalSize else { continue }
                // No need to fetch an object that cannot apply to this source.
                guard try fileMD5(source) == patch.originalMD5 else { continue }
            } else if patch.originalSize != 0 || patch.originalMD5 != nil { continue }
            let object = SophonPatchObject(file: patch, category: patchCategory)
            let key = "\(object.prefix.absoluteString)\n\(object.id)\n\(object.size)"
            if groups[key] == nil { groups[key] = (object, []) }
            groups[key]!.1.append(PatchCandidate(file: file, patch: patch))
        }
        return groups
    }

    func hasVerifiedFullCache(_ file: SophonFile, cache: SophonResumeCache) throws -> Bool {
        guard try cache.estimatedRemainingBytes(for: file) == 0 else { return false }
        let location = try cache.locations(for: file.path)
        guard fm.fileExists(atPath: location.data.path) else { return false }
        let checkpoint = try cache.checkpoint(at: location.checkpoint, key: location.key,
                                              count: file.chunks.count, dataExists: true)
        let reader = try StreamingFileHasher<Insecure.MD5>(path: location.data.path)
        defer { reader.close() }
        for (index, chunk) in file.chunks.enumerated() {
            try Task.checkCancellation()
            guard checkpoint.contains(index) else { return false }
            let result = try reader.hash(offset: chunk.offset, length: chunk.uncompressedSize)
            guard result.bytes == chunk.uncompressedSize, result.digest == chunk.md5.lowercased() else { return false }
        }
        return true
    }

    func openPatchCache(_ cache: SophonResumeCache) throws -> SophonPatchCache {
        let directory = cache.context.appendingPathComponent("patches", isDirectory: true)
        if Darwin.mkdir(directory.path, mode_t(0o700)) != 0 && errno != EEXIST {
            throw SophonProtocolError.corrupt("无法创建差分缓存目录")
        }
        var info = stat()
        guard lstat(directory.path, &info) == 0, (info.st_mode & S_IFMT) == S_IFDIR else {
            throw SophonProtocolError.corrupt("差分缓存目录不安全")
        }
        return SophonPatchCache(root: directory, session: session)
    }

    /// Stage patch results into the same transaction as FULL downloads.
    private func stageAvailablePatches(needs: [(SophonFile, SophonCategory)], build: SophonBuild,
                                       sourceVersion: String, cache: SophonResumeCache,
                                       root: URL, work: URL, stagedRoot: URL,
                                       progress: @escaping @Sendable (SophonProgress) async -> Void) async throws -> (staged: Set<String>, objects: [SophonPatchObject], completedBytes: UInt64) {
        let groups = try await planPatches(needs: needs, build: build, sourceVersion: sourceVersion, cache: cache, root: root)
        guard !groups.isEmpty else { return ([], [], 0) }
        let patchCache = try openPatchCache(cache)
        var staged = Set<String>()
        let plan = try await patchDownloadPlan(groups: groups, cache: patchCache)
        var patchCompleted: UInt64 = 0
        for group in plan.groups {
            try Task.checkCancellation()
            let groupSize = group.selectedBytes
            let completedBefore = patchCompleted
            let totalBytes = plan.totalBytes
            await progress(.init(fractionCompleted: totalBytes == 0 ? nil : Double(completedBefore) / Double(totalBytes),
                                 message: "正在下载差分补丁（阶段进度）", bytesCompleted: Int64(completedBefore), bytesTotal: Int64(totalBytes)))
            let counter = SophonPatchProgressCounter()
            try await patchCache.download(group.object, ranges: group.ranges, progress: { completed in
                    await counter.record(min(completed, groupSize))
                    let current = completedBefore + min(completed, groupSize)
                    await progress(.init(fractionCompleted: totalBytes == 0 ? nil : Double(current) / Double(totalBytes),
                                         message: "正在下载差分补丁（阶段进度）", bytesCompleted: Int64(current), bytesTotal: Int64(totalBytes)))
                })
            patchCompleted += await counter.value()
            await progress(.init(fractionCompleted: nil, message: "正在验证并应用差分补丁", bytesCompleted: 0, bytesTotal: nil))
            var failedRanges: [Range<UInt64>] = []
            for candidate in group.candidates {
                try Task.checkCancellation()
                let range = candidate.patch.offset..<(candidate.patch.offset + candidate.patch.length)
                let temporary = work.appendingPathComponent(".patch-slice-\(UUID().uuidString)")
                try createResumeFile(temporary)
                defer { try? fm.removeItem(at: temporary) }
                let handle = try openResumeFile(temporary, writing: true)
                do { try await patchCache.copy(group.object, range: range, to: handle); try handle.close() }
                catch { try? handle.close(); throw error }
                let source: URL
                var emptySource: URL?
                if let path = candidate.patch.originalPath { source = try safeURL(root: root, path: path) }
                else {
                    source = work.appendingPathComponent(".patch-empty-\(UUID().uuidString)")
                    try createResumeFile(source)
                    emptySource = source
                }
                defer { if let emptySource { try? fm.removeItem(at: emptySource) } }
                let output = try safeURL(root: stagedRoot, path: candidate.file.path)
                try fm.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
                if try stagePatch(source: source, diff: temporary, output: output, entry: candidate.patch, diffOffset: 0) {
                    staged.insert(candidate.file.path.lowercased())
                } else { failedRanges.append(range) }
            }
            if !failedRanges.isEmpty { try? await patchCache.invalidate(group.object, ranges: failedRanges) }
        }
        return (staged, groups.values.map(\.0), patchCompleted)
    }

    /// Creates a new transaction-owned file and verifies both inputs and the
    /// result. A false result means the caller must use the FULL resource.
    internal func stagePatch(source: URL, diff: URL, output: URL, entry: SophonPatchFile,
                             diffOffset: UInt64? = nil) throws -> Bool {
        try Task.checkCancellation()
        let oldFD = Darwin.open(source.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard oldFD >= 0 else {
            if errno == ENOENT { return false }
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        defer { Darwin.close(oldFD) }
        let diffFD = Darwin.open(diff.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard diffFD >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(diffFD) }
        var oldInfo = stat()
        guard fstat(oldFD, &oldInfo) == 0, (oldInfo.st_mode & S_IFMT) == S_IFREG,
              oldInfo.st_size >= 0, UInt64(oldInfo.st_size) == entry.originalSize else { return false }
        let expectedSource = entry.originalMD5 ?? SophonMetadataClient.md5(Data())
        guard try fileMD5(source) == expectedSource else { return false }
        try createResumeFile(output)
        var success = false
        defer { if !success { try? fm.removeItem(at: output) } }
        let outputHandle = try openResumeFile(output, writing: true)
        do {
            let offset = diffOffset ?? entry.offset
            var usedRawFile = false
            // A new-file entry can store the complete target directly in the
            // patch object, rather than wrapping it in HDIFF13. Authenticate
            // the exact bounded range before treating it as a staged result.
            if entry.originalPath == nil, entry.originalMD5 == nil, entry.originalSize == 0,
               entry.length == entry.size {
                var diffInfo = stat()
                guard fstat(diffFD, &diffInfo) == 0, (diffInfo.st_mode & S_IFMT) == S_IFREG,
                      diffInfo.st_size >= 0, offset <= UInt64(diffInfo.st_size),
                      entry.length <= UInt64(diffInfo.st_size) - offset else { return false }
                let input = FileHandle(fileDescriptor: diffFD, closeOnDealloc: false)
                try input.seek(toOffset: offset)
                var remaining = entry.length
                var hash = Insecure.MD5()
                while remaining > 0 {
                    try Task.checkCancellation()
                    let copied = try autoreleasepool {
                        guard let data = try input.read(upToCount: Int(min(remaining, 1024 * 1024))), !data.isEmpty else {
                            return 0
                        }
                        hash.update(data: data)
                        try outputHandle.write(contentsOf: data)
                        return data.count
                    }
                    guard copied > 0 else { return false }
                    remaining -= UInt64(copied)
                }
                let digest = hash.finalize().map { String(format: "%02x", $0) }.joined()
                usedRawFile = digest == entry.md5.lowercased()
                if !usedRawFile {
                    // It may instead be an HDIFF13 patch whose encoded length
                    // happens to equal the target size.
                    try outputHandle.truncate(atOffset: 0)
                    try outputHandle.seek(toOffset: 0)
                }
            }
            if !usedRawFile {
                try SophonHDiff.apply(oldFD: oldFD, diffFD: diffFD, outputFD: outputHandle.fileDescriptor,
                                      offset: offset, length: entry.length,
                                      oldSize: entry.originalSize, newSize: entry.size)
            }
            try outputHandle.synchronize()
            try outputHandle.close()
            try Task.checkCancellation()
            guard try fileMD5(source) == expectedSource, try fileMD5(output) == entry.md5.lowercased() else { return false }
            success = true
            return true
        } catch is CancellationError { try? outputHandle.close(); throw CancellationError() }
        catch SophonHDiff.Error.invalidOrUnsupportedPatch { try? outputHandle.close(); try Task.checkCancellation(); return false }
        catch { try? outputHandle.close(); throw error }
    }

    /// Fill the same verified cache for pre-download and ordinary updates.
    /// Only an update supplies a staging root; pre-download never links or
    /// writes into the live game or its commit transaction.
    func cacheDownloads(_ needs: [(SophonFile, SophonCategory)], cache: SophonResumeCache,
                                stagedRoot: URL?, total: Int64, message: String,
                                spaceCheck: (@Sendable (UInt64) async throws -> Void)? = nil,
                                progress: @escaping @Sendable (SophonProgress) async -> Void) async throws -> Set<String> {
        var ownedCacheKeys = Set<String>()
        var completed: Int64 = 0
        var lastProgress = Date.distantPast
        for (file, category) in needs {
            try Task.checkCancellation()
            let location = try cache.locations(for: file.path)
            let dataExists = fm.fileExists(atPath: location.data.path)
            var checkpoint = try cache.checkpoint(at: location.checkpoint, key: location.key, count: file.chunks.count, dataExists: dataExists)
            if !dataExists { try createResumeFile(location.data) }
            ownedCacheKeys.insert(location.key)
            var pendingChunks: [(Int, SophonChunk)] = []
            let completedBeforeReuse = completed
            let reader = try StreamingFileHasher<Insecure.MD5>(path: location.data.path)
            do {
                for (index, chunk) in file.chunks.enumerated() {
                    try Task.checkCancellation()
                    guard checkpoint.contains(index) else { pendingChunks.append((index, chunk)); continue }
                    let result = try reader.hash(offset: chunk.offset, length: chunk.uncompressedSize)
                    if result.bytes == chunk.uncompressedSize,
                       result.digest == chunk.md5.lowercased() {
                        completed += Int64(chunk.compressedSize)
                    } else {
                        checkpoint.set(index, false)
                        pendingChunks.append((index, chunk))
                    }
                }
                reader.close()
            } catch { reader.close(); throw error }
            if completed > completedBeforeReuse && Date().timeIntervalSince(lastProgress) >= 0.5 {
                lastProgress = Date()
                await progress(.init(fractionCompleted: total == 0 ? nil : Double(completed) / Double(total), message: message, bytesCompleted: completed, bytesTotal: total))
            }
            let currentSize = (try fm.attributesOfItem(atPath: location.data.path)[.size] as? NSNumber)?.uint64Value
            if !pendingChunks.isEmpty || currentSize != file.size {
            let handle = try openResumeFile(location.data, writing: true)
            do {
                var next = 0
                while next < pendingChunks.count {
                    try Task.checkCancellation()
                    var batch: [(Int, SophonChunk)] = []
                    var expectedMemory: UInt64 = 0
                    while next < pendingChunks.count && batch.count < 4 {
                        let chunk = pendingChunks[next].1
                        let memory = chunk.compressedSize + chunk.uncompressedSize
                        if !batch.isEmpty && expectedMemory + memory > 64 * 1024 * 1024 { break }
                        batch.append(pendingChunks[next])
                        expectedMemory += memory
                        next += 1
                    }
                    if stagedRoot == nil {
                        let required = batch.reduce(UInt64(0)) { $0 + $1.1.uncompressedSize }
                        try checkPreDownloadSpace(at: cache.root, required: required)
                    }
                    if let spaceCheck {
                        try await spaceCheck(batch.reduce(UInt64(0)) { $0 + $1.1.uncompressedSize })
                    }
                    let client = metadata
                    let results = try await withThrowingTaskGroup(of: (Int, Data).self) { group in
                        for (position, entry) in batch.enumerated() {
                            group.addTask { (position, try await Self.downloadChunk(entry.1, category: category, client: client)) }
                        }
                        var collected: [(Int, Data)] = []
                        for try await result in group { collected.append(result) }
                        return collected.sorted { $0.0 < $1.0 }
                    }
                    if stagedRoot == nil {
                        let required = batch.reduce(UInt64(0)) { $0 + $1.1.uncompressedSize }
                        try checkPreDownloadSpace(at: cache.root, required: required)
                    }
                    if let spaceCheck {
                        try await spaceCheck(batch.reduce(UInt64(0)) { $0 + $1.1.uncompressedSize })
                    }
                    for (position, data) in results {
                        let (index, chunk) = batch[position]
                        try autoreleasepool {
                            try handle.seek(toOffset: chunk.offset)
                            try handle.write(contentsOf: data)
                        }
                        checkpoint.set(index, true)
                        completed += Int64(chunk.compressedSize)
                    }
                    // A checkpoint never claims bytes that were not flushed.
                    try handle.synchronize()
                    try cache.save(checkpoint, to: location.checkpoint)
                    if Date().timeIntervalSince(lastProgress) >= 0.5 {
                        lastProgress = Date()
                        await progress(.init(fractionCompleted: total == 0 ? nil : Double(completed) / Double(total), message: message, bytesCompleted: completed, bytesTotal: total))
                    }
                }
                try handle.truncate(atOffset: file.size)
                try handle.synchronize()
                try handle.close()
            } catch { try? handle.close(); throw error }
            }
            guard try fileMD5(location.data) == file.md5.lowercased() else { throw SophonProtocolError.corrupt("游戏文件校验失败：\(file.path)") }
            if let stagedRoot {
                let staged = try safeURL(root: stagedRoot, path: file.path)
                try fm.createDirectory(at: staged.deletingLastPathComponent(), withIntermediateDirectories: true)
                // Refuse to share an inode with an unrelated external file.
                let unique = try openResumeFile(location.data, writing: true)
                try unique.close()
                do { try fm.linkItem(at: location.data, to: staged) }
                catch {
                    guard !fm.fileExists(atPath: staged.path) else { throw error }
                    if let spaceCheck { try await spaceCheck(file.size) }
                    try fm.copyItem(at: location.data, to: staged)
                }
            }
        }
        return ownedCacheKeys
    }

    private func checkPreDownloadSpace(at root: URL, required: UInt64) throws {
        let free = try preDownloadAvailableBytes(root)
        guard free >= Self.preDownloadSpaceReserve,
              required <= free - Self.preDownloadSpaceReserve else {
            throw SophonProtocolError.unsupported("磁盘可用空间不足，预下载需要额外空间并保留至少 2 GiB；已下载的资源可以稍后继续")
        }
    }

    /// Resolve OS-level aliases such as /var before checking files below the
    /// authorized game root. Foundation standardization maps /private/var
    /// back to /var, so use realpath to obtain the physical ancestor.
    func canonicalDestination(_ destination: URL) throws -> URL {
        guard destination.isFileURL else { throw SophonProtocolError.unsupported("游戏目录无效") }
        var current = destination.standardizedFileURL
        var missing: [String] = []
        while !fm.fileExists(atPath: current.path) {
            guard current.path != "/", !current.lastPathComponent.isEmpty else {
                throw SophonProtocolError.unsupported("找不到游戏目录的现有父目录")
            }
            missing.append(current.lastPathComponent)
            current.deleteLastPathComponent()
        }
        guard let raw = realpath(current.path, nil) else {
            throw SophonProtocolError.unsupported("无法解析游戏目录")
        }
        defer { free(raw) }
        var result = URL(fileURLWithPath: String(cString: raw), isDirectory: true)
        for part in missing.reversed() { result.appendPathComponent(part, isDirectory: true) }
        return result
    }

    func validateRoot(_ root: URL) throws {
        guard root.isFileURL, root.path != "/" else { throw SophonProtocolError.unsupported("游戏目录无效") }
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        for component in root.pathComponents.dropFirst() {
            current.appendPathComponent(component, isDirectory: true)
            if let attrs = try? fm.attributesOfItem(atPath: current.path),
               let type = attrs[.type] as? FileAttributeType, type == .typeSymbolicLink {
                throw SophonProtocolError.unsupported("游戏路径包含符号链接")
            }
        }
    }

    func safeURL(root: URL, path: String) throws -> URL {
        guard !path.isEmpty, !path.hasPrefix("/"), !path.contains("\\"), !path.contains("\0") else {
            throw SophonProtocolError.corrupt("清单包含非法文件路径")
        }
        let components = path.split(separator: "/", omittingEmptySubsequences: false)
        guard components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              components.first?.lowercased() != transactionName.lowercased(),
              components.first?.lowercased() != Self.resumeDirectoryName.lowercased() else {
            throw SophonProtocolError.corrupt("清单包含不安全的文件路径")
        }
        var result = root
        for part in components {
            result.appendPathComponent(String(part))
            if let attrs = try? fm.attributesOfItem(atPath: result.path),
               let type = attrs[.type] as? FileAttributeType, type == .typeSymbolicLink {
                throw SophonProtocolError.unsupported("游戏路径包含符号链接：\(path)")
            }
        }
        return result
    }

    private func validateFile(_ file: SophonFile) throws {
        guard isMD5(file.md5), file.size <= UInt64(Int64.max) else { throw SophonProtocolError.corrupt("清单包含无效的文件校验信息") }
        var end: UInt64 = 0
        for chunk in file.chunks.sorted(by: { $0.offset < $1.offset }) {
            guard !chunk.name.isEmpty, !chunk.name.contains("/"), !chunk.name.contains("\\"),
                  chunk.name != ".", chunk.name != "..", isMD5(chunk.md5),
                  chunk.uncompressedSize <= 512 * 1024 * 1024,
                  chunk.compressedSize <= 512 * 1024 * 1024,
                  chunk.offset == end, chunk.uncompressedSize <= UInt64.max - end else {
                throw SophonProtocolError.corrupt("清单包含无效的文件分块：\(file.path)")
            }
            end += chunk.uncompressedSize
        }
        guard end == file.size else { throw SophonProtocolError.corrupt("文件分块长度不一致：\(file.path)") }
    }

    nonisolated private static func downloadChunk(_ chunk: SophonChunk, category: SophonCategory,
                                                  client: SophonMetadataClient) async throws -> Data {
        let urlString = category.chunkPrefix.appendingPathComponent(chunk.name).absoluteString + category.chunkSuffix
        guard let url = URL(string: urlString) else { throw SophonProtocolError.corrupt("无效的分块地址") }
        var lastError: Error = SophonProtocolError.invalidResponse("分块下载失败")
        for attempt in 0..<3 {
            do {
                try Task.checkCancellation()
                let compressed = try await client.download(url)
                guard UInt64(compressed.count) == chunk.compressedSize else { throw SophonProtocolError.corrupt("下载分块长度不符") }
                return try autoreleasepool {
                    let data = try SophonZstd.decompress(compressed, expectedSize: Int(chunk.uncompressedSize))
                    guard SophonMetadataClient.md5(data) == chunk.md5.lowercased() else { throw SophonProtocolError.corrupt("下载分块校验失败") }
                    return data
                }
            } catch is CancellationError { throw CancellationError() }
            catch {
                try Task.checkCancellation()
                lastError = error
                if attempt < 2 { try await Task.sleep(for: .seconds(1 << attempt)) }
            }
        }
        throw lastError
    }

    private func isMD5(_ value: String) -> Bool {
        value.utf8.count == 32 && value.utf8.allSatisfy { (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) }
    }

    func fileMD5(_ url: URL, honorCancellation: Bool = true, noFollow: Bool = false) throws -> String {
        _ = noFollow // Sophon paths must never follow the final symlink.
        let reader = try StreamingFileHasher<Insecure.MD5>(path: url.path)
        defer { reader.close() }
        return try reader.hash(honorCancellation: honorCancellation).digest
    }

    /// Do not follow a cache symlink or mutate a hard-linked installed/user
    /// file if a crash occurred after the commit but before cache cleanup.
    func openResumeFile(_ url: URL, writing: Bool) throws -> FileHandle {
        let descriptor = Darwin.open(url.path, (writing ? O_RDWR : O_RDONLY) | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard descriptor >= 0 else { throw SophonProtocolError.corrupt("无法安全打开续传缓存文件") }
        var info = stat()
        guard fstat(descriptor, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG,
              !writing || info.st_nlink == 1 else {
            Darwin.close(descriptor)
            throw SophonProtocolError.corrupt("续传缓存文件不是可安全写入的独立文件")
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }

    func createResumeFile(_ url: URL) throws {
        let descriptor = Darwin.open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
        guard descriptor >= 0 else { throw SophonProtocolError.corrupt("无法安全创建续传缓存文件") }
        Darwin.close(descriptor)
    }

    private func saveJournal(_ journal: Journal, work: URL) throws {
        let destination = work.appendingPathComponent("journal.json")
        try JSONEncoder().encode(journal).write(to: destination, options: .atomic)
        let handle = try FileHandle(forWritingTo: destination)
        defer { try? handle.close() }
        try handle.synchronize()
    }

    private func readInstallReceiptBytes(root: URL, game: GameType) throws -> Data? {
        guard try SophonResumeCache.isOwned(at: root, game: game) else { return nil }
        let url = root.appendingPathComponent(Self.resumeDirectoryName, isDirectory: true)
            .appendingPathComponent(installReceiptName)
        guard (try? fm.attributesOfItem(atPath: url.path)) != nil else { return nil }
        let handle = try openResumeFile(url, writing: false)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        guard size > 0, size <= 64 * 1024 * 1024 else { throw SophonProtocolError.corrupt("已提交安装凭据大小无效") }
        try handle.seek(toOffset: 0)
        guard let bytes = try handle.readToEnd(), bytes.count == Int(size) else {
            throw SophonProtocolError.corrupt("已提交安装凭据读取失败")
        }
        return bytes
    }

    private func receiptDigest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private func publishCommittedInstallReceipt(_ journal: Journal, root: URL, game: GameType) throws {
        try SophonResumeCache.ensureOwnedRoot(destination: root, game: game)
        let cacheRoot = root.appendingPathComponent(Self.resumeDirectoryName, isDirectory: true)
        let receipt = cacheRoot.appendingPathComponent(installReceiptName)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(journal)
        let digest = receiptDigest(data)
        if let existing = try readInstallReceiptBytes(root: root, game: game) {
            guard receiptDigest(existing) == digest else {
                throw SophonProtocolError.corrupt("已有不同的安装凭据，已保留供恢复")
            }
        } else {
            let temporary = cacheRoot.appendingPathComponent(".install-receipt-\(UUID().uuidString).tmp")
            let descriptor = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode_t(0o600))
            guard descriptor >= 0 else { throw SophonProtocolError.corrupt("无法安全创建安装凭据") }
            defer { _ = Darwin.unlink(temporary.path) }
            let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
            do {
                try handle.write(contentsOf: data)
                try handle.synchronize()
                try handle.close()
            } catch { try? handle.close(); throw error }
            guard Darwin.link(temporary.path, receipt.path) == 0 else {
                throw SophonProtocolError.corrupt("安装凭据已存在或无法安全提交")
            }
            try synchronizeDirectory(cacheRoot)
        }
        receiptAuthorization = ReceiptAuthorization(destination: root.path, game: game, digest: digest)
    }

    private func readCommittedInstallReceipt(root: URL, game: GameType) throws -> SophonInstallResult? {
        guard let data = try readInstallReceiptBytes(root: root, game: game) else { return nil }
        let journal = try JSONDecoder().decode(Journal.self, from: data)
        guard journal.version == 1, journal.game == game, journal.committed,
              journal.installMode == "install", let version = journal.targetVersion,
              try canonicalDestination(URL(fileURLWithPath: journal.destination, isDirectory: true)).path == root.path else {
            throw SophonProtocolError.corrupt("已提交安装凭据与游戏目录不匹配")
        }
        try verifyCommittedInstall(journal, root: root, game: game, version: version)
        receiptAuthorization = ReceiptAuthorization(destination: root.path, game: game, digest: receiptDigest(data))
        return SophonInstallResult(version: version)
    }

    /// Acknowledge only a receipt validated or published by this installer
    /// instance. Call after registry and version persistence have succeeded.
    public func finalizeCommittedInstall(destination: URL, game: GameType, holding suppliedLock: SophonDirectoryLock? = nil) throws {
        let root = try canonicalDestination(destination)
        try validateRoot(root)
        let directoryLock = try operationLock(at: root, holding: suppliedLock)
        defer { if suppliedLock == nil { directoryLock.release() } }
        guard let authorization = receiptAuthorization, authorization.destination == root.path,
              authorization.game == game, let data = try readInstallReceiptBytes(root: root, game: game),
              receiptDigest(data) == authorization.digest else {
            throw SophonProtocolError.corrupt("安装凭据未验证或已变化，无法确认登记")
        }
        let directory = root.appendingPathComponent(Self.resumeDirectoryName, isDirectory: true)
        let receipt = directory.appendingPathComponent(installReceiptName)
        // Open with O_NOFOLLOW and ensure the path still names the same inode
        // immediately before unlinking it.
        let descriptor = Darwin.open(receipt.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw SophonProtocolError.corrupt("安装凭据无法安全打开") }
        defer { Darwin.close(descriptor) }
        var opened = stat(), named = stat()
        guard fstat(descriptor, &opened) == 0, opened.st_size > 0, opened.st_size <= 64 * 1024 * 1024 else {
            throw SophonProtocolError.corrupt("安装凭据大小无效")
        }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
        guard let openedBytes = try handle.readToEnd(), openedBytes.count == Int(opened.st_size),
              receiptDigest(openedBytes) == authorization.digest,
              lstat(receipt.path, &named) == 0,
              (opened.st_mode & S_IFMT) == S_IFREG, (named.st_mode & S_IFMT) == S_IFREG,
              opened.st_dev == named.st_dev, opened.st_ino == named.st_ino,
              Darwin.unlink(receipt.path) == 0 else {
            throw SophonProtocolError.corrupt("安装凭据发生变化，已停止清理")
        }
        // The game registration already committed before this cleanup. Some
        // external filesystems do not support directory fsync; a successfully
        // removed receipt must not turn a completed installation into failure.
        try? synchronizeDirectory(directory)
        receiptAuthorization = nil
        // Other version namespaces and unknown content are deliberately kept.
        try? SophonResumeCache.cleanupEmptyOwnedRoot(destination: root, game: game)
    }

    private func synchronizeDirectory(_ directory: URL) throws {
        let descriptor = Darwin.open(directory.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw SophonProtocolError.corrupt("无法打开安装凭据目录") }
        defer { Darwin.close(descriptor) }
        guard fsync(descriptor) == 0 else { throw SophonProtocolError.corrupt("无法确认安装凭据已写入磁盘") }
    }

    /// A completed initial install may have been interrupted before the game
    /// registry persisted it. Revalidate every recorded target and the
    /// mandatory mainland identity before returning an install result.
    private func verifyCommittedInstall(_ journal: Journal, root: URL, game: GameType, version: String) throws {
        guard !version.isEmpty, version.utf8.allSatisfy({ (48...57).contains($0) || $0 == 46 }) else {
            throw SophonProtocolError.corrupt("已提交安装的版本记录无效")
        }
        let executable = game.definition.mainlandExecutableName.lowercased()
        var seen = Set<String>()
        for operation in journal.operations {
            let key = operation.path.lowercased()
            guard seen.insert(key).inserted, operation.deletion != true,
                  !operation.hadExisting, operation.originalMD5 == nil,
                  isMD5(operation.installedMD5) else {
                throw SophonProtocolError.corrupt("已提交安装的操作记录无效")
            }
            let target = try safeURL(root: root, path: operation.path)
            guard fm.fileExists(atPath: target.path),
                  try fileMD5(target, honorCancellation: false) == operation.installedMD5.lowercased() else {
                throw SophonProtocolError.corrupt("已提交安装的文件校验失败：\(operation.path)")
            }
        }
        guard seen.isSuperset(of: [executable, "config.ini", ".miplay-sophon-install.json"]) else {
            throw SophonProtocolError.corrupt("已提交安装缺少必要文件记录")
        }
        let markerURL = try safeURL(root: root, path: ".miplay-sophon-install.json")
        let marker = try JSONDecoder().decode(InstallIdentity.self, from: Data(contentsOf: markerURL))
        guard marker.game == game, marker.region == "cn" else { throw SophonProtocolError.corrupt("已提交安装的游戏来源无效") }
        let configURL = try safeURL(root: root, path: "config.ini")
        let config = try String(contentsOf: configURL, encoding: .utf8)
        let versions = config.components(separatedBy: .newlines).compactMap { line -> String? in
            let pair = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            return pair.count == 2 && pair[0].lowercased() == "game_version" ? pair[1] : nil
        }
        guard versions == [version] else { throw SophonProtocolError.corrupt("已提交安装的版本与游戏配置不一致") }
        try verifyMainlandInstallation(game: game, root: root, confirmedMainland: false)
    }

    private struct InstallIdentity: Codable {
        let game: GameType
        let region: String
    }

    /// HoyoPlay package markers and language-specific game directories are
    /// independent of particular voice files, whose names change per release.
    func installedAudioLanguages(game: GameType, root: URL) throws -> Set<String> {
        let candidates = SophonGameProfile.audioResources(for: game)
        var result = Set<String>()
        for (language, marker, directory) in candidates {
            let markerURL = try safeURL(root: root, path: "Audio_\(marker)_pkg_version")
            let directoryURL = try safeURL(root: root, path: directory)
            if fm.fileExists(atPath: markerURL.path) || fm.fileExists(atPath: directoryURL.path) {
                result.insert(language)
            }
        }
        // Games without detectable installed voice resources receive the
        // mainland default, as they would on a new installation.
        return result.isEmpty ? ["zh-cn"] : result
    }

    func verifyMainlandInstallation(game: GameType, root: URL, confirmedMainland: Bool) throws {
        let configURL = try safeURL(root: root, path: "config.ini")
        let config = try String(contentsOf: configURL, encoding: .utf8)
        var values: [String: String] = [:]
        for line in config.components(separatedBy: .newlines) {
            let pair = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if pair.count == 2 { values[pair[0].lowercased()] = pair[1] }
        }
        guard values["channel"] == "1", values["sub_channel"] == "1", values["cps"]?.lowercased() == "mihoyo" else {
            throw SophonProtocolError.unsupported("游戏渠道不是可确认的国服官服")
        }
        let exe = game.definition.mainlandExecutableName
        let biz = game.definition.mainlandBiz
        let exeURL = try safeURL(root: root, path: exe)
        guard fm.fileExists(atPath: exeURL.path) else { throw SophonProtocolError.unsupported("目录中没有匹配的国服游戏程序") }
        if let uapc = values["uapc"], !uapc.isEmpty {
            guard let data = uapc.data(using: .utf8),
                  let values = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  values[biz] != nil, !values.keys.contains(where: { $0.hasSuffix("_global") }) else {
                throw SophonProtocolError.unsupported("游戏账号区域与国服不一致")
            }
        } else if game.definition.requiresMainlandIdentityConfirmation {
            // Star Rail's overseas config uses the same numeric channel. Require
            // a previous MiPlay mainland install marker or explicit uapc identity.
            let markerURL = try safeURL(root: root, path: ".miplay-sophon-install.json")
            guard let data = try? Data(contentsOf: markerURL),
                  let marker = try? JSONDecoder().decode(InstallIdentity.self, from: data),
                  marker.game == game, marker.region == "cn" else {
                if confirmedMainland { return }
                throw SophonProtocolError.unsupported("无法确认星穹铁道安装目录属于国服")
            }
        }
    }

    func updatedConfig(mode: SophonInstallMode, version: String, sourceVersion: String, existing: Data?) throws -> Data {
        guard !version.isEmpty, version.utf8.allSatisfy({ (48...57).contains($0) || $0 == 46 }) else {
            throw SophonProtocolError.corrupt("游戏版本号无效")
        }
        switch mode {
        case .install:
            return Data("[General]\r\ngame_version=\(version)\r\nchannel=1\r\nsub_channel=1\r\ncps=mihoyo\r\n".utf8)
        case .update, .updateConfirmedMainland:
            guard let existing, var config = String(data: existing, encoding: .utf8) else {
                throw SophonProtocolError.corrupt("游戏配置无法读取")
            }
            let regex = try NSRegularExpression(pattern: "(?m)^game_version[ \\t]*=[^\\r\\n]*")
            let range = NSRange(config.startIndex..<config.endIndex, in: config)
            guard regex.numberOfMatches(in: config, range: range) == 1,
                  config.components(separatedBy: .newlines).contains(where: { line in
                      let pair = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
                      return pair.count == 2 && pair[0].lowercased() == "game_version" && pair[1] == sourceVersion
                  }) else { throw SophonProtocolError.corrupt("游戏配置版本在下载期间发生变化") }
            config = regex.stringByReplacingMatches(in: config, range: range, withTemplate: "game_version=\(version)")
            return Data(config.utf8)
        }
    }
}
