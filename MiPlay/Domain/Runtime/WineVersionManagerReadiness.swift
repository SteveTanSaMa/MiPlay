// WineVersionManagerReadiness.swift
// MiPlay

import Foundation

// Source: Architecture Design -> ADR-018 -> runtime and prefix readiness
extension WineVersionManager {
    internal func checkRuntimeReadiness() async -> Readiness {
        await checkRuntimeReadiness(for: selectedVersionTag)
    }

    internal func checkRuntimeReadiness(for tag: String?) async -> Readiness {
        // Source: Architecture Design -> ADR-018 -> managed runtime only
        guard let tag else {
            return .notSelected
        }
        guard Self.managedWineTags.contains(tag), installedVersionTags.contains(tag) else {
            return .notDownloaded
        }
        guard BuiltInWineVersions.sourceDescriptor(for: selectedSourceID) != nil,
              BuiltInWineVersions.source(for: tag) != nil else {
            return .error("Wine 来源或版本不在批准清单内")
        }

        let versionsDir = await wineVersionsDirectory()
        let rootURL = versionsDir.appendingPathComponent(tag, isDirectory: true)
        let canonicalRoot = rootURL.resolvingSymlinksInPath().standardizedFileURL
        let canonicalVersionsDir = versionsDir.resolvingSymlinksInPath().standardizedFileURL
        guard canonicalRoot.path.hasPrefix(canonicalVersionsDir.path + "/"),
              FileManager.default.fileExists(atPath: canonicalRoot.path),
              Self.isDirectory(atPath: canonicalRoot.path) else {
            return .notDownloaded
        }
        let wineBinary = canonicalRoot.appendingPathComponent("bin/wine")
        guard FileManager.default.fileExists(atPath: wineBinary.path),
              FileManager.default.isExecutableFile(atPath: wineBinary.path) else {
            return .error("Wine binary 不存在或不可执行")
        }

        if let wineRuntimeProvider {
            do {
                _ = try await wineRuntimeProvider.load(
                    runtime: ManagedWineRuntime(tagName: tag, rootURL: canonicalRoot)
                )
            } catch {
                return .error("Wine runtime 检测失败: \(error.localizedDescription)")
            }
        }
        return .ready(versionPath: canonicalRoot.path)
    }

    /// Checks the public fixed runtime/shared-prefix pair. A Game ID only
    /// scopes the diagnostic result; it never selects a runtime or prefix.
    public func checkReadiness(for gameID: String) async -> Readiness {
        let readiness = await checkReadiness()
        if case .prefixNotReady = readiness {
            let scoped = Readiness.prefixNotReady(gameID: gameID)
            await recordReadiness(scoped, gameID: gameID, wineTag: Self.fixedRuntimeTag)
            return scoped
        }
        await recordReadiness(readiness, gameID: gameID, wineTag: Self.fixedRuntimeTag)
        return readiness
    }

    /// Public readiness for the fixed runtime/shared-prefix pair.
    public func checkReadiness() async -> Readiness {
        let runtimeReadiness = await checkRuntimeReadiness()
        let readiness: Readiness
        switch runtimeReadiness {
        case .ready(let versionPath):
            guard let wineRuntimeProvider,
                  await wineRuntimeProvider.isSharedPrefixReady(),
                  let prefixRecord,
                  prefixRecord.identity == Self.sharedPrefixIdentity,
                  prefixRecord.runtimeIdentity == Self.fixedRuntimeTag,
                  prefixRecord.state == "ready" else {
                readiness = .prefixNotReady(gameID: nil)
                await recordReadiness(readiness, gameID: nil, wineTag: selectedVersionTag)
                return readiness
            }
            readiness = .ready(versionPath: versionPath)
        case let state:
            readiness = state
        }
        await recordReadiness(readiness, gameID: nil, wineTag: selectedVersionTag)
        return readiness
    }

    internal func recordReadiness(
        _ readiness: Readiness,
        gameID: String?,
        wineTag: String?
    ) async {
        let result: String
        let errorCategory: String
        let messageCode: String
        switch readiness {
        case .ready:
            result = "completed"; errorCategory = "none"; messageCode = "wine.readiness.ready"
        case .notSelected:
            result = "unavailable"; errorCategory = "none"; messageCode = "wine.readiness.not_selected"
        case .notDownloaded:
            result = "unavailable"; errorCategory = "resourceNotFound"; messageCode = "wine.readiness.not_downloaded"
        case .prefixNotReady:
            result = "unavailable"; errorCategory = "resourceNotFound"; messageCode = "wine.readiness.prefix_not_ready"
        case .error:
            result = "failed"; errorCategory = "processStartFailed"; messageCode = "wine.readiness.error"
        }
        await logWriter.record(.init(
            level: result == "completed" ? .info : .warning,
            module: "WineVersionManager",
            eventName: "wine.readiness",
            gameID: gameID,
            wineTag: wineTag,
            phase: "check",
            result: result,
            errorCategory: errorCategory,
            messageCode: messageCode
        ))
    }

