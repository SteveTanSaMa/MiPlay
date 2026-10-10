import Foundation
import Observation

@MainActor @Observable
final class GameNewsViewModel {
    enum State: Equatable { case loading, ready, empty, failed, cached }
    private(set) var news: GameNews?
    private(set) var state: State = .loading
    private(set) var refreshFailed = false
    var category: GameNewsCategory = .activity
    private let provider: any GameNewsProviding
    private var requestID = UUID()
    static let cacheTTL: TimeInterval = 30 * 60

    init(provider: any GameNewsProviding) { self.provider = provider }

    /// The SwiftUI .task owns cancellation. A token also protects against non-cooperative providers.
    func load(for game: GameType, forceRefresh: Bool = false) async {
        let token = UUID()
        requestID = token
        if news?.game != game {
            news = nil
            category = .activity
        }
        refreshFailed = false
        state = news == nil ? .loading : .cached
        let cached = await provider.cachedNews(for: game)
        guard requestID == token, !Task.isCancelled else { return }
        if let cached {
            news = cached
            state = cached.isEmpty ? .empty : .cached
            let age = Date().timeIntervalSince(cached.fetchedAt)
            if !forceRefresh && age >= 0 && age < Self.cacheTTL { return }
        }
        do {
            let updated = try await provider.fetchNews(for: game)
            guard requestID == token, !Task.isCancelled, updated.game == game else { return }
            news = updated
            state = updated.isEmpty ? .empty : .ready
        } catch {
            guard requestID == token, !Task.isCancelled else { return }
            refreshFailed = true
            state = news == nil ? .failed : .cached
        }
    }
}
