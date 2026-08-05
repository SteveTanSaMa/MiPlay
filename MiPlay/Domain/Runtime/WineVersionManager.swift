//
//  WineVersionManager.swift
//  MiPlay
//
//  Created by Steve Tan on 2026/7/7.
//

import Foundation

// Source: Architecture Design → Service Contract → WineVersionManager
// Source: Architecture Design → ADR 011 → Domain + Infrastructure 双层分离
// Source: Product Definition → Feature List → Must: Wine 版本管理
// Source: QA Report → F-003 — GitHub API 认证策略 (ADR-017)
// Source: QA Report → F-006 — GitHub API 模型重复定义
// Source: Architecture Design → ADR-018 — WineVersionManager 为统一决策者

// MARK: - Wine 版本管理器（Domain 层）

/// Wine 版本管理器。负责运行时环境版本的全生命周期管理。
///
/// 职责范围（Domain 层业务编排，ADR-018 统一决策者）：
/// - 版本发现（从 GitHub Release API 获取可用版本列表，含缓存和可选认证）
/// - 版本下载编排（委托 WineVersionDownloader 执行实际下载和解压）
/// - 版本选中/删除
/// - 版本就绪状态报告
/// - 生效运行时路径决策（仅返回已验证的 MiPlay 托管版本）
///
/// 依赖的 Infrastructure 层：
/// - WineVersionDownloader（下载和解压）
/// - GameFileSystemRepository（版本存储目录管理）
/// - PersistenceStore（持久化选中版本和已安装版本列表）
public actor WineVersionManager {
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

    /// 可用版本列表缓存（60 分钟有效期）
    internal var cachedVersions: [WineVersionInfo]?
    internal var cacheTimestamp: Date?

    // MARK: - Persisted State

    /// 当前选中的版本标识（持久化）
    internal var selectedVersionTag: String?
    internal var selectedSourceID: String = BuiltInWineVersions.officialSource.sourceID
    /// 已安装版本列表（持久化）
    internal var installedVersionTags: Set<String> = []

    // MARK: - Dependencies

    internal let networkProvider: NetworkDownloadProvider
    internal let fileSystemRepository: GameFileSystemRepository
    internal let persistenceStore: PersistenceStore
    internal let wineVersionDownloader: WineVersionDownloader
    internal let logWriter: LogWriter
    internal let wineRuntimeProvider: WineRuntimeProvider?
    internal nonisolated static let managedWineTags: Set<String> = Set(
        BuiltInWineVersions.allSources().map(\.tagName)
    )
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
            selectedVersionTag = appData.selectedWineVersion.flatMap {
                Self.managedWineTags.contains($0) ? $0 : nil
            }
            selectedSourceID = BuiltInWineVersions.sourceDescriptor(
                for: appData.selectedWineSource ?? BuiltInWineVersions.officialSource.sourceID
            )?.sourceID ?? BuiltInWineVersions.officialSource.sourceID
            installedVersionTags = Set(appData.installedWineVersions.filter { Self.managedWineTags.contains($0) })
            await logWriter.info("Wine 版本管理器已初始化: \(installedVersionTags.count) 个已安装, 选中: \(selectedVersionTag ?? "无")", module: "WineVersionManager")
            await logWriter.record(.init(
                level: .info,
                module: "WineVersionManager",
                eventName: "wine.manager.initialized",
                wineTag: selectedVersionTag,
                phase: "initialized",
                result: "completed",
                messageCode: "wine.manager.initialized",
                fields: ["installedCount": String(installedVersionTags.count), "sourceID": selectedSourceID]
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
}
