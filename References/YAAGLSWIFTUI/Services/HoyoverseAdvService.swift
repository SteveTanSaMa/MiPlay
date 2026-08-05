import Foundation

/// Fetches launcher background images, videos, logos, and icons
/// from Hoyoverse's advertising/content APIs.
enum HoyoverseAdvService {

    // MARK: - Types

    struct AdvContent: Codable, Sendable {
        let backgroundURL: URL?
        let backgroundVideoURL: URL?
        let logoURL: URL?
        let iconURL: URL?
    }

    private struct AdvResponse: Codable {
        let retcode: Int?
        let data: AdvData?

        struct AdvData: Codable {
            let adv: AdvInfo?
            let banner: [AdvBanner]?
        }

        struct AdvInfo: Codable {
            let background: String?
            let bgVideo: String?

            enum CodingKeys: String, CodingKey {
                case background
                case bgVideo = "bg_video"
            }
        }

        struct AdvBanner: Codable {
            let banner: BannerInfo?

            struct BannerInfo: Codable {
                let background: String?
                let icon: IconInfo?

                struct IconInfo: Codable {
                    let url: String?
                }
            }
        }
    }

    private struct ContentResponse: Codable {
        let retcode: Int?
        let data: ContentData?

        struct ContentData: Codable {
            let adv: AdvContentData?

            struct AdvContentData: Codable {
                let background: BackgroundInfo?

                struct BackgroundInfo: Codable {
                    let logo: LogoInfo?

                    struct LogoInfo: Codable {
                        let url: String?
                    }
                }
            }
        }
    }

    // MARK: - Fetch

    /// Fetch advertisement content (backgrounds, videos) for a game server.
    static func fetchAdvContent(for server: GameServer) async -> AdvContent {
        async let adv = fetchAdvBanners(server: server)
        async let content = fetchContent(server: server)

        let advResult = await adv
        let contentResult = await content

        let bgURL = advResult.backgroundURL ?? contentResult.backgroundURL
        let videoURL = advResult.backgroundVideoURL
        let logoURL = contentResult.logoURL
        let iconURL = advResult.iconURL

        return AdvContent(
            backgroundURL: bgURL,
            backgroundVideoURL: videoURL,
            logoURL: logoURL,
            iconURL: iconURL
        )
    }

    private static func fetchAdvBanners(server: GameServer) async -> (
        backgroundURL: URL?, backgroundVideoURL: URL?, iconURL: URL?
    ) {
        guard let url = URL(string: server.advURL) else {
            return (nil, nil, nil)
        }

        do {
            let session = URLSession.shared
            let (data, _) = try await session.data(from: url)
            let response = try JSONDecoder().decode(AdvResponse.self, from: data)

            let bg = response.data?.adv?.background.flatMap(URL.init(string:))
            let video = response.data?.adv?.bgVideo.flatMap(URL.init(string:))
            let icon = response.data?.banner?.first?.banner?.icon?.url.flatMap(URL.init(string:))

            return (bg, video, icon)
        } catch {
            LogService.networkLog("Failed to fetch adv banners: \(error.localizedDescription)")
            return (nil, nil, nil)
        }
    }

    private static func fetchContent(server: GameServer) async -> (
        backgroundURL: URL?, logoURL: URL?
    ) {
        // Content API uses the updateURL but with a filter parameter
        guard let url = URL(string: server.advURL) else {
            return (nil, nil)
        }

        do {
            let session = URLSession.shared
            let (data, _) = try await session.data(from: url)
            let response = try JSONDecoder().decode(ContentResponse.self, from: data)

            let logo = response.data?.adv?.background?.logo?.url.flatMap(URL.init(string:))
            return (nil, logo)
        } catch {
            LogService.networkLog("Failed to fetch content: \(error.localizedDescription)")
            return (nil, nil)
        }
    }
}
