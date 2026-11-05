// BackgroundMediaModels.swift
// MiPlay

import Foundation

// Source: Architecture Design -> Service Contract -> BackgroundMediaService
// HoyoPlay response models are infrastructure-facing data contracts.
// MARK: - HoyoPlay API 响应模型（基于实际 API 格式）

/// 顶层响应
struct HoyoPlayResponse: Codable, @unchecked Sendable {
    let retcode: Int
    let message: String?
    let data: HoyoPlayData

    nonisolated init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.retcode = try container.decode(Int.self, forKey: .retcode)
        self.message = try container.decodeIfPresent(String.self, forKey: .message)
        self.data = try container.decode(HoyoPlayData.self, forKey: .data)
    }
}

struct HoyoPlayData: Codable, @unchecked Sendable {
    let gameInfoList: [HoyoPlayGameEntry]

    enum CodingKeys: String, CodingKey {
        case gameInfoList = "game_info_list"
    }

    nonisolated init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.gameInfoList = try container.decode([HoyoPlayGameEntry].self, forKey: .gameInfoList)
    }
}

/// 单个游戏条目
struct HoyoPlayGameEntry: Codable, @unchecked Sendable {
    let game: HoyoPlayGameID
    let backgrounds: [HoyoPlayBackground]

    nonisolated init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.game = try container.decode(HoyoPlayGameID.self, forKey: .game)
        self.backgrounds = try container.decode([HoyoPlayBackground].self, forKey: .backgrounds)
    }
}

/// 游戏 ID 信息
struct HoyoPlayGameID: Codable, @unchecked Sendable {
    let id: String
    let biz: String
}

/// 单个背景素材条目
struct HoyoPlayBackground: Codable, @unchecked Sendable {
    let id: String
    let background: HoyoPlayMediaURL?
    let icon: HoyoPlayIcon?
    let video: HoyoPlayMediaURL?
    let theme: HoyoPlayMediaURL?
    let type: String?

    nonisolated init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decodeIfPresent(String.self, forKey: .id) ?? ""
        self.background = try container.decodeIfPresent(HoyoPlayMediaURL.self, forKey: .background)
        self.icon = try container.decodeIfPresent(HoyoPlayIcon.self, forKey: .icon)
        self.video = try container.decodeIfPresent(HoyoPlayMediaURL.self, forKey: .video)
        self.theme = try container.decodeIfPresent(HoyoPlayMediaURL.self, forKey: .theme)
        self.type = try container.decodeIfPresent(String.self, forKey: .type)
    }

    /// Preserve the response order and resources while assigning a safe cache key.
    internal func withCacheID(_ cacheID: String) -> HoyoPlayBackground {
        HoyoPlayBackground(id: cacheID, background: background, icon: icon,
                           video: video, theme: theme, type: type)
    }

    private init(id: String, background: HoyoPlayMediaURL?, icon: HoyoPlayIcon?,
                 video: HoyoPlayMediaURL?, theme: HoyoPlayMediaURL?, type: String?) {
        self.id = id
        self.background = background
        self.icon = icon
        self.video = video
        self.theme = theme
        self.type = type
    }
}

/// 媒体 URL 信息
struct HoyoPlayMediaURL: Codable, @unchecked Sendable {
    let url: String?
    let link: String?
    let loginStateInLink: Bool?

    enum CodingKeys: String, CodingKey {
        case url
        case link
        case loginStateInLink = "login_state_in_link"
    }

    nonisolated init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.url = try container.decodeIfPresent(String.self, forKey: .url)
        self.link = try container.decodeIfPresent(String.self, forKey: .link)
        self.loginStateInLink = try container.decodeIfPresent(Bool.self, forKey: .loginStateInLink)
    }
}

/// 图标信息
struct HoyoPlayIcon: Codable {
    let url: String?
    let hoverURL: String?
    let link: String?
    let loginStateInLink: Bool?
    let md5: String?
    let size: Int?

    enum CodingKeys: String, CodingKey {
        case url
        case hoverURL = "hover_url"
        case link
        case loginStateInLink = "login_state_in_link"
        case md5
        case size
    }
}
