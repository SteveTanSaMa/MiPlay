import Foundation

nonisolated enum GameNewsCategory: String, Codable, CaseIterable, Sendable {
    case activity = "POST_TYPE_ACTIVITY"
    case announcement = "POST_TYPE_ANNOUNCE"
    case info = "POST_TYPE_INFO"

    var title: String {
        switch self {
        case .activity: "活动"
        case .announcement: "公告"
        case .info: "资讯"
        }
    }
}

nonisolated struct GameNews: Codable, Sendable, Equatable {
    struct Banner: Codable, Sendable, Identifiable, Equatable {
        let id: String
        let imageURL: URL
        let link: URL
    }
    struct Post: Codable, Sendable, Identifiable, Equatable {
        let id: String
        let category: GameNewsCategory
        let title: String
        /// HoYoPlay supplies MM/dd without a year. Keep the displayed date unchanged.
        let date: String
        let link: URL
    }
    let game: GameType
    let banners: [Banner]
    let posts: [Post]
    let fetchedAt: Date

    var isEmpty: Bool { banners.isEmpty && posts.isEmpty }
    func posts(in category: GameNewsCategory) -> [Post] {
        let calendar = Calendar(identifier: .gregorian)
        let today = calendar.component(.month, from: fetchedAt) * 32 + calendar.component(.day, from: fetchedAt)
        // Launcher posts are recent. Treat a later month/day as the preceding year
        // at the New Year boundary; never invent a year in the displayed text.
        func order(_ date: String) -> Int {
            let parts = date.split(separator: "/").compactMap { Int($0) }
            guard parts.count == 2, (1...12).contains(parts[0]), (1...31).contains(parts[1]) else { return Int.min }
            let value = parts[0] * 32 + parts[1]
            return value > today ? value - 416 : value
        }
        return posts.enumerated().filter { $0.element.category == category }
            .sorted {
                let left = order($0.element.date), right = order($1.element.date)
                return left == right ? $0.offset < $1.offset : left > right
            }.map(\.element)
    }

    /// Only web links are eligible for browser navigation or image downloads.
    static func webURL(_ value: String) -> URL? {
        guard let url = URL(string: value),
              ["https", "http"].contains(url.scheme?.lowercased() ?? ""),
              let host = url.host, !host.isEmpty,
              url.user == nil, url.password == nil else { return nil }
        return url
    }
}

nonisolated protocol GameNewsProviding: Sendable {
    func cachedNews(for game: GameType) async -> GameNews?
    func fetchNews(for game: GameType) async throws -> GameNews
}
