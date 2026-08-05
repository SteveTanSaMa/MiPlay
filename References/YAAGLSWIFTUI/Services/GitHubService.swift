import Foundation

/// GitHub API client for checking releases and finding fastest mirror.
/// Replaces YAAGL's `github.ts`.
final class GitHubService: @unchecked Sendable {

    // MARK: - Types

    struct ReleaseInfo: Codable, Equatable {
        let tagName: String
        let name: String
        let body: String?
        let publishedAt: String?
        let assets: [ReleaseAsset]

        enum CodingKeys: String, CodingKey {
            case tagName = "tag_name"
            case name
            case body
            case publishedAt = "published_at"
            case assets
        }

        struct ReleaseAsset: Codable, Equatable {
            let name: String
            let size: Int
            let browserDownloadURL: String
            let contentType: String

            enum CodingKeys: String, CodingKey {
                case name
                case size
                case browserDownloadURL = "browser_download_url"
                case contentType = "content_type"
            }
        }
    }

    // MARK: - Errors

    enum GitHubError: LocalizedError {
        case noReleaseFound
        case apiError(String)

        var errorDescription: String? {
            switch self {
            case .noReleaseFound: return "No release found on GitHub"
            case .apiError(let msg): return "GitHub API error: \(msg)"
            }
        }
    }

    // MARK: - Configuration

    private let session: URLSession
    private let decoder: JSONDecoder

    /// Repository owner and name.
    private let owner = "3Shain"
    private let repo = "yet-another-anime-game-launcher"

    /// Proxies to try for faster access.
    private let mirrorProxies = ["https://ghp.3shain.uk/"]

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 10
        self.session = URLSession(configuration: config)
        self.decoder = JSONDecoder()
    }

    // MARK: - Endpoint Discovery

    /// Find the fastest responding endpoint (direct or proxy).
    func findFastestEndpoint() async -> String {
        let direct = "https://api.github.com"

        // Test each endpoint with a simple request
        typealias EndpointResult = (url: String, time: TimeInterval)

        let candidates = [direct] + mirrorProxies.map { "\($0)repos/\(owner)/\(repo)/releases/latest" }
        var results: [EndpointResult] = []

        for candidate in candidates {
            let start = Date()
            guard let url = URL(string: candidate) else { continue }
            do {
                var request = URLRequest(url: url)
                request.httpMethod = "HEAD"
                let (_, response) = try await session.data(for: request)
                if let httpResponse = response as? HTTPURLResponse,
                   (200...302).contains(httpResponse.statusCode) {
                    let elapsed = Date().timeIntervalSince(start)
                    results.append((candidate, elapsed))
                }
            } catch {
                continue
            }
        }

        // Return fastest, or fallback to direct
        return results.min(by: { $0.time < $1.time })?.url ?? direct
    }

    // MARK: - Fetch Latest Release

    /// Fetch the latest release from GitHub.
    func fetchLatestRelease() async throws -> ReleaseInfo {
        let endpoint = await findFastestEndpoint()
        let urlStr: String

        if endpoint.contains("ghp.3shain.uk") {
            urlStr = "\(endpoint)repos/\(owner)/\(repo)/releases/latest"
        } else {
            urlStr = "\(endpoint)/repos/\(owner)/\(repo)/releases/latest"
        }

        guard let url = URL(string: urlStr) else {
            throw GitHubError.apiError("Invalid URL: \(urlStr)")
        }

        var request = URLRequest(url: url)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 15

        let (data, response) = try await session.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse,
              (200...302).contains(httpResponse.statusCode) else {
            throw GitHubError.apiError("HTTP \(String(describing: (response as? HTTPURLResponse)?.statusCode))")
        }

        return try decoder.decode(ReleaseInfo.self, from: data)
    }

    // MARK: - Asset Match

    /// Find an asset matching a pattern in the release.
    func findAsset(named namePattern: String, in release: ReleaseInfo) -> ReleaseInfo.ReleaseAsset? {
        release.assets.first { $0.name.contains(namePattern) }
    }

    /// Get the accelerated download URL for an asset.
    func acceleratedURL(for asset: ReleaseInfo.ReleaseAsset) -> URL? {
        URL(string: asset.browserDownloadURL)
    }
}
