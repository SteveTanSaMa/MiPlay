//
//  WineVersionManager.swift
//  MiPlay
//
//  Created by Steve Tan on 2026/7/7.
//

import Foundation

// Source: Architecture Design → Service Contract → WineVersionManager
// Source: Architecture Design -> ADR 037/038/040 -> fixed runtime setup
// Source: QA Report → F-003 — GitHub API 认证策略 (ADR-017)
// Source: QA Report → F-006 — GitHub API 模型重复定义
// Source: Architecture Design → ADR-018 — WineVersionManager 为统一决策者

// MARK: - Wine 版本管理器（Domain 层）

/// Wine runtime manager for the one fixed runtime/shared-prefix pair.
///
/// 职责范围（Domain 层业务编排，ADR-018 统一决策者）：
/// - fixed catalog validation and setup orchestration
/// - shared prefix readiness and recovery
/// - validated runtime/prefix facts for launch consumers
///
/// 依赖的 Infrastructure 层：
/// - WineVersionDownloader（下载和解压）
/// - GameFileSystemRepository（版本存储目录管理）
/// - PersistenceStore (authoritative runtime/prefix records)
public actor WineVersionManager {
    public static let fixedRuntimeTag = BuiltInWineVersions.fixedTag
    public static let sharedPrefixIdentity = "sharedWinePrefix"
    public enum VersionManagerError: Error, LocalizedError {
        case apiUnavailable(String)
        case apiForbidden(sourceID: String, detail: String)
        case assetForbidden(sourceID: String, detail: String)
        case resourceNotFound(sourceID: String, detail: String)
        case sourceInvalid(String)
        case noAvailableManagedVersion(sourceID: String)
        case downloadFailed(String)
        case extractionFailed(String)
        case versionNotFound(String)
        case diskSpaceInsufficient(String)
        case persistenceFailed(String)
        case rateLimited(retryAfter: Int)
        case cancelled
        case recoveryRequired(String)

        public var errorDescription: String? {
            switch self {
            case .apiUnavailable(let detail):
                return "GitHub API 不可用: \(detail)"
            case .apiForbidden(let sourceID, let detail):
                return "Wine 来源 \(sourceID) 的 API 访问被拒绝: \(detail)"
            case .assetForbidden(let sourceID, let detail):
                return "Wine 来源 \(sourceID) 的下载资源被拒绝: \(detail)"
            case .resourceNotFound(let sourceID, let detail):
                return "Wine 来源 \(sourceID) 的下载资源不存在: \(detail)"
            case .sourceInvalid(let detail):
                return "Wine 来源无效: \(detail)"
            case .noAvailableManagedVersion(let sourceID):
                return "来源 \(sourceID) 没有可用的托管 Wine 版本"
            case .downloadFailed(let detail):
                return "下载失败: \(detail)"
            case .extractionFailed(let detail):
                return "解压失败: \(detail)"
            case .versionNotFound(let id):
                return "版本未找到: \(id)"
            case .diskSpaceInsufficient(let detail):
                return "磁盘空间不足: \(detail)"
            case .persistenceFailed(let detail):
                return "持久化失败: \(detail)"
            case .rateLimited(let retryAfter):
                return "GitHub API 速率限制，请在 \(retryAfter) 秒后重试"
            case .cancelled:
                return "Wine 下载已取消"
            case .recoveryRequired(let detail):
                return "Wine 状态需要恢复: \(detail)"
            }
        }
    }

    /// 版本就绪状态
    public enum Readiness: Sendable, Equatable {
        case ready(versionPath: String)
        case notDownloaded
        case notSelected
        case prefixNotReady(gameID: String?)
        case error(String)
    }

    // MARK: - Cache

    /// Fixed catalog cache (metadata only; never a user selection).
    internal var cachedVersions: [WineVersionInfo]?
    internal var cacheTimestamp: Date?

    // MARK: - Persisted State

    /// Legacy compatibility state. It is derived only from the canonical record.
    internal var selectedVersionTag: String?
    /// Kept empty after schema 4 migration. It must never participate in runtime
    /// resolution.
    internal var perGameOverrides: [String: String] = [:]
    internal var selectedSourceID: String = BuiltInWineVersions.officialSource.sourceID
    /// Legacy compatibility state, containing at most the fixed identity.
    internal var installedVersionTags: Set<String> = []
    internal var runtimeRecord: ManagedWineRuntimeRecord?
    internal var prefixRecord: SharedWinePrefixRecord?

    // MARK: - Dependencies

    internal let networkProvider: NetworkDownloadProvider
    internal let fileSystemRepository: GameFileSystemRepository
    internal let persistenceStore: PersistenceStore
    internal let wineVersionDownloader: WineVersionDownloader
    internal let logWriter: LogWriter
    internal let wineRuntimeProvider: WineRuntimeProvider?
    internal nonisolated static let managedWineTags: Set<String> = [fixedRuntimeTag]
    internal var activeDownloadTasks: [UUID: Task<Void, Never>] = [:]
    internal var activeDownloadTags: [UUID: String] = [:]

    public init(
        networkProvider: NetworkDownloadProvider,
        fileSystemRepository: GameFileSystemRepository,
        persistenceStore: PersistenceStore,
        wineVersionDownloader: WineVersionDownloader,
        logWriter: LogWriter,
        wineRuntimeProvider: WineRuntimeProvider? = nil
    ) {
        self.networkProvider = networkProvider
        self.fileSystemRepository = fileSystemRepository
        self.persistenceStore = persistenceStore
        self.wineVersionDownloader = wineVersionDownloader
        self.logWriter = logWriter
        self.wineRuntimeProvider = wineRuntimeProvider
    }

    // MARK: - Initialization

    /// 从 AppData 恢复状态
    public func initialize() async {
        do {
            let appData = try await persistenceStore.readAppData()
            selectedSourceID = BuiltInWineVersions.officialSource.sourceID
            runtimeRecord = appData.managedWineRuntime?.identity == Self.fixedRuntimeTag
                ? appData.managedWineRuntime
                : nil
            prefixRecord = appData.sharedWinePrefix?.identity == Self.sharedPrefixIdentity
                ? appData.sharedWinePrefix
                : nil
            selectedVersionTag = runtimeRecord?.identity
            installedVersionTags = runtimeRecord == nil ? [] : [Self.fixedRuntimeTag]
            perGameOverrides = [:]
            await logWriter.info("Wine 运行时管理器已初始化: \(runtimeRecord == nil ? "未安装" : "已安装")，共享 prefix: \(prefixRecord == nil ? "未准备" : "已准备")", module: "WineVersionManager")
            await logWriter.record(.init(
                level: .info,
                module: "WineVersionManager",
                eventName: "wine.manager.initialized",
                wineTag: runtimeRecord?.identity,
                phase: "initialized",
                result: "completed",
                messageCode: "wine.manager.initialized",
                fields: ["runtimeIdentity": Self.fixedRuntimeTag, "prefixIdentity": Self.sharedPrefixIdentity]
            ))
        } catch {
            await logWriter.warning("Wine 版本管理器初始化失败: \(error.localizedDescription)", module: "WineVersionManager")
            await logWriter.record(.init(
                level: .error,
                module: "WineVersionManager",
                eventName: "wine.manager.initialized",
                phase: "initialized",
                result: "failed",
                errorCategory: "persistenceCorrupted",
                messageCode: "wine.manager.initialize_failed"
            ))
        }
    }

    public func wineVersionsDirectory() async -> URL {
        let baseDir = await fileSystemRepository.appSupportDirectory()
        let dir = baseDir.appendingPathComponent("WineVersions", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    // MARK: - 游戏运行设置（Metal HUD / 帧率 / Retina / 左 Command）

    /// 持久化的应用级游戏运行设置。
    public func gameEnvironmentSettings() async -> GameEnvironmentSettings {
        (try? await persistenceStore.readAppData())?.gameEnvironmentSettings ?? GameEnvironmentSettings()
    }

    /// 更新并持久化设置。注册表项在下一次准备 prefix / 启动游戏时写入
    /// （与 YAAGL 每次启动前 `setProps` 的时机一致）；Metal HUD 等环境变量在下一次启动游戏时注入。
    public func updateGameEnvironmentSettings(_ settings: GameEnvironmentSettings) async throws {
        do {
            try await persistenceStore.updateAppData { data in
                data.gameEnvironmentSettings = settings
            }
        } catch {
            throw VersionManagerError.persistenceFailed(error.localizedDescription)
        }
    }

    /// Completes setup for a valid runtime already staged under MiPlay's own
    /// managed directory. This avoids an unnecessary catalog/API dependency
    /// when a previous download completed but the app was interrupted before
    /// prefix preparation or AppData commit.
    public func setupExistingManagedRuntimeIfPresent() async throws -> Bool {
        guard let wineRuntimeProvider else {
            throw VersionManagerError.recoveryRequired("缺少固定 Wine runtime provider")
        }
        let versionsDir = await wineVersionsDirectory()
        let rootURL = versionsDir
            .appendingPathComponent(Self.fixedRuntimeTag, isDirectory: true)
            .resolvingSymlinksInPath()
            .standardizedFileURL
        let canonicalVersionsDir = versionsDir.resolvingSymlinksInPath().standardizedFileURL
        guard FileManager.default.fileExists(atPath: rootURL.path) else {
            return false
        }
        guard rootURL.path.hasPrefix(canonicalVersionsDir.path + "/"),
              Self.isDirectory(atPath: rootURL.path),
              FileManager.default.isExecutableFile(
                atPath: rootURL.appendingPathComponent("bin/wine").path
              ) else {
            throw VersionManagerError.recoveryRequired("MiPlay 托管的 Wine 目录存在，但 binary 不完整")
        }

        let runtime = ManagedWineRuntime(tagName: Self.fixedRuntimeTag, rootURL: rootURL)
        _ = try await wineRuntimeProvider.load(runtime: runtime)
        try await markVersionInstalled(tagName: Self.fixedRuntimeTag)
        try await prepareAndCommitSharedPrefix(runtime: runtime)
        return true
    }
}
