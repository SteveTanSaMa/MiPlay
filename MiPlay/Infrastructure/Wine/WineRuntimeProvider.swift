//
//  WineRuntimeProvider.swift
//  MiPlay
//

import Foundation

/// All supported game clients are mainland builds. Give managed Wine an
/// explicit locale instead of inheriting the developer shell's C/en locale.
/// This selects Wine's default language; existing in-game preferences remain
/// owned by the game and are never rewritten here.
enum ManagedWineLocale {
    nonisolated static func environment(adding values: [String: String] = [:]) -> [String: String] {
        var environment = values
        for key in ["LANG", "LC_ALL", "LC_CTYPE", "LC_MESSAGES"] {
            environment[key] = "zh_CN.UTF-8"
        }
        environment["LANGUAGE"] = "zh_CN:zh"
        return environment
    }
}

// Source: Architecture Design -> Service Contract -> WineRuntimeProvider
// Source: Architecture Design -> ADR 006 -> fixed Wine executable and prefix

/// Executes the fixed managed Wine binary and prepares the one application-owned
/// prefix shared by all supported games.
public actor WineRuntimeProvider {
    public struct PreparedPrefix: Sendable, Equatable {
        public let url: URL

        internal init(url: URL) {
            self.url = url
        }

        public var path: String { url.path }
    }

    public enum WineError: Error, LocalizedError, Sendable {
        case wineNotInstalled
        case prefixCreationFailed(String)
        case environmentNotReady(String)
        case wineBinaryNotFound(String)
        case prefixBusy
        case recoveryRequired(String)
        case cancelled

        public var errorDescription: String? {
            switch self {
            case .wineNotInstalled: return "Wine 运行时未安装"
            case .prefixCreationFailed(let detail): return "Wine 前缀创建失败: \(detail)"
            case .environmentNotReady(let detail): return "Wine 环境未就绪: \(detail)"
            case .wineBinaryNotFound(let path): return "Wine 二进制文件未找到: \(path)"
            case .prefixBusy: return "共享 Wine prefix 正在被占用"
            case .recoveryRequired(let detail): return "Wine prefix 需要恢复: \(detail)"
            case .cancelled: return "Wine 环境准备已取消"
            }
        }
    }

    private let processManager: ProcessManager
    private let fileSystemRepository: GameFileSystemRepository
    private let logWriter: LogWriter?
    /// 读取 `AppData.gameEnvironmentSettings`（Metal HUD / 帧率 / Retina / 左 Command）。
    /// 可选依赖：测试与旧调用点不传时使用默认值（Retina 开、左 Command 不映射）。
    private let persistenceStore: PersistenceStore?
    private var activePrefixLease: SharedWinePrefixLease?
    /// 已验证过的 wine binary 指纹（见 `load(runtime:)`）。
    private var verifiedBinaryFingerprints: Set<String> = []

    public init(
        processManager: ProcessManager,
        fileSystemRepository: GameFileSystemRepository,
        logWriter: LogWriter? = nil,
        persistenceStore: PersistenceStore? = nil
    ) {
        self.processManager = processManager
        self.fileSystemRepository = fileSystemRepository
        self.logWriter = logWriter
        self.persistenceStore = persistenceStore
        self.activePrefixLease = nil
    }

    /// Loads only a runtime identity produced by WineVersionManager.
    ///
    /// 一次启动流程里会有多个调用方请求同一 runtime（readiness → lease →
    /// 编排器 → prefix 准备，共 4–6 次）。每次 `wine --version` 都要拉起一个
    /// wine 进程，因此这里按 binary 指纹（路径 + 大小 + 修改时间）在进程内缓存
    /// 验证结果：同一 binary 只探针一次；runtime 被重新下载/替换后指纹变化，
    /// 会重新验证。
    internal func load(runtime: ManagedWineRuntime) async throws -> URL {
        guard runtime.identity == WineVersionManager.fixedRuntimeTag else {
            throw WineError.environmentNotReady("不是当前固定 Wine runtime")
        }
        let runtimeRoot = runtime.rootURL.resolvingSymlinksInPath().standardizedFileURL
        let wineBinaryURL = runtime.binaryURL
        guard runtimeRoot.path.hasSuffix("/WineVersions/\(runtime.tagName)"),
              wineBinaryURL.deletingLastPathComponent().deletingLastPathComponent()
                .resolvingSymlinksInPath().standardizedFileURL == runtimeRoot,
              FileManager.default.fileExists(atPath: wineBinaryURL.path) else {
            throw WineError.wineBinaryNotFound(wineBinaryURL.path)
        }
        guard FileManager.default.isExecutableFile(atPath: wineBinaryURL.path) else {
            throw WineError.environmentNotReady("Wine binary 不可执行")
        }
        if let fingerprint = Self.binaryFingerprint(at: wineBinaryURL),
           verifiedBinaryFingerprints.contains(fingerprint) {
            await logWriter?.record(.init(
                level: .info,
                module: "WineRuntimeProvider",
                eventName: "wine.runtime.readiness",
                wineTag: runtime.tagName,
                phase: "binaryCheck",
                result: "completed",
                messageCode: "wine.runtime.ready",
                fields: ["reasonCode": "cachedBinaryVerification"]
            ))
            return wineBinaryURL
        }
        await logWriter?.record(.init(
            level: .info,
            module: "WineRuntimeProvider",
            eventName: "wine.runtime.readiness",
            wineTag: runtime.tagName,
            phase: "binaryCheck",
            result: "inProgress",
            messageCode: "wine.runtime.check_started"
        ))
        do {
            let output = try await processManager.launchAndWait(
                executablePath: wineBinaryURL.path,
                arguments: ["--version"],
                environment: ManagedWineLocale.environment(),
                timeout: 10
            ).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !output.isEmpty else { throw WineError.environmentNotReady("Wine 版本检测无输出") }
            if let fingerprint = Self.binaryFingerprint(at: wineBinaryURL) {
                verifiedBinaryFingerprints.insert(fingerprint)
            }
            await logWriter?.record(.init(
                level: .info,
                module: "WineRuntimeProvider",
                eventName: "wine.runtime.readiness",
                wineTag: runtime.tagName,
                phase: "binaryCheck",
                result: "completed",
                messageCode: "wine.runtime.ready"
            ))
            return wineBinaryURL
        } catch let error as WineError { throw error }
        catch is CancellationError { throw WineError.cancelled }
        catch { throw WineError.environmentNotReady(error.localizedDescription) }
    }

    /// Legacy test/migration seam. Production code must use `load(runtime:)`.
    internal func load(runtimePath: String) async throws -> String {
        let runtimeURL = URL(fileURLWithPath: runtimePath)
        let rootURL: URL
        switch runtimeURL.lastPathComponent {
        case "wine":
            rootURL = runtimeURL.deletingLastPathComponent().deletingLastPathComponent()
        case "bin":
            rootURL = runtimeURL.deletingLastPathComponent()
        default:
            rootURL = runtimeURL
        }
        let runtime = ManagedWineRuntime(
            tagName: rootURL.lastPathComponent,
            rootURL: rootURL
        )
        return try await load(runtime: runtime).path
    }

    /// Acquires the exclusive lease for the shared prefix. The lease is held by
    /// the launch orchestrator from preparation through process cleanup.
    internal func acquireSharedPrefixLease() async throws -> SharedWinePrefixLease {
        guard activePrefixLease == nil else { throw WineError.prefixBusy }
        let prefix = SharedWinePrefix(
            identity: WineVersionManager.sharedPrefixIdentity,
            url: await sharedPrefixURL(),
            runtimeIdentity: WineVersionManager.fixedRuntimeTag
        )
        let lease = SharedWinePrefixLease(prefix: prefix)
        activePrefixLease = lease
        return lease
    }

    internal func releaseSharedPrefixLease(_ lease: SharedWinePrefixLease) throws {
        guard activePrefixLease?.id == lease.id else {
            throw WineError.recoveryRequired("共享 prefix lease 释放顺序不一致")
        }
        activePrefixLease = nil
    }

    /// Applies the Wine "Mac Driver" display and keyboard properties the
    /// supported games rely on: `RetinaMode` 与 `LeftCommandIsCtrl`
    /// （对照 YAAGL 的 `wine.setProps`，由用户在设置里开关）。
    ///
    /// 值已经写进 prefix 就跳过：`wine reg add` 会冷启动 wineserver，实测约
    /// 3.7s（warm 0.66s），是启动流程里最大的一段固定开销。注册表在 wineserver
    /// 退出时落盘（每次启动清理都会 `wineserver -k`），因此 wine 未运行时
    /// `user.reg` 就是权威值；prefix 被重建后文件缺失，会自动回到写入路径。
    private func applyManagedDisplaySettings(wineBinary: String, prefixPath: String) async {
        let desired = await desiredDisplaySettings()
        var appliedKeys: [String] = []
        var failedKeys: [String] = []
        for (key, value) in desired.registryValues.sorted(by: { $0.key < $1.key }) {
            if Self.macDriverValue(forKey: key, atPrefixPath: prefixPath) == value { continue }
            do {
                _ = try await processManager.launchAndWait(
                    executablePath: wineBinary,
                    arguments: [
                        "reg", "add", "HKCU\\Software\\Wine\\Mac Driver",
                        "/v", key, "/t", "REG_SZ", "/d", value, "/f"
                    ],
                    environment: ManagedWineLocale.environment(adding: ["WINEPREFIX": prefixPath]),
                    workingDirectory: prefixPath,
                    timeout: 15
                )
                appliedKeys.append(key)
            } catch {
                failedKeys.append(key)
            }
        }

        if !appliedKeys.isEmpty || !failedKeys.isEmpty {
            await logWriter?.record(.init(
                level: failedKeys.isEmpty ? .info : .warning,
                module: "WineRuntimeProvider",
                eventName: "wine.display.settings",
                phase: "apply",
                result: failedKeys.isEmpty ? "completed" : "failed",
                errorCategory: failedKeys.isEmpty ? "none" : "unknown",
                messageCode: failedKeys.isEmpty
                    ? "wine.display.settings_applied"
                    : "wine.display.settings_failed",
                fields: ["itemCount": String(appliedKeys.count)]
            ))
        } else {
            await logWriter?.record(.init(
                level: .info,
                module: "WineRuntimeProvider",
                eventName: "wine.display.settings",
                phase: "apply",
                result: "completed",
                messageCode: "wine.display.settings_already_applied",
                fields: ["reasonCode": "alreadyApplied"]
            ))
        }
    }

    /// AppData 里持久化的显示/按键设置；没有 store 时返回默认值。
    private func desiredDisplaySettings() async -> GameEnvironmentSettings {
        guard let persistenceStore,
              let appData = try? await persistenceStore.readAppData() else {
            return GameEnvironmentSettings()
        }
        return appData.gameEnvironmentSettings
    }

    /// 读取 prefix 的 `user.reg`，返回
    /// `HKCU\Software\Wine\Mac Driver\<key>` 的当前值（无则 nil）。只读文件，
    /// 不拉起任何 wine 进程。
    nonisolated internal static func macDriverValue(forKey key: String, atPrefixPath prefixPath: String) -> String? {
        let registryURL = URL(fileURLWithPath: prefixPath, isDirectory: true)
            .appendingPathComponent("user.reg")
        guard let content = try? String(contentsOf: registryURL, encoding: .utf8) else { return nil }
        var inMacDriverSection = false
        for rawLine in content.split(separator: "\n", omittingEmptySubsequences: false) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") {
                inMacDriverSection = line.contains(#"Software\\Wine\\Mac Driver"#)
                continue
            }
            guard inMacDriverSection, line.hasPrefix("\"\(key)\"=") else { continue }
            // 形如 `"RetinaMode"="y"`：取最后一个引号对之间的内容。
            let components = line.components(separatedBy: "\"")
            return components.count >= 4 ? components[components.count - 2] : nil
        }
        return nil
    }

    /// wine binary 身份指纹（路径 + 大小 + 修改时间）。runtime 被替换后指纹变化。
    nonisolated internal static func binaryFingerprint(at url: URL) -> String? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attributes[.size] as? UInt64,
              let modified = attributes[.modificationDate] as? Date else { return nil }
        return "\(url.path)|\(size)|\(modified.timeIntervalSince1970)"
    }

    /// Stops the managed wineserver for the leased shared prefix. Wine keeps
    /// this service alive after the last Windows process exits, so releasing
    /// only the Swift lease would not fully release the prefix.
    internal func shutdownSharedPrefix(
        runtime: ManagedWineRuntime,
        lease: SharedWinePrefixLease
    ) async throws {
        guard activePrefixLease?.id == lease.id else {
            throw WineError.recoveryRequired("共享 prefix lease 已失效")
        }
        let runtimeRoot = runtime.rootURL.resolvingSymlinksInPath().standardizedFileURL
        let serverURL = runtimeRoot.appendingPathComponent("bin/wineserver")
        guard FileManager.default.fileExists(atPath: serverURL.path) else { return }
        guard FileManager.default.isExecutableFile(atPath: serverURL.path) else {
            throw WineError.environmentNotReady("managed wineserver 不可执行")
        }
        let processID = try await processManager.launch(
            executablePath: serverURL.path,
            arguments: ["-k"],
            environment: ManagedWineLocale.environment(adding: ["WINEPREFIX": lease.prefix.url.path]),
            workingDirectory: lease.prefix.url.path
        )
        let result = try await processManager.waitForTermination(processID: processID, timeout: 10)
        // `wineserver -k` exits 1 when no server is running. That state already
        // satisfies this call's goal (no managed server left behind), so it is
        // accepted alongside the clean kill.
        guard !result.terminatedBySignal, result.statusCode == 0 || result.statusCode == 1 else {
            throw WineError.recoveryRequired("managed wineserver -k 未确认: 退出码 \(result.statusCode)")
        }
    }

    internal func sharedPrefixURL() async -> URL {
        await fileSystemRepository.appSupportDirectory()
            .appendingPathComponent("WinePrefixes/shared", isDirectory: true)
    }

    /// Runs `wine wineboot -u` with the same binary that will launch the game.
    /// When a lease is supplied, ownership remains with the caller.
    internal func prepareSharedPrefix(
        runtime: ManagedWineRuntime,
        lease: SharedWinePrefixLease? = nil
    ) async throws -> PreparedPrefix {
        await logWriter?.record(.init(
            level: .info,
            module: "WineRuntimeProvider",
            eventName: "wine.prefix.readiness",
            wineTag: runtime.tagName,
            phase: "prepare",
            result: "inProgress",
            messageCode: "wine.prefix.prepare_started"
        ))
        try Task.checkCancellation()
        let prefixLease: SharedWinePrefixLease
        let ownsLease: Bool
        if let lease {
            guard lease.prefix.identity == WineVersionManager.sharedPrefixIdentity,
                  lease.prefix.runtimeIdentity == runtime.identity,
                  activePrefixLease?.id == lease.id else {
                throw WineError.environmentNotReady("共享 prefix lease 与 runtime 不匹配")
            }
            prefixLease = lease
            ownsLease = false
        } else {
            prefixLease = try await acquireSharedPrefixLease()
            ownsLease = true
        }
        let wineBinary = try await load(runtime: runtime).path
        let prefixURL = prefixLease.prefix.url
        let prefixPath = prefixURL.path
        let alreadyReady = isSharedPrefixReady(at: prefixURL)
        await applyManagedDisplaySettings(wineBinary: wineBinary, prefixPath: prefixPath)
        if alreadyReady {
            await logWriter?.record(.init(
                level: .info,
                module: "WineRuntimeProvider",
                eventName: "wine.prefix.readiness",
                wineTag: runtime.tagName,
                phase: "prepare",
                result: "completed",
                messageCode: "wine.prefix.ready"
            ))
            if ownsLease { try releaseSharedPrefixLease(prefixLease) }
            return PreparedPrefix(url: prefixURL)
        }

        let prefixExistedBefore = FileManager.default.fileExists(atPath: prefixPath)
        do {
            try FileManager.default.createDirectory(at: prefixURL, withIntermediateDirectories: true)
            let environment = ManagedWineLocale.environment(adding: [
                "WINEPREFIX": prefixPath,
                "WINEDLLOVERRIDES": "winemenubuilder.exe=d"
            ])
            _ = try await processManager.launchAndWait(
                executablePath: wineBinary,
                arguments: ["wineboot", "-u"],
                environment: environment,
                workingDirectory: prefixPath,
                timeout: 60
            )
            try Task.checkCancellation()
            guard FileManager.default.fileExists(atPath: prefixURL.appendingPathComponent("drive_c").path) else {
                throw WineError.prefixCreationFailed("wineboot 完成但 drive_c 未生成")
            }
            await applyManagedDisplaySettings(wineBinary: wineBinary, prefixPath: prefixPath)
            await logWriter?.record(.init(
                level: .info,
                module: "WineRuntimeProvider",
                eventName: "wine.prefix.readiness",
                wineTag: runtime.tagName,
                phase: "prepare",
                result: "completed",
                messageCode: "wine.prefix.ready"
            ))
            if ownsLease { try releaseSharedPrefixLease(prefixLease) }
            return PreparedPrefix(url: prefixURL)
        } catch is CancellationError {
            await logWriter?.record(.init(
                level: .warning,
                module: "WineRuntimeProvider",
                eventName: "wine.prefix.readiness",
                wineTag: runtime.tagName,
                phase: "prepare",
                result: "cancelled",
                errorCategory: "userCancelled",
                messageCode: "wine.prefix.cancelled"
            ))
            if !prefixExistedBefore {
                do { try FileManager.default.removeItem(at: prefixURL) }
                catch {
                    if ownsLease { try? releaseSharedPrefixLease(prefixLease) }
                    throw WineError.recoveryRequired("准备已取消，未完成前缀清理失败: \(error.localizedDescription)")
                }
            }
            if ownsLease { try? releaseSharedPrefixLease(prefixLease) }
            throw WineError.cancelled
        } catch let error as WineError {
            await logWriter?.record(.init(
                level: .error,
                module: "WineRuntimeProvider",
                eventName: "wine.prefix.readiness",
                wineTag: runtime.tagName,
                phase: "prepare",
                result: "failed",
                errorCategory: "processStartFailed",
                messageCode: "wine.prefix.failed"
            ))
            let originalDetail = error.localizedDescription
            if !prefixExistedBefore {
                do { try FileManager.default.removeItem(at: prefixURL) }
                catch {
                    if ownsLease { try? releaseSharedPrefixLease(prefixLease) }
                    throw WineError.recoveryRequired("\(originalDetail); 未完成前缀清理失败: \(error.localizedDescription)")
                }
            }
            if ownsLease { try? releaseSharedPrefixLease(prefixLease) }
            throw error
        } catch {
            await logWriter?.record(.init(
                level: .error,
                module: "WineRuntimeProvider",
                eventName: "wine.prefix.readiness",
                wineTag: runtime.tagName,
                phase: "prepare",
                result: "failed",
                errorCategory: "processStartFailed",
                messageCode: "wine.prefix.failed"
            ))
            let originalDetail = error.localizedDescription
            if !prefixExistedBefore {
                do { try FileManager.default.removeItem(at: prefixURL) }
                catch {
                    if ownsLease { try? releaseSharedPrefixLease(prefixLease) }
                    throw WineError.recoveryRequired("\(originalDetail); 未完成前缀清理失败: \(error.localizedDescription)")
                }
            }
            if ownsLease { try? releaseSharedPrefixLease(prefixLease) }
            throw WineError.prefixCreationFailed(originalDetail)
        }
    }

    /// Legacy test/migration seam. Production code must use the managed runtime
    /// overload above.
    internal func preparePrefix(for gameID: String, runtimePath: String) async throws -> String {
        let runtimeURL = URL(fileURLWithPath: runtimePath)
        let rootURL: URL
        switch runtimeURL.lastPathComponent {
        case "wine":
            rootURL = runtimeURL.deletingLastPathComponent().deletingLastPathComponent()
        case "bin":
            rootURL = runtimeURL.deletingLastPathComponent()
        default:
            rootURL = runtimeURL
        }
        let runtime = ManagedWineRuntime(
            tagName: rootURL.lastPathComponent,
            rootURL: rootURL
        )
        _ = gameID
        return try await prepareSharedPrefix(runtime: runtime).path
    }

    internal func isPrefixReady(for gameID: String) async -> Bool {
        _ = gameID
        return await isSharedPrefixReady()
    }

    internal func getPrefixPath(for gameID: String) async -> String {
        _ = gameID
        return await sharedPrefixURL().path
    }

    internal func isSharedPrefixReady() async -> Bool {
        isSharedPrefixReady(at: await sharedPrefixURL())
    }

    private func isSharedPrefixReady(at prefixURL: URL) -> Bool {
        let root = prefixURL.resolvingSymlinksInPath().standardizedFileURL
        let parent = root.deletingLastPathComponent()
        return root.path.hasPrefix(parent.path + "/")
            && FileManager.default.fileExists(atPath: root.appendingPathComponent("drive_c").path)
            && FileManager.default.fileExists(atPath: root.appendingPathComponent("dosdevices").path)
    }
}
