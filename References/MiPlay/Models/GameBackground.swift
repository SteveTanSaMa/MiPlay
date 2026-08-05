//
//  GameBackground.swift
//  MiPlay
//
//  Created by Steve Tan on 2026/6/20.
//

import Foundation

// MARK: - HoyoPlay API 响应模型

struct HoyoConnectResponse: Codable {
    let data: HoyoConnectData
}

struct HoyoConnectData: Codable {
    let gameInfoList: [GameInfo]

    enum CodingKeys: String, CodingKey {
        case gameInfoList = "game_info_list"
    }
}

struct GameInfo: Codable {
    let game: GameBiz
    let backgrounds: [GameBackground]
}

struct GameBiz: Codable {
    let biz: String
}

struct GameBackground: Codable {
    let background: BackgroundURL
    let icon: IconURL?
    let video: VideoInfo?
    let theme: ThemeURL?
    let type: String
}

struct BackgroundDisplayData {
    let backgroundURL: URL
    let iconURL: URL?
    let themeURL: URL?
}

struct BackgroundURL: Codable {
    let url: String
}

struct IconURL: Codable {
    let url: String
    let hoverURL: String?

    enum CodingKeys: String, CodingKey {
        case url
        case hoverURL = "hover_url"
    }
}

struct VideoInfo: Codable {
    let url: String
    let size: Int
}

struct ThemeURL: Codable {
    let url: String
}

// MARK: - 背景填充模式

enum BackgroundFillMode: String, Codable, CaseIterable {
    case fill = "fill"
    case fit = "fit"

    var displayName: String {
        switch self {
        case .fill: return "填充"
        case .fit: return "缩放"
        }
    }
}
