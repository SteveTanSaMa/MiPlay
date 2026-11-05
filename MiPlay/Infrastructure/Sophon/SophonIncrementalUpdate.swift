import Foundation
import CryptoKit
import Darwin

/// Version 2 is a forward-only update. A completed file is never rolled back.
/// One active write-ahead intent bridges the two renames of the current file.
/// Old sources needed by later patches remain in backup until their last user.
extension SophonInstaller {
    struct IncrementalOperation: Codable {
        let path: String
        let size: UInt64
        let md5: String
        let originalMD5: String?
        let category: String?
        let patch: SophonPatchFile?
        let deletion: Bool
    }

    struct IncrementalJournal: Codable {
        let version: Int
        let game: GameType
        let destination: String
        let sourceVersion: String
        let targetVersion: String
        let identity: String
        let audioLanguages: [String]
        let config: Data
        let operations: [IncrementalOperation]
        var completedCount: Int
        var activeIndex: Int?
        var committed: Bool
    }

    /// A read-only discriminator. Legacy v1 transactions still use rollback.
    public func hasResumableUpdate(destination: URL, game: GameType) throws -> Bool {
        let root = try canonicalDestination(destination)
        try validateRoot(root)
        return try incrementalJournal(at: root, game: game) != nil
    }

    func incrementalJournal(at root: URL, game: GameType) throws -> IncrementalJournal? {
        let work = root.appendingPathComponent(transactionName, isDirectory: true)
        guard fm.fileExists(atPath: work.path) else { return nil }
        guard try fm.attributesOfItem(atPath: work.path)[.type] as? FileAttributeType == .typeDirectory else {
            throw SophonProtocolError.corrupt("更新事务目录无效，请保留目录")
        }
        let url = try safeURL(root: work, path: "journal.json")
        let handle = try openResumeFile(url, writing: false)
        defer { try? handle.close() }
        let length = try handle.seekToEnd()
        guard length > 0, length <= 64 * 1024 * 1024 else {
            throw SophonProtocolError.corrupt("更新事务记录大小无效")
        }
        try handle.seek(toOffset: 0)
        guard let bytes = try handle.readToEnd(), bytes.count == Int(length),
              let header = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              let version = header["version"] as? Int else {
            throw SophonProtocolError.corrupt("更新事务记录无法读取")
        }
        if version == 1 { return nil }
        guard version == 2 else { throw SophonProtocolError.corrupt("无法识别更新事务版本") }
        let journal = try JSONDecoder().decode(IncrementalJournal.self, from: bytes)
        guard journal.game == game,
              try canonicalDestination(URL(fileURLWithPath: journal.destination, isDirectory: true)).path == root.path,
              !journal.identity.isEmpty, !journal.sourceVersion.isEmpty, !journal.targetVersion.isEmpty,
              !journal.operations.isEmpty, journal.operations.count <= 200_000,
              (0...journal.operations.count).contains(journal.completedCount),
              journal.activeIndex == nil || (journal.activeIndex == journal.completedCount && journal.completedCount < journal.operations.count),
              !journal.committed || (journal.completedCount == journal.operations.count && journal.activeIndex == nil),
              journal.config.count <= 1024 * 1024,
              !journal.audioLanguages.isEmpty, Set(journal.audioLanguages).isSubset(of: ["zh-cn", "en-us", "ja-jp", "ko-kr"]) else {
            throw SophonProtocolError.corrupt("续装记录与游戏目录不匹配")
        }
        var paths = Set<String>()
        for (index, operation) in journal.operations.enumerated() {
            _ = try safeURL(root: root, path: operation.path)
            let key = operation.path.lowercased()
            guard paths.insert(key).inserted, key != ".miplay-sophon-install.json",
                  operation.size <= UInt64(Int64.max),
                  operation.originalMD5 == nil || SophonPatchClient.isMD5(operation.originalMD5!),
                  operation.deletion ? (operation.md5.isEmpty && operation.originalMD5 != nil && key != "config.ini") : SophonPatchClient.isMD5(operation.md5),
                  key != "config.ini" || (index == journal.operations.count - 1 && !operation.deletion && operation.patch == nil &&
                      operation.md5 == SophonMetadataClient.md5(journal.config) && operation.size == UInt64(journal.config.count)) else {
                throw SophonProtocolError.corrupt("续装记录包含无效操作")
            }
            if let patch = operation.patch {
                guard !operation.deletion, patch.path.lowercased() == operation.path.lowercased(), patch.size == operation.size,
                      patch.md5.lowercased() == operation.md5, operation.category != nil,
                      SophonPatchClient.safeComponent(patch.objectID), patch.objectSize > 0,
                      patch.offset <= patch.objectSize, patch.length > 0, patch.length <= patch.objectSize - patch.offset else {
                    throw SophonProtocolError.corrupt("续装差分记录无效")
                }
                if let source = patch.originalPath {
                    _ = try safeURL(root: root, path: source)
                    guard source.lowercased() != "config.ini", source.lowercased() != ".miplay-sophon-install.json",
                          patch.originalMD5.map(SophonPatchClient.isMD5) == true else {
                        throw SophonProtocolError.corrupt("续装差分源无效")
                    }
                } else if patch.originalSize != 0 || patch.originalMD5 != nil {
                    throw SophonProtocolError.corrupt("续装差分源无效")
                }
            }
        }
        guard journal.operations.last?.path.lowercased() == "config.ini" else {
            throw SophonProtocolError.corrupt("续装记录缺少最终版本配置")
        }
        return journal
    }

