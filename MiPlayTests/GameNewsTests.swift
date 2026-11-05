import XCTest
@testable import MiPlay

@MainActor extension MiPlayCoreTests {
    func testBuiltInGameDefinitionsPreserveOfficialIdentitiesAndExecutableLocations() {
        let cases: [(GameType, String, String, String, String, String)] = [
            (.genshinImpact, "GenshinImpact", "1Z8W5NHUQb", "hk4e_cn", "hk4e_global", "YuanShen.exe"),
            (.honkaiStarRail, "HonkaiStarRail", "64kMb5iAWu", "hkrpg_cn", "hkrpg_global", "StarRail.exe"),
            (.zenlessZoneZero, "ZenlessZoneZero", "x6znKlJ0xK", "nap_cn", "nap_global", "ZenlessZoneZero.exe")
        ]
        for (game, persistedID, gameID, mainlandBiz, globalBiz, executable) in cases {
            XCTAssertEqual(game.rawValue, persistedID)
            XCTAssertEqual(game.definition.mainlandGameID, gameID)
            XCTAssertEqual(game.definition.mainlandBiz, mainlandBiz)
            XCTAssertEqual(game.definition.globalBiz, globalBiz)
            XCTAssertEqual(game.definition.mainlandExecutableName, executable)
            XCTAssertTrue(game.executableNames.contains(executable))
            XCTAssertTrue(game.executableRelativePaths.contains(executable))
            XCTAssertEqual(HoYoPlayNewsProvider.identity(for: game).id, gameID)
            XCTAssertEqual(HoYoPlayNewsProvider.identity(for: game).biz, mainlandBiz)
            XCTAssertEqual(GameIconProvider.candidateBizIDs(for: game), [mainlandBiz, globalBiz])
        }
        XCTAssertEqual(Set(GameType.allCases.map { $0.definition.mainlandGameID }).count, GameType.allCases.count)
        XCTAssertEqual(Set(GameType.allCases.map { $0.definition.mainlandBiz }).count, GameType.allCases.count)
        XCTAssertFalse(GameType.genshinImpact.definition.requiresMainlandIdentityConfirmation)
        XCTAssertTrue(GameType.honkaiStarRail.definition.requiresMainlandIdentityConfirmation)
        XCTAssertFalse(GameType.zenlessZoneZero.definition.requiresMainlandIdentityConfirmation)
    }

    func testIconIdentityCandidatesAllowMainlandOnlyGames() {
        func definition(globalBiz: String?) -> BuiltInGameDefinition {
            BuiltInGameDefinition(
                displayName: "test", englishName: "test", settingsSidebarTitle: "test", symbolName: "gamecontroller",
                mainlandGameID: "test-cn", mainlandBiz: "test_cn", globalBiz: globalBiz,
                requiresMainlandIdentityConfirmation: false,
                contentCapabilities: .init(sophonInstall: false, sophonUpdate: false, sophonPredownload: false),
                officialDownloadURL: nil, mainlandExecutableName: "test.exe",
                executableNames: ["test.exe"], executableRelativePaths: ["test.exe"],
                versionFileRelativePath: "config.ini", minimumDiskSpaceRequired: 0
            )
        }
        XCTAssertEqual(GameIconProvider.candidateBizIDs(for: definition(globalBiz: nil)), ["test_cn"])
        XCTAssertEqual(GameIconProvider.candidateBizIDs(for: definition(globalBiz: "")), ["test_cn"])
    }

