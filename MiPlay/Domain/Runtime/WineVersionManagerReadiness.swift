// WineVersionManagerReadiness.swift
// MiPlay

import Foundation

// Source: Architecture Design -> ADR-018 -> runtime and prefix readiness
extension WineVersionManager {
    internal func checkRuntimeReadiness() async -> Readiness {
        // Source: Architecture Design -> ADR-018 -> managed runtime only
        guard let tag = selectedVersionTag else {
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

    /// Checks the complete game-specific WineReady gate without creating a
    /// prefix. Prefix creation belongs to the launch preflight and must not be
    /// hidden inside a settings refresh.
    public func checkReadiness(for gameID: String) async -> Readiness {
        let readiness: Readiness
        switch await checkRuntimeReadiness() {
        case .ready(let versionPath):
            guard let wineRuntimeProvider,
                  await wineRuntimeProvider.isPrefixReady(for: gameID) else {
                readiness = .prefixNotReady(gameID: gameID)
                await recordReadiness(readiness, gameID: gameID)
                return readiness
            }
            readiness = .ready(versionPath: versionPath)
        case .notSelected, .notDownloaded, .error, .prefixNotReady:
            readiness = await checkRuntimeReadiness()
        }
        await recordReadiness(readiness, gameID: gameID)
        return readiness
    }

    /// Settings has no implicit game selection. It must not report WineReady
    /// until a game-specific prefix is known to be ready.
    public func checkReadiness() async -> Readiness {
        let readiness: Readiness
        switch await checkRuntimeReadiness() {
        case .ready:
            readiness = .prefixNotReady(gameID: nil)
        case let state:
            readiness = state
        }
        await recordReadiness(readiness, gameID: nil)
        return readiness
    }

    internal func recordReadiness(_ readiness: Readiness, gameID: String?) async {
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
            wineTag: selectedVersionTag,
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
        guard case .ready(let versionPath) = await checkRuntimeReadiness(),
              let tag = selectedVersionTag else { return nil }
        return ManagedWineRuntime(tagName: tag, rootURL: URL(fileURLWithPath: versionPath, isDirectory: true))
    }

    // MARK: - 已安装版本管理

    /// 获取已安装的版本列表
}