    private func saveIncrementalJournal(_ journal: IncrementalJournal, root: URL) throws {
        let work = root.appendingPathComponent(transactionName, isDirectory: true)
        let url = try safeURL(root: work, path: "journal.json")
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        try encoder.encode(journal).write(to: url, options: .atomic)
        let handle = try openResumeFile(url, writing: false)
        defer { try? handle.close() }
        try handle.synchronize()
        try syncIncrementalDirectory(work)
    }

    private func syncIncrementalDirectory(_ url: URL) throws {
        let fd = Darwin.open(url.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(fd) }
        if Darwin.fsync(fd) != 0, errno != EINVAL, errno != ENOTSUP {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private func incrementalFileMatches(_ url: URL, md5: String, size: UInt64? = nil) throws -> Bool {
        guard fm.fileExists(atPath: url.path) else { return false }
        let info = try fm.attributesOfItem(atPath: url.path)
        guard info[.type] as? FileAttributeType == .typeRegular else {
            throw SophonProtocolError.corrupt("续装路径不是常规文件：\(url.lastPathComponent)")
        }
        if let size, (info[.size] as? NSNumber)?.uint64Value != size { return false }
        return try fileMD5(url, honorCancellation: false) == md5.lowercased()
    }

    /// Reconcile only the active file; historical completed files stay installed.
    /// Returning nil means installation must continue and launching stays blocked.
    func recoverIncrementalUpdate(_ journal: inout IncrementalJournal, root: URL) throws -> SophonInstallResult? {
        if let index = journal.activeIndex {
            let operation = journal.operations[index]
            let work = root.appendingPathComponent(transactionName, isDirectory: true)
            let target = try safeURL(root: root, path: operation.path)
            let staged = try safeURL(root: work.appendingPathComponent("staged"), path: operation.path)
            let backup = try safeURL(root: work.appendingPathComponent("backup"), path: operation.path)
            if !operation.deletion,
               try incrementalFileMatches(target, md5: operation.md5, size: operation.size),
               !fm.fileExists(atPath: staged.path) || operation.originalMD5 == operation.md5 {
                journal.completedCount += 1
                journal.activeIndex = nil
                try saveIncrementalJournal(journal, root: root)
            } else if operation.deletion, !fm.fileExists(atPath: target.path),
                      let original = operation.originalMD5,
                      try incrementalFileMatches(backup, md5: original) {
                journal.completedCount += 1
                journal.activeIndex = nil
                try saveIncrementalJournal(journal, root: root)
            } else if try operation.deletion || incrementalFileMatches(staged, md5: operation.md5, size: operation.size) {
                try commitIncrementalOperation(&journal, root: root)
            } else {
                // A crash while preparing cannot invalidate already committed
                // files. Restore only this file if its old name was moved.
                if let original = operation.originalMD5 {
                    if !fm.fileExists(atPath: target.path), try incrementalFileMatches(backup, md5: original) {
                        try fm.moveItem(at: backup, to: target)
                        try syncIncrementalDirectory(target.deletingLastPathComponent())
                    }
                    guard try incrementalFileMatches(target, md5: original) else {
                        throw SophonProtocolError.corrupt("续装时发现被修改的文件：\(operation.path)")
                    }
                } else if fm.fileExists(atPath: target.path) {
                    throw SophonProtocolError.corrupt("续装目标被占用：\(operation.path)")
                }
                journal.activeIndex = nil
                try saveIncrementalJournal(journal, root: root)
                if fm.fileExists(atPath: staged.path) { try fm.removeItem(at: staged) }
            }
        }
        try verifyIncrementalCompleted(journal, root: root)
        try releaseIncrementalSources(journal, root: root)
        if journal.completedCount == journal.operations.count {
            journal.committed = true
            try saveIncrementalJournal(journal, root: root)
            incrementalReceiptDigest = try incrementalJournalDigest(at: root)
            return SophonInstallResult(version: journal.targetVersion)
        }
        return nil
    }

    private func verifyIncrementalCompleted(_ journal: IncrementalJournal, root: URL) throws {
        for operation in journal.operations.prefix(journal.completedCount) {
            let target = try safeURL(root: root, path: operation.path)
            if operation.deletion {
                guard !fm.fileExists(atPath: target.path) else {
                    throw SophonProtocolError.corrupt("已移除的文件又被占用：\(operation.path)")
                }
            } else if try !incrementalFileMatches(target, md5: operation.md5, size: operation.size) {
                throw SophonProtocolError.corrupt("已安装的文件被修改，请保留续装目录：\(operation.path)")
            }
        }
    }

    private func incrementalJournalDigest(at root: URL) throws -> String {
        try fileMD5(try safeURL(root: root.appendingPathComponent(transactionName), path: "journal.json"), honorCancellation: false)
    }

    /// The registry must durably save the version and installed state first.
    public func finalizeCommittedUpdate(destination: URL, game: GameType,
                                        holding suppliedLock: SophonDirectoryLock? = nil) throws {
        let root = try canonicalDestination(destination)
        try validateRoot(root)
        let lock = try operationLock(at: root, holding: suppliedLock)
        defer { if suppliedLock == nil { lock.release() } }
        guard let journal = try incrementalJournal(at: root, game: game) else { return }
        guard journal.committed, journal.completedCount == journal.operations.count, journal.activeIndex == nil else {
            throw SophonProtocolError.corrupt("分批更新尚未完成，必须继续更新")
        }
        if try incrementalJournalDigest(at: root) != incrementalReceiptDigest {
            try verifyIncrementalCompleted(journal, root: root)
        }
        try releaseIncrementalSources(journal, root: root)
        try fm.removeItem(at: root.appendingPathComponent(transactionName))
        incrementalReceiptDigest = nil
        try syncIncrementalDirectory(root)
    }

    func runIncrementalUpdate(game: GameType, destination: URL, mode: SophonInstallMode,
                              holding suppliedLock: SophonDirectoryLock?,
                              progress: @escaping @Sendable (SophonProgress) async -> Void) async throws -> SophonInstallResult {
        let root = try canonicalDestination(destination)
        try validateRoot(root)
        let lock = try operationLock(at: root, holding: suppliedLock)
        defer { if suppliedLock == nil { lock.release() } }
        var existing = try incrementalJournal(at: root, game: game)
        if var journal = existing {
            if let completed = try recoverIncrementalUpdate(&journal, root: root) { return completed }
            existing = journal
        } else {
            guard !hasPendingTransaction(destination: root) else {
                throw SophonProtocolError.corrupt("发现旧版下载事务，必须先恢复")
            }
            guard game.definition.contentCapabilities.sophonUpdate else {
                throw SophonProtocolError.unsupported("此游戏暂不支持 Sophon 更新")
            }
            let confirmed: Bool
            if case .updateConfirmedMainland = mode { confirmed = true } else { confirmed = false }
            try verifyMainlandInstallation(game: game, root: root, confirmedMainland: confirmed)
        }
        try Task.checkCancellation()
        await progress(.init(fractionCompleted: nil, message: "正在获取官方续装清单", bytesCompleted: 0, bytesTotal: nil))
        let audio = try existing.map { Set($0.audioLanguages) } ?? installedAudioLanguages(game: game, root: root)
        let build = try await metadata.fetchBuild(for: game, audioLanguages: audio)
        let (files, byPath) = try await loadFiles(build: build, root: root)
        let sourceVersion = try existing?.sourceVersion ?? installedVersion(at: root)
        let identity = try resumeContextIdentity(game: game, mode: "update", sourceVersion: sourceVersion, build: build)
        if let existing {
            guard existing.identity == identity, existing.targetVersion == build.version else {
                throw SophonProtocolError.unsupported("官方更新清单已变化，已安装进度已保留；请勿删除续装目录")
            }
        }
        let cache = try SophonResumeCache.open(destination: root, game: game, identity: identity, filePaths: files.map { $0.0.path })
        let patchCategories = build.diffTags.contains(sourceVersion) && sourceVersion != build.version
            ? try await patchClient.fetch(build: build, from: sourceVersion) : []
        guard Set(patchCategories.map(\.id)).count == patchCategories.count else {
            throw SophonProtocolError.corrupt("差分资源分类重复")
        }
        var journal: IncrementalJournal
        if let existing {
            journal = existing
            try validateIncrementalPlan(journal, files: byPath, patchCategories: patchCategories)
            let config = try safeURL(root: root, path: "config.ini")
            guard let original = journal.operations.last?.originalMD5,
                  try incrementalFileMatches(config, md5: original) else {
                throw SophonProtocolError.corrupt("续装期间游戏版本配置发生变化")
            }
        } else {
            journal = try await createIncrementalPlan(game: game, root: root, build: build, files: files,
                byPath: byPath, sourceVersion: sourceVersion, identity: identity, audio: audio,
                patchCategories: patchCategories, cache: cache, mode: mode, progress: progress)
            let work = root.appendingPathComponent(transactionName, isDirectory: true)
            try fm.createDirectory(at: work.appendingPathComponent("staged"), withIntermediateDirectories: true)
            try fm.createDirectory(at: work.appendingPathComponent("backup"), withIntermediateDirectories: true)
            do { try saveIncrementalJournal(journal, root: root) }
            catch { try? fm.removeItem(at: work); throw error }
        }
        // Resume cleanup after a crash between publishing completion and
        // releasing that file's cache. Never discard a pending file's cache.
        try await cleanIncrementalCaches(journal, cache: cache, patchCategories: patchCategories)
        let work = root.appendingPathComponent(transactionName, isDirectory: true)
        while journal.completedCount < journal.operations.count {
            try Task.checkCancellation()
            let index = journal.completedCount
            let operation = journal.operations[index]
            let fraction = Double(index) / Double(journal.operations.count)
            await progress(.init(fractionCompleted: fraction, message: "正在分批安装游戏文件（\(index)/\(journal.operations.count)）", bytesCompleted: 0, bytesTotal: nil))
            try validateIncrementalOriginal(operation, root: root)
            if operation.path.lowercased() == "config.ini" {
                // A file that was already current during the original scan may
                // have changed while this update was paused. Do not publish a
                // new version until the complete official target set matches.
                for (fileIndex, entry) in files.enumerated() {
                    try Task.checkCancellation()
                    let file = entry.0
                    guard try incrementalFileMatches(try safeURL(root: root, path: file.path), md5: file.md5, size: file.size) else {
                        throw SophonProtocolError.corrupt("更新后文件校验失败，已保留续装记录：\(file.path)")
                    }
                    if fileIndex % 50 == 0 || fileIndex + 1 == files.count {
                        await progress(.init(fractionCompleted: Double(fileIndex + 1) / Double(files.count),
                            message: "正在验证更新后的游戏文件（\(fileIndex + 1)/\(files.count)）", bytesCompleted: 0, bytesTotal: nil))
                    }
                }
            }
            if !operation.deletion {
                let staged = try safeURL(root: work.appendingPathComponent("staged"), path: operation.path)
                if try !incrementalFileMatches(staged, md5: operation.md5, size: operation.size) {
                    if fm.fileExists(atPath: staged.path) { try fm.removeItem(at: staged) }
                    try fm.createDirectory(at: staged.deletingLastPathComponent(), withIntermediateDirectories: true)
                    if operation.path.lowercased() == "config.ini" {
                        try checkIncrementalSpace(root: root, required: UInt64(journal.config.count))
                        try journal.config.write(to: staged, options: .atomic)
                    } else {
                        guard let file = byPath[operation.path.lowercased()],
                              let category = files.first(where: { $0.0.path.lowercased() == operation.path.lowercased() })?.1 else {
                            throw SophonProtocolError.corrupt("续装目标不在官方清单")
                        }
                        var patched = false
                        if let patch = operation.patch, let patchCategory = patchCategories.first(where: { $0.id == operation.category }),
                           try !hasVerifiedFullCache(file, cache: cache) {
                            let patchCache = try openPatchCache(cache)
                            let object = SophonPatchObject(file: patch, category: patchCategory)
                            let range = patch.offset..<(patch.offset + patch.length)
                            let remaining = try await patchCache.estimatedRemainingBytes(object, ranges: [range])
                            guard operation.size <= UInt64.max - patch.length,
                                  operation.size + patch.length <= UInt64.max - remaining else {
                                throw SophonProtocolError.corrupt("更新空间大小溢出")
                            }
                            try checkIncrementalSpace(root: root, required: operation.size + patch.length + remaining)
                            try await patchCache.download(object, ranges: [range], beforeWrite: { [self] required in
                                try await checkIncrementalSpace(root: root, required: required)
                            })
                            let slice = work.appendingPathComponent("patch-slice")
                            if fm.fileExists(atPath: slice.path) { try fm.removeItem(at: slice) }
                            try createResumeFile(slice)
                            defer { try? fm.removeItem(at: slice) }
                            let writer = try openResumeFile(slice, writing: true)
                            do { try await patchCache.copy(object, range: range, to: writer); try writer.close() }
                            catch { try? writer.close(); throw error }
                            let source: URL
                            if let path = patch.originalPath {
                                source = try incrementalSource(path, journal: journal, root: root)
                            } else {
                                source = work.appendingPathComponent("empty-source")
                                if !fm.fileExists(atPath: source.path) { try createResumeFile(source) }
                            }
                            patched = try stagePatch(source: source, diff: slice, output: staged, entry: patch, diffOffset: 0)
                            if !patched { try? await patchCache.invalidate(object, ranges: [range]) }
                        }
                        if !patched {
                            var total: Int64 = 0
                            for chunk in file.chunks {
                                guard chunk.compressedSize <= UInt64(Int64.max), total <= Int64.max - Int64(chunk.compressedSize) else {
                                    throw SophonProtocolError.corrupt("资源大小溢出")
                                }
                                total += Int64(chunk.compressedSize)
                            }
                            _ = try await cacheDownloads([(file, category)], cache: cache,
                                stagedRoot: work.appendingPathComponent("staged"), total: total,
                                message: "正在下载本批完整资源", spaceCheck: { [self] required in
                                    try await checkIncrementalSpace(root: root, required: required)
                                }, progress: progress)
                        }
                    }
                    let handle = try openResumeFile(staged, writing: false)
                    try handle.synchronize()
                    try handle.close()
                    try syncIncrementalDirectory(staged.deletingLastPathComponent())
                }
                guard try incrementalFileMatches(staged, md5: operation.md5, size: operation.size) else {
                    throw SophonProtocolError.corrupt("本批文件校验失败：\(operation.path)")
                }
            }
            if operation.path.lowercased() == "config.ini" {
                await progress(.init(fractionCompleted: 0.99, message: ScheduledTask.sophonCommitPhaseDescription, bytesCompleted: 0, bytesTotal: nil))
            }
            try Task.checkCancellation()
            journal.activeIndex = index
            try saveIncrementalJournal(journal, root: root)
            // No cancellation point between the old/new rename and its durable
            // completion record. Cancellation is honored before the next file.
            try commitIncrementalOperation(&journal, root: root)
            try releaseIncrementalSources(journal, root: root)
            if journal.completedCount == journal.operations.count {
                // Config is now durable. A late Task cancellation must not turn
                // a completed update into a cancelled result during cleanup.
                journal.committed = true
                try saveIncrementalJournal(journal, root: root)
                break
            }
            try await cleanIncrementalCaches(journal, cache: cache, patchCategories: patchCategories)
            if journal.completedCount < journal.operations.count {
                await progress(.init(fractionCompleted: Double(journal.completedCount) / Double(journal.operations.count),
                    message: "已安装 \(journal.completedCount)/\(journal.operations.count) 个文件", bytesCompleted: 0, bytesTotal: nil))
            }
        }
        journal.committed = true
        try saveIncrementalJournal(journal, root: root)
        incrementalReceiptDigest = try incrementalJournalDigest(at: root)
        try? await cleanIncrementalCaches(journal, cache: cache, patchCategories: patchCategories)
        try? cache.cleanup(ownedKeys: Set(files.map { SophonResumeCache.hash($0.0.path) }))
        await progress(.init(fractionCompleted: 0.99, message: ScheduledTask.sophonCommitPhaseDescription, bytesCompleted: 0, bytesTotal: nil))
        return SophonInstallResult(version: journal.targetVersion)
    }

    private func createIncrementalPlan(game: GameType, root: URL, build: SophonBuild,
        files: [(SophonFile, SophonCategory)], byPath: [String: SophonFile], sourceVersion: String,
        identity: String, audio: Set<String>, patchCategories: [SophonPatchCategory], cache: SophonResumeCache,
        mode: SophonInstallMode, progress: @escaping @Sendable (SophonProgress) async -> Void) async throws -> IncrementalJournal {
        await progress(.init(fractionCompleted: 0, message: "正在检查已有游戏文件", bytesCompleted: 0, bytesTotal: nil))
        var operations: [IncrementalOperation] = []
        for (index, entry) in files.enumerated() {
            try Task.checkCancellation()
            let (file, category) = entry
            let target = try safeURL(root: root, path: file.path)
            let original = fm.fileExists(atPath: target.path) ? try fileMD5(target) : nil
            if original == file.md5.lowercased() { continue }
            var selected: SophonPatchFile?
            if try !hasVerifiedFullCache(file, cache: cache),
               let candidate = patchCategories.first(where: { $0.id == category.id })?.files.first(where: { $0.path.lowercased() == file.path.lowercased() }),
               candidate.size == file.size, candidate.md5.lowercased() == file.md5.lowercased() {
                if let source = candidate.originalPath {
                    if !["config.ini", ".miplay-sophon-install.json"].contains(source.lowercased()),
                       let md5 = candidate.originalMD5,
                       try incrementalFileMatches(try safeURL(root: root, path: source), md5: md5, size: candidate.originalSize) {
                        selected = candidate
                    }
                } else if candidate.originalSize == 0 && candidate.originalMD5 == nil { selected = candidate }
            }
            operations.append(.init(path: file.path, size: file.size, md5: file.md5.lowercased(), originalMD5: original,
                                    category: category.id, patch: selected, deletion: false))
            if index % 50 == 0 {
                await progress(.init(fractionCompleted: Double(index) / Double(files.count), message: "正在检查已有游戏文件", bytesCompleted: 0, bytesTotal: nil))
            }
        }
        operations = incrementalOrder(operations)
        let deletions = try await metadata.fetchDeletions(for: build, from: sourceVersion)
        var deletionPaths: [String: SophonDeletedFile] = [:]
        for file in deletions {
            let key = file.path.lowercased()
            guard !["config.ini", ".miplay-sophon-install.json"].contains(key), SophonPatchClient.isMD5(file.md5) else {
                throw SophonProtocolError.corrupt("删除清单包含受保护路径")
            }
            if byPath[key] != nil { continue }
            if let prior = deletionPaths[key] {
                guard prior == file else { throw SophonProtocolError.corrupt("删除清单包含冲突条目") }
                continue
            }
            deletionPaths[key] = file
            let target = try safeURL(root: root, path: file.path)
            guard fm.fileExists(atPath: target.path) else { continue }
            guard try incrementalFileMatches(target, md5: file.md5, size: file.size) else {
                throw SophonProtocolError.corrupt("待移除的旧文件已改变：\(file.path)")
            }
            operations.append(.init(path: file.path, size: 0, md5: "", originalMD5: file.md5.lowercased(), category: nil, patch: nil, deletion: true))
        }
        let originalConfig = try Data(contentsOf: safeURL(root: root, path: "config.ini"))
        let config = try updatedConfig(mode: mode, version: build.version, sourceVersion: sourceVersion, existing: originalConfig)
        operations.append(.init(path: "config.ini", size: UInt64(config.count), md5: SophonMetadataClient.md5(config),
                                originalMD5: SophonMetadataClient.md5(originalConfig), category: nil, patch: nil, deletion: false))
        return IncrementalJournal(version: 2, game: game, destination: root.path, sourceVersion: sourceVersion,
            targetVersion: build.version, identity: identity, audioLanguages: audio.sorted(), config: config,
            operations: operations, completedCount: 0, activeIndex: nil, committed: false)
    }

    /// Consumers precede the file whose old bytes they need. Breaking a cycle
    /// retains that producer's backup until the remaining consumers complete.
    private func incrementalOrder(_ operations: [IncrementalOperation]) -> [IncrementalOperation] {
        var remaining = Dictionary(uniqueKeysWithValues: operations.map { ($0.path.lowercased(), $0) })
        var consumers: [String: Set<String>] = [:]
        for operation in operations {
            if let source = operation.patch?.originalPath?.lowercased(), source != operation.path.lowercased(), remaining[source] != nil {
                consumers[source, default: []].insert(operation.path.lowercased())
            }
        }
        func priority(_ key: String) -> String { (key.contains("pkg_version") ? "1" : "0") + key }
        var result: [IncrementalOperation] = []
        while !remaining.isEmpty {
            let ordered = remaining.keys.sorted { priority($0) < priority($1) }
            let key = ordered.first(where: { consumers[$0, default: []].isEmpty }) ?? ordered[0]
            let operation = remaining.removeValue(forKey: key)!
            result.append(operation)
            if let source = operation.patch?.originalPath?.lowercased() { consumers[source]?.remove(key) }
        }
        return result
    }

    private func validateIncrementalPlan(_ journal: IncrementalJournal, files: [String: SophonFile], patchCategories: [SophonPatchCategory]) throws {
        for operation in journal.operations where !operation.deletion && operation.path.lowercased() != "config.ini" {
            guard let file = files[operation.path.lowercased()], file.size == operation.size, file.md5.lowercased() == operation.md5 else {
                throw SophonProtocolError.corrupt("续装目标与官方清单不一致")
            }
            if let patch = operation.patch, journal.operations[journal.completedCount...].contains(where: { $0.path == operation.path }) {
                guard patchCategories.first(where: { $0.id == operation.category })?.files.contains(patch) == true else {
                    throw SophonProtocolError.corrupt("官方差分清单已变化，已保留续装进度")
                }
            }
        }
    }

    private func validateIncrementalOriginal(_ operation: IncrementalOperation, root: URL) throws {
        let target = try safeURL(root: root, path: operation.path)
        if let original = operation.originalMD5 {
            guard try incrementalFileMatches(target, md5: original) else {
                throw SophonProtocolError.corrupt("待更新文件在安装期间发生变化：\(operation.path)")
            }
        } else if fm.fileExists(atPath: target.path) {
            throw SophonProtocolError.corrupt("待更新路径被占用：\(operation.path)")
        }
    }

    private func incrementalSource(_ path: String, journal: IncrementalJournal, root: URL) throws -> URL {
        if journal.operations.prefix(journal.completedCount).contains(where: { $0.path.lowercased() == path.lowercased() }) {
            return try safeURL(root: root.appendingPathComponent(transactionName).appendingPathComponent("backup"), path: path)
        }
        return try safeURL(root: root, path: path)
    }

    private func commitIncrementalOperation(_ journal: inout IncrementalJournal, root: URL) throws {
        guard let index = journal.activeIndex, index == journal.completedCount else {
            throw SophonProtocolError.corrupt("续装提交状态无效")
        }
        let operation = journal.operations[index]
        let work = root.appendingPathComponent(transactionName, isDirectory: true)
        let target = try safeURL(root: root, path: operation.path)
        let staged = try safeURL(root: work.appendingPathComponent("staged"), path: operation.path)
        let backup = try safeURL(root: work.appendingPathComponent("backup"), path: operation.path)
        if !operation.deletion {
            guard try incrementalFileMatches(staged, md5: operation.md5, size: operation.size) else {
                throw SophonProtocolError.corrupt("暂存文件在提交前改变：\(operation.path)")
            }
        }
        try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let original = operation.originalMD5 {
            if fm.fileExists(atPath: backup.path) {
                guard !fm.fileExists(atPath: target.path), try incrementalFileMatches(backup, md5: original) else {
                    throw SophonProtocolError.corrupt("当前文件备份与续装状态冲突：\(operation.path)")
                }
            } else {
                guard try incrementalFileMatches(target, md5: original) else {
                    throw SophonProtocolError.corrupt("提交前发现原文件变化：\(operation.path)")
                }
                try fm.createDirectory(at: backup.deletingLastPathComponent(), withIntermediateDirectories: true)
                try fm.moveItem(at: target, to: backup)
                try syncIncrementalDirectory(backup.deletingLastPathComponent())
                try syncIncrementalDirectory(target.deletingLastPathComponent())
            }
        } else if fm.fileExists(atPath: target.path) {
            throw SophonProtocolError.corrupt("提交路径被占用：\(operation.path)")
        }
        if !operation.deletion {
            try fm.moveItem(at: staged, to: target)
            try syncIncrementalDirectory(target.deletingLastPathComponent())
            try syncIncrementalDirectory(staged.deletingLastPathComponent())
        }
        journal.completedCount += 1
        journal.activeIndex = nil
        try saveIncrementalJournal(journal, root: root)
    }

    private func releaseIncrementalSources(_ journal: IncrementalJournal, root: URL) throws {
        let needed = Set(journal.operations.dropFirst(journal.completedCount).compactMap { $0.patch?.originalPath?.lowercased() })
        let backupRoot = root.appendingPathComponent(transactionName).appendingPathComponent("backup")
        for operation in journal.operations.prefix(journal.completedCount) where !needed.contains(operation.path.lowercased()) {
            let backup = try safeURL(root: backupRoot, path: operation.path)
            guard fm.fileExists(atPath: backup.path) else { continue }
            guard let original = operation.originalMD5, try incrementalFileMatches(backup, md5: original) else {
                throw SophonProtocolError.corrupt("旧源文件发生变化，已停止释放：\(operation.path)")
            }
            try fm.removeItem(at: backup)
            try syncIncrementalDirectory(backup.deletingLastPathComponent())
        }
    }

    private func cleanIncrementalCaches(_ journal: IncrementalJournal, cache: SophonResumeCache,
                                       patchCategories: [SophonPatchCategory]) async throws {
        let completed = journal.operations.prefix(journal.completedCount)
        let keys = Set(completed.filter { !$0.deletion && $0.category != nil }.map { SophonResumeCache.hash($0.path) })
        try cache.cleanup(ownedKeys: keys, preservingContext: true)
        let pending = journal.operations.dropFirst(journal.completedCount)
        var objects: [String: SophonPatchObject] = [:]
        for operation in completed {
            guard let patch = operation.patch, let category = patchCategories.first(where: { $0.id == operation.category }),
                  !pending.contains(where: { $0.category == operation.category && $0.patch?.objectID == patch.objectID }) else { continue }
            objects[category.id + ":" + patch.objectID] = SophonPatchObject(file: patch, category: category)
        }
        if !objects.isEmpty {
            let patchCache = try openPatchCache(cache)
            _ = try await patchCache.cleanup(objects: Array(objects.values))
        }
    }

    private func checkIncrementalSpace(root: URL, required: UInt64) throws {
        let free = try preDownloadAvailableBytes(root)
        guard free >= Self.preDownloadSpaceReserve, required <= free - Self.preDownloadSpaceReserve else {
            throw SophonProtocolError.unsupported("本批更新空间不足，已安装进度和下载缓存已保留；腾出空间后可继续更新")
        }
    }
}