    func testNewsDatesSortNewestFirstAcrossNewYear() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 1, day: 3)))
        let link = try XCTUnwrap(URL(string: "https://www.miyoushe.com"))
        let news = GameNews(game: .genshinImpact, banners: [], posts: [
            .init(id: "old", category: .activity, title: "old", date: "12/31", link: link),
            .init(id: "new", category: .activity, title: "new", date: "01/02", link: link),
            .init(id: "older", category: .activity, title: "older", date: "12/20", link: link)
        ], fetchedAt: now)
        XCTAssertEqual(news.posts(in: .activity).map(\.id), ["new", "old", "older"])
    }

    func testNewsMappingsAndResponseValidationForAllGames() throws {
        for game in GameType.allCases {
            let url = try HoYoPlayNewsProvider.endpoint(for: game)
            let queries = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems
            XCTAssertEqual(queries?.first { $0.name == "game_id" }?.value, HoYoPlayNewsProvider.identity(for: game).id)
            let news = try HoYoPlayNewsProvider.decode(newsResponse(for: game), for: game)
            XCTAssertEqual(news.game, game)
            XCTAssertEqual(news.banners.count, 1)
            XCTAssertEqual(news.posts.map(\.category), [.activity, .announcement, .info])
            XCTAssertEqual(news.posts.first?.date, "10/02")
        }
        XCTAssertThrowsError(try HoYoPlayNewsProvider.decode(newsResponse(for: .genshinImpact), for: .honkaiStarRail))
        XCTAssertThrowsError(try HoYoPlayNewsProvider.decode(Data(#"{"retcode":-1,"data":null}"#.utf8), for: .genshinImpact))
    }

    func testNewsRejectsUnsafeLinksAndToleratesEmptyContent() throws {
        for bad in ["javascript:alert(1)", "file:///tmp/a", "mip:launch", "https://user:password@example.com", "/relative"] {
            XCTAssertNil(GameNews.webURL(bad))
        }
        let data = newsResponse(for: .genshinImpact)
        let unsafe = Data(String(decoding: data, as: UTF8.self).replacingOccurrences(of: "https://www.miyoushe.com/ys/article/1", with: "javascript:alert(1)").utf8)
        let filtered = try HoYoPlayNewsProvider.decode(unsafe, for: .genshinImpact)
        XCTAssertTrue(filtered.banners.isEmpty)
        XCTAssertTrue(filtered.posts.isEmpty)
        let identity = HoYoPlayNewsProvider.identity(for: .genshinImpact)
        let empty = Data("{\"retcode\":0,\"data\":{\"content\":{\"game\":{\"id\":\"\(identity.id)\",\"biz\":\"\(identity.biz)\"}}}}".utf8)
        XCTAssertTrue(try HoYoPlayNewsProvider.decode(empty, for: .genshinImpact).isEmpty)
    }

    func testNewsDiskCacheSurvivesProviderRecreationAndHTTPFailure() async throws {
        let root = try makeTemporaryDirectory()
        let fixture = try await makeScheduler()
        let network = try makeMockNetwork(response: newsResponse(for: .genshinImpact))
        let first = HoYoPlayNewsProvider(network: network, logger: fixture.logger, cacheDirectory: root)
        let fetched = try await first.fetchNews(for: .genshinImpact)
        let failing = try makeMockNetwork(response: Data(), statusCode: 503)
        let second = HoYoPlayNewsProvider(network: failing, logger: fixture.logger, cacheDirectory: root)
        let cached = await second.cachedNews(for: .genshinImpact)
        XCTAssertEqual(cached, fetched)
        let missing = await second.cachedNews(for: .zenlessZoneZero)
        XCTAssertNil(missing)
        let model = GameNewsViewModel(provider: second)
        await model.load(for: .genshinImpact, forceRefresh: true)
        XCTAssertEqual(model.news, fetched)
        XCTAssertEqual(model.state, .cached)
        XCTAssertTrue(model.refreshFailed)
    }

    func testFreshNewsCacheSkipsFetchAndExpiredCacheRefreshes() async {
        let fresh = NewsFixtureProvider(timestamp: Date())
        let model = GameNewsViewModel(provider: fresh)
        await model.load(for: .genshinImpact)
        await model.load(for: .honkaiStarRail)
        await model.load(for: .genshinImpact)
        var count = await fresh.fetchCount
        XCTAssertEqual(count, 0)
        await model.load(for: .genshinImpact, forceRefresh: true)
        count = await fresh.fetchCount
        XCTAssertEqual(count, 1)
        let stale = NewsFixtureProvider(timestamp: Date(timeIntervalSinceNow: -3600))
        let refreshing = GameNewsViewModel(provider: stale)
        await refreshing.load(for: .zenlessZoneZero)
        count = await stale.fetchCount
        XCTAssertEqual(count, 1)
        XCTAssertEqual(refreshing.state, .ready)
    }

    func testOldGameRequestCannotOverwriteCurrentNews() async {
        let provider = NewsFixtureProvider(timestamp: nil, delayed: true)
        let model = GameNewsViewModel(provider: provider)
        let old = Task { await model.load(for: .genshinImpact) }
        try? await Task.sleep(for: .milliseconds(20))
        let new = Task { await model.load(for: .honkaiStarRail) }
        await new.value
        await old.value
        XCTAssertEqual(model.news?.game, .honkaiStarRail)
        XCTAssertEqual(model.state, .ready)
    }

    func testNewsCancellationAndFailureAreContained() async {
        let provider = NewsFixtureProvider(timestamp: nil, delayed: true)
        let model = GameNewsViewModel(provider: provider)
        let loading = Task { await model.load(for: .genshinImpact) }
        try? await Task.sleep(for: .milliseconds(20))
        loading.cancel()
        await loading.value
        XCTAssertNil(model.news)
        let failure = GameNewsViewModel(provider: NewsFixtureProvider(timestamp: nil, failing: true))
        await failure.load(for: .genshinImpact)
        XCTAssertEqual(failure.state, .failed)
        XCTAssertNil(failure.news)
    }

    private func newsResponse(for game: GameType) -> Data {
        let identity = HoYoPlayNewsProvider.identity(for: game)
        return Data("""
        {"retcode":0,"data":{"content":{"game":{"id":"\(identity.id)","biz":"\(identity.biz)"},
        "banners":[{"id":"banner","image":{"url":"https://launcher-webstatic.mihoyo.com/banner.png","link":"https://www.miyoushe.com/ys/article/1"}}],
        "posts":[
        {"id":"a","type":"POST_TYPE_ACTIVITY","title":"活动标题","date":"10/02","link":"https://www.miyoushe.com/ys/article/1"},
        {"id":"b","type":"POST_TYPE_ANNOUNCE","title":"公告标题","date":"10/01","link":"https://www.miyoushe.com/ys/article/1"},
        {"id":"c","type":"POST_TYPE_INFO","title":"资讯标题","date":"09/30","link":"https://www.miyoushe.com/ys/article/1"}]}}}
        """.utf8)
    }
}

private actor NewsFixtureProvider: GameNewsProviding {
    let timestamp: Date?
    let delayed: Bool
    let failing: Bool
    var fetchCount = 0
    init(timestamp: Date?, delayed: Bool = false, failing: Bool = false) {
        self.timestamp = timestamp; self.delayed = delayed; self.failing = failing
    }
    func cachedNews(for game: GameType) -> GameNews? {
        timestamp.map { makeNews(game, date: $0) }
    }
    func fetchNews(for game: GameType) async throws -> GameNews {
        fetchCount += 1
        if delayed {
            // Deliberately ignores caller cancellation to verify the request token.
            await Task.detached { try? await Task.sleep(for: .milliseconds(game == .genshinImpact ? 150 : 10)) }.value
        }
        if failing { throw HoYoPlayNewsProvider.NewsError.invalidResponse }
        return makeNews(game, date: Date())
    }
    private func makeNews(_ game: GameType, date: Date) -> GameNews {
        GameNews(game: game, banners: [], posts: [.init(id: "post", category: .activity, title: game.displayName, date: "10/02", link: URL(string: "https://www.miyoushe.com")!)], fetchedAt: date)
    }
}