    /// 获取当前选中版本的完整路径
    internal func getSelectedVersionPath() async -> String? {
        guard let tag = selectedVersionTag,
              Self.managedWineTags.contains(tag),
              installedVersionTags.contains(tag) else { return nil }
        let versionsDir = await wineVersionsDirectory()
        let versionPath = versionsDir.appendingPathComponent(tag, isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        let canonicalRoot = versionsDir.resolvingSymlinksInPath().standardizedFileURL
        guard versionPath.path.hasPrefix(canonicalRoot.path + "/"),
              Self.isDirectory(atPath: versionPath.path),
              FileManager.default.isExecutableFile(atPath: versionPath.appendingPathComponent("bin/wine").path) else {
            return nil
        }
        return versionPath.path
    }

    /// 获取目标 Game 生效版本的完整路径。
    internal func effectiveVersionPath(for gameID: String) async -> String? {
        guard let tag = effectiveVersion(for: gameID),
              Self.managedWineTags.contains(tag),
              installedVersionTags.contains(tag) else { return nil }
        let versionsDir = await wineVersionsDirectory()
        let versionPath = versionsDir.appendingPathComponent(tag, isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        let canonicalRoot = versionsDir.resolvingSymlinksInPath().standardizedFileURL
        guard versionPath.path.hasPrefix(canonicalRoot.path + "/"),
              Self.isDirectory(atPath: versionPath.path),
              FileManager.default.isExecutableFile(atPath: versionPath.appendingPathComponent("bin/wine").path) else {
            return nil
        }
        return versionPath.path
    }

    // MARK: - 生效运行时路径（ADR-018 统一决策者）

    /// Source: Architecture Design → ADR-018 — 生效运行时路径决策
    /// 返回 wine 二进制所在目录路径，供 WineRuntimeProvider.load(runtimePath:) 使用。
    /// 只返回选中的、已安装的 MiPlay 托管版本 bin/ 目录。
    internal func effectiveRuntimePath() async -> String? {
        if case .ready(let versionPath) = await checkRuntimeReadiness() {
            return URL(fileURLWithPath: versionPath).appendingPathComponent("bin").path
        }
        return nil
    }

    /// Returns the managed runtime identity for launch/preflight consumers.
    /// This is the only production path from selection state to the runtime
    /// provider; no caller needs to pass a user-controlled String path.
    public func validatedRuntime() async -> ManagedWineRuntime? {
        guard case .ready(let versionPath) = await checkReadiness(),
              let tag = selectedVersionTag else { return nil }
        return ManagedWineRuntime(tagName: tag, rootURL: URL(fileURLWithPath: versionPath, isDirectory: true))
    }

    /// Returns the managed runtime resolved for a Game ID. Launch preflight
    /// must use this game-scoped API; the no-game variant never produces a
    /// Game-specific WineReady.
    public func validatedRuntime(for gameID: String) async -> ManagedWineRuntime? {
        _ = gameID
        return await validatedRuntime()
    }

    /// Returns the validated shared prefix fact for setup and launch callers.
    public func validatedSharedPrefix() async -> SharedWinePrefix? {
        guard case .ready = await checkReadiness(),
              let prefixRecord,
              prefixRecord.identity == Self.sharedPrefixIdentity,
              prefixRecord.runtimeIdentity == Self.fixedRuntimeTag,
              prefixRecord.state == "ready" else { return nil }
        return SharedWinePrefix(
            identity: prefixRecord.identity,
            url: URL(fileURLWithPath: prefixRecord.absolutePath, isDirectory: true),
            runtimeIdentity: prefixRecord.runtimeIdentity
        )
    }

    /// Acquires the single shared prefix lease only after the persisted pair is
    /// readable and the prefix structure has been verified.
    public func acquireSharedPrefixLease() async throws -> SharedWinePrefixLease {
        guard await validatedRuntime() != nil,
              await validatedSharedPrefix() != nil,
              let wineRuntimeProvider else {
            throw VersionManagerError.recoveryRequired("固定 runtime/shared prefix 尚未就绪")
        }
        do {
            return try await wineRuntimeProvider.acquireSharedPrefixLease()
        } catch let error as WineRuntimeProvider.WineError {
            throw VersionManagerError.recoveryRequired(error.localizedDescription)
        }
    }

    // MARK: - 已安装版本管理

    /// 获取已安装的版本列表
}
