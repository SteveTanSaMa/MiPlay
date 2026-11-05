//
//  SettingsViewModelModels.swift
//  MiPlay
//

import Foundation

// Source: Architecture Design -> ViewModel Layer -> SettingsViewModel

/// 下载入口只消费已读取的版本证据；实际写入前由调度器重新验证目录和区服。
enum GameDownloadPresentation {
    enum MainlandEligibility: Equatable {
        case confirmed
        case requiresConfirmation
        case unsupported
    }

    static func isActive(_ task: ScheduledTask?) -> Bool {
        task?.state == .pending || task?.state == .running
    }

    static func pauseButtonLabel(for task: ScheduledTask) -> String {
        task.type == .gameInstall || task.type == .gameUpdate ? "暂停" : "取消"
    }

    static func resumeButtonLabel(for task: ScheduledTask) -> String {
        switch task.type {
        case .gameInstall: return "继续安装"
        case .gameUpdate: return "继续更新"
        case .gamePredownload: return "继续预下载"
        default: return "继续"
        }
    }

    static func pausedMessage(for task: ScheduledTask) -> String {
        switch task.type {
        case .gameInstall: return "安装已暂停，已下载的资源会在继续时重新校验。"
        case .gameUpdate: return "更新已暂停，已完成的安装进度会在继续时重新校验。更新完成前无法启动游戏。"
        case .gamePredownload: return "预下载已取消，继续时会重新校验缓存。"
        default: return "任务已取消。"
        }
    }

    static func shouldProject(_ task: ScheduledTask, replacing previous: ScheduledTask?) -> Bool {
        guard let previous else { return true }
        if previous.id == task.id { return task.revision >= previous.revision }
        return task.createdAt >= previous.createdAt
    }

    static func mainlandEligibility(for game: Game) -> MainlandEligibility {
        guard game.location?.bookmarkData != nil else { return .unsupported }
        let recovering = game.state == .gameUpdating
        if let metadata = game.lastMetadata,
           !metadata.conflictDetails.isEmpty || metadata.outcome == .versionEvidenceConflict { return .unsupported }
        let expectedBiz = game.type.definition.mainlandBiz
        let evidence = game.lastMetadata?.localEvidence
        var identityConfirmed = false
        if let raw = evidence?.configFields.last(where: { $0.section == "General" && $0.key == "uapc" })?.value,
           !raw.isEmpty {
            guard let data = raw.data(using: .utf8),
                  let identity = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  identity[expectedBiz] != nil,
                  !identity.keys.contains(where: { $0.hasSuffix("_global") }) else { return .unsupported }
            identityConfirmed = true
        }
        if let channel = evidence?.channel, !channel.isEmpty, channel != "1" { return .unsupported }
        if let subChannel = evidence?.subChannel, !subChannel.isEmpty, subChannel != "1" { return .unsupported }
        if let cps = evidence?.cps, !cps.isEmpty, cps.lowercased() != "mihoyo" { return .unsupported }
        guard game.metadataFailure == nil, evidence?.channel == "1", evidence?.subChannel == "1",
              evidence?.cps?.lowercased() == "mihoyo" else {
            // 核心验证中断事务与磁盘证据；UI只允许用户明确确认后提交。
            return recovering ? .requiresConfirmation : .unsupported
        }
        if identityConfirmed { return .confirmed }
        // 星穹铁道双区服可使用相同数字渠道，缺少身份时必须由用户明确确认。
        return game.type.definition.requiresMainlandIdentityConfirmation ? .requiresConfirmation : .confirmed
    }

    static func supportsChinaUpdate(_ game: Game) -> Bool {
        game.type.definition.contentCapabilities.sophonUpdate && mainlandEligibility(for: game) != .unsupported
    }

    static func canSubmitUpdate(for game: Game, task: ScheduledTask? = nil) -> Bool {
        [.installed, .updateAvailable, .launchFailed, .gameUpdating].contains(game.state)
            && !isActive(task) && supportsChinaUpdate(game)
    }

    static func canResume(_ task: ScheduledTask?, for game: Game) -> Bool {
        guard let task, task.context["recoveryOnly"] != "true", task.gameId == game.id,
              task.state == .failed || task.state == .cancelled else { return false }
        switch task.type {
        case .gameInstall:
            guard game.type.definition.contentCapabilities.sophonInstall, game.state == .notInstalled,
                  let encoded = task.context["installBookmark"],
                  let data = Data(base64Encoded: encoded), !data.isEmpty else { return false }
            return true
        case .gameUpdate:
            return canSubmitUpdate(for: game, task: task)
        case .gamePredownload:
            return canPredownload(game, task: task) && task.context["predownloadVersion"]?.isEmpty == false
                && task.context["predownloadLocationBookmark"] == game.location?.bookmarkData?.base64EncodedString()
        default:
            return false
        }
    }

