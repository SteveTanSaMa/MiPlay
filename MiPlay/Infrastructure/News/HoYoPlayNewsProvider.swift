import Foundation

/// Optional launcher content, isolated from launch and Wine preparation.
actor HoYoPlayNewsProvider: GameNewsProviding {
    private let network: NetworkDownloadProvider
    private let logger: LogWriter
    private let cacheDirectory: URL
    private var memory: [GameType: GameNews] = [:]

    init(network: NetworkDownloadProvider, logger: LogWriter, cacheDirectory: URL? = nil) {
        self.network = network
        self.logger = logger
        self.cacheDirectory = cacheDirectory ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("MiPlay/GameNews-v1", isDirectory: true)
    }

    func cachedNews(for game: GameType) -> GameNews? {
        if let cached = memory[game] { return cached }
        guard let bytes = try? Data(contentsOf: cacheURL(for: game)),
              let cached = try? JSONDecoder().decode(GameNews.self, from: bytes),
              cached.game == game,
              cached.banners.allSatisfy({ GameNews.webURL($0.link.absoluteString) != nil && GameNews.webURL($0.imageURL.absoluteString) != nil }),
              cached.posts.allSatisfy({ GameNews.webURL($0.link.absoluteString) != nil }) else { return nil }
        memory[game] = cached
        return cached
    }

    func fetchNews(for game: GameType) async throws -> GameNews {
        do {
            let data = try await network.requestData(from: Self.endpoint(for: game))
            try Task.checkCancellation()
            let news = try Self.decode(data, for: game)
            memory[game] = news
            do {
                try FileManager.default.createDirectory(at: cacheDirectory, withIntermediateDirectories: true)
                try JSONEncoder().encode(news).write(to: cacheURL(for: game), options: .atomic)
            } catch {
                await logger.warning("新闻缓存写入失败", module: "GameNews")
            }
            return news
        } catch {
            if !Task.isCancelled {
                await logger.warning("新闻加载失败: \(error.localizedDescription)", module: "GameNews")
            }
            throw error
        }
    }

    private func cacheURL(for game: GameType) -> URL {
        cacheDirectory.appendingPathComponent("\(game.rawValue)-cn-zh-cn.json")
    }

    // Same official China source as MiPlay's background service. Keep API IDs separate from GameType.
    nonisolated static func identity(for game: GameType) -> (id: String, biz: String) {
        switch game {
        case .genshinImpact: ("1Z8W5NHUQb", "hk4e_cn")
        case .honkaiStarRail: ("64kMb5iAWu", "hkrpg_cn")
        case .zenlessZoneZero: ("x6znKlJ0xK", "nap_cn")
        }
    }

    nonisolated static func endpoint(for game: GameType) throws -> URL {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "hyp-api.mihoyo.com"
        components.path = "/hyp/hyp-connect/api/getGameContent"
        components.queryItems = [
            URLQueryItem(name: "launcher_id", value: "jGHBHlcOq1"),
            URLQueryItem(name: "language", value: "zh-cn"),
            URLQueryItem(name: "game_id", value: identity(for: game).id)
        ]
        guard let url = components.url else { throw NewsError.invalidResponse }
        return url
    }

    nonisolated static func decode(_ data: Data, for game: GameType, now: Date = Date()) throws -> GameNews {
        let response = try JSONDecoder().decode(Response.self, from: data)
        let expected = identity(for: game)
        guard response.retcode == 0, let content = response.data?.content,
              content.game.id == expected.id, content.game.biz == expected.biz else {
            throw NewsError.invalidResponse
        }
        var bannerIDs: Set<String> = []
        let banners = (content.banners ?? []).compactMap { entry -> GameNews.Banner? in
            guard !entry.id.isEmpty, let image = GameNews.webURL(entry.image.url),
                  image.scheme == "https", let link = GameNews.webURL(entry.image.link),
                  bannerIDs.insert(entry.id).inserted else { return nil }
            return .init(id: entry.id, imageURL: image, link: link)
        }
        var postIDs: Set<String> = []
        let posts = (content.posts ?? []).compactMap { entry -> GameNews.Post? in
            guard !entry.id.isEmpty, !entry.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  let category = GameNewsCategory(rawValue: entry.type),
                  let link = GameNews.webURL(entry.link), postIDs.insert(entry.id).inserted else { return nil }
            return .init(id: entry.id, category: category, title: entry.title, date: entry.date, link: link)
        }
        return GameNews(game: game, banners: banners, posts: posts, fetchedAt: now)
    }

    nonisolated enum NewsError: Error { case invalidResponse }
    nonisolated private struct Response: Decodable {
        let retcode: Int
        let data: Payload?
        struct Payload: Decodable { let content: Content? }
        struct Content: Decodable {
            let game: Identity
            let banners: [Banner]?
            let posts: [Post]?
        }
        struct Identity: Decodable { let id: String; let biz: String }
        struct Banner: Decodable {
            let id: String
            let image: BannerImage
        }
        struct BannerImage: Decodable { let url: String; let link: String }
        struct Post: Decodable {
            let id: String
            let type: String
            let title: String
            let date: String
            let link: String
        }
    }
}
