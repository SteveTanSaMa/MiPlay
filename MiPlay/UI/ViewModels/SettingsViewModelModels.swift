//
//  SettingsViewModelModels.swift
//  MiPlay
//

import Foundation

// Source: Architecture Design -> ViewModel Layer -> SettingsViewModel

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