    static func canPredownload(_ game: Game, task: ScheduledTask? = nil) -> Bool {
        [.installed, .updateAvailable, .launchFailed, .running].contains(game.state)
            && !isActive(task) && game.type.definition.contentCapabilities.sophonPredownload
            && mainlandEligibility(for: game) != .unsupported
    }

    static func canReauthorizeDirectory(for game: Game, task: ScheduledTask? = nil) -> Bool {
        game.state == .gameUpdating && !isActive(task)
            && game.location?.lastKnownPath?.isEmpty == false
    }

    static func mainlandConfirmationContext(for game: Game, bookmark: Data?) throws -> [String: String] {
        guard let bookmark, !bookmark.isEmpty, game.location?.bookmarkData == bookmark else {
            throw GameRegistry.RegistrationError.permissionRequired("游戏目录已变化，请重新确认当前目录的国服身份。")
        }
        return ["confirmedMainland": "true", "confirmedLocationBookmark": bookmark.base64EncodedString()]
    }

    /// 历史路径只供显示；续传必须重新打开原授权书签并把刷新后的凭据写入新任务。
    static func refreshedInstallContext(
        from task: ScheduledTask,
        game: Game,
        repository: GameFileSystemRepository
    ) throws -> [String: String] {
        guard task.type == .gameInstall, canResume(task, for: game),
              let encoded = task.context["installBookmark"], let bookmark = Data(base64Encoded: encoded) else {
            throw GameRegistry.RegistrationError.permissionRequired("没有可继续的安装目录授权，请重新选择安装目录。")
        }
        let location = GameLocation(gameID: game.id, bookmarkData: bookmark,
                                    lastKnownPath: task.context["installPath"], scope: .readWrite,
                                    resolutionState: .resolvable)
        let access = try repository.acquireSecurityScopedAccess(location)
        defer { access.stop() }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: access.url.path, isDirectory: &isDirectory), isDirectory.boolValue,
              let refreshed = access.resolvedLocation.bookmarkData else {
            throw GameRegistry.RegistrationError.permissionRequired("原安装目录不可用，请重新选择安装目录。")
        }
        var context = task.context
        context["installBookmark"] = refreshed.base64EncodedString()
        context["installPath"] = access.url.path
        return context
    }

    static func resultConfirmed(for task: ScheduledTask, game: Game?) -> Bool {
        guard task.type == .gameInstall || task.type == .gameUpdate || task.type == .gamePredownload else { return false }
        if task.type == .gamePredownload {
            return task.state == .completed && task.outcome == "gamePredownloaded"
                && task.gameId == game?.id && game?.location?.bookmarkData != nil
                && task.context["predownloadLocationPath"]?.isEmpty == false
                && task.context["predownloadLocationPath"] == game?.location?.lastKnownPath
        }
        if task.context["recoveryOnly"] == "true" {
            return task.state == .completed && task.outcome == "gameRecovered"
                && task.gameId == game?.id && game?.state != .gameUpdating
                && game?.location?.bookmarkData != nil
        }
        let expected = task.type == .gameInstall ? "gameInstalled" : "gameUpdated"
        guard task.state == .completed, task.outcome == expected,
              let game, task.gameId == game.id,
              game.state != .notInstalled, game.state != .gameUpdating,
              game.location?.bookmarkData != nil,
              let version = game.version, !version.isEmpty else { return false }
        return true
    }
}

extension SettingsViewModel {
    /// Wine 下载进度
    public struct WineDownloadProgress: Sendable {
        public let phase: String
        public let progress: Double?
        public let bytesReceived: Int64?
        public let totalBytes: Int64?
        public let speed: Double?

        public init(
            phase: String,
            progress: Double?,
            bytesReceived: Int64? = nil,
            totalBytes: Int64? = nil,
            speed: Double? = nil
        ) {
            self.phase = phase
            self.progress = progress
            self.bytesReceived = bytesReceived
            self.totalBytes = totalBytes
            self.speed = speed
        }
    }

    /// Wine 状态文本
    public enum WineStatusText: Sendable {
        case ready(version: String)
        case notSelected
        case notDownloaded
        case prefixNotReady(gameID: String?)
        case error(String)
        case unknown

        public var label: String {
            switch self {
            case .ready(let version): return "已就绪 (\(version))"
            case .notSelected: return "未选择托管 Wine"
            case .notDownloaded: return "未下载托管 Wine"
            case .prefixNotReady(let gameID):
                if let gameID { return "游戏前缀未就绪 (\(gameID))" }
                return "游戏前缀未就绪"
            case .error(let detail): return "运行环境错误: \(detail)"
            case .unknown: return "检测中…"
            }
        }
    }

    /// 关于信息
    public struct AboutInfo: Sendable {
        public let appVersion: String
        public let buildNumber: String
        public let license: String

        public init() {
            self.appVersion = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0"
            self.buildNumber = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "1"
            self.license = "MIT License"
        }
    }
}
