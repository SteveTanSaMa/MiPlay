import Foundation
import Observation

/// Game operation orchestrator.
/// Manages the lifecycle of game clients and coordinates operations.
@Observable
final class GameService {

    // MARK: - Errors

    enum GameError: LocalizedError {
        case notInstalled
        case executableNotFound
        case gameClientNotAvailable(Game)
        case installDirectoryNotFound

        var errorDescription: String? {
            switch self {
            case .notInstalled: return "Game is not installed"
            case .executableNotFound: return "Game executable not found"
            case .gameClientNotAvailable(let game): return "Game client not available for \(game.fullDisplayName)"
            case .installDirectoryNotFound: return "Install directory not found"
            }
        }
    }

    // MARK: - State

    private(set) var statusText: String = ""
    private(set) var progress: Double = 0
    private(set) var isBusy: Bool = false

    private let configService: ConfigService
    private let wineService: WineService
    private let downloadService: DownloadService
    private let sophonService: SophonService

    /// Active game clients keyed by game.
    private var clients: [Game: GameClient] = [:]

    // MARK: - Initialization

    init(
        configService: ConfigService,
        wineService: WineService,
        downloadService: DownloadService,
        sophonService: SophonService
    ) {
        self.configService = configService
        self.wineService = wineService
        self.downloadService = downloadService
        self.sophonService = sophonService
    }

    // MARK: - Client Factory

    /// Get or create a game client for the specified game.
    func client(for game: Game) -> GameClient? {
        if let existing = clients[game] {
            return existing
        }

        let client: GameClient? = createClient(for: game)
        if let client = client {
            clients[game] = client
        }
        return client
    }

    private func createClient(for game: Game) -> GameClient? {
        let client: GameClient?
        switch game {
        case .hk4eCN, .hk4eGlobal:
            client = HK4EClient(game: game, wineService: wineService, downloadService: downloadService, configService: configService, sophonService: sophonService)
        case .hkrpgCN, .hkrpgGlobal:
            client = HKRPGClient(game: game, wineService: wineService, downloadService: downloadService, configService: configService)
        case .napCN, .napGlobal:
            client = NAPClient(game: game, wineService: wineService, downloadService: downloadService, configService: configService)
        case .bh3Global:
            client = BH3Client(game: game, wineService: wineService, downloadService: downloadService, configService: configService)
        case .cbjqCN, .cbjqGlobal:
            client = CBJQClient(game: game, wineService: wineService, downloadService: downloadService, configService: configService)
        }
        if client == nil {
            LogService.error("Failed to create game client for \(game.fullDisplayName)")
        }
        return client
    }

    // MARK: - Operations

    /// Install a game.
    func install(game: Game, to directory: URL) -> AsyncThrowingStream<ProgressEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    guard let client = self.client(for: game) else {
                        continuation.finish(throwing: GameError.gameClientNotAvailable(game))
                        return
                    }
                    for try await event in client.install(to: directory) {
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// Update a game.
    func update(game: Game) -> AsyncThrowingStream<ProgressEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    guard let client = self.client(for: game) else {
                        continuation.finish(throwing: GameError.gameClientNotAvailable(game))
                        return
                    }
                    for try await event in client.update() {
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// Launch a game.
    func launch(game: Game) -> AsyncThrowingStream<ProgressEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    guard let client = self.client(for: game) else {
                        continuation.finish(throwing: GameError.gameClientNotAvailable(game))
                        return
                    }
                    for try await event in client.launch(config: configService.config) {
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// Check integrity of a game.
    func checkIntegrity(game: Game) -> AsyncThrowingStream<ProgressEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    guard let client = self.client(for: game) else {
                        continuation.finish(throwing: GameError.gameClientNotAvailable(game))
                        return
                    }
                    for try await event in client.checkIntegrity() {
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    /// Get the installation state for a game.
    func installState(for game: Game) async -> GameInstallState {
        guard let client = self.client(for: game) else { return .notInstalled }
        return await client.installState
    }

    /// Get the install directory for a game.
    func installDir(for game: Game) async -> URL? {
        guard let client = self.client(for: game) else { return nil }
        return await client.installDir
    }

    /// Check whether an update is required for a game.
    func updateRequired(for game: Game) async -> Bool {
        guard let client = self.client(for: game) else { return false }
        return await client.updateRequired
    }

    /// Check whether a pre-download prompt should be shown.
    func predownloadInfo(for game: Game) async -> (show: Bool, version: String?) {
        guard let client = self.client(for: game) else { return (false, nil) }
        return (await client.showPredownloadPrompt, await client.predownloadVersion)
    }

    /// Pre-download a game update.
    func predownload(game: Game) -> AsyncThrowingStream<ProgressEvent, Error> {
        AsyncThrowingStream { continuation in
            Task {
                do {
                    guard let client = self.client(for: game) else {
                        continuation.finish(throwing: GameError.gameClientNotAvailable(game))
                        return
                    }
                    for try await event in client.predownload() {
                        continuation.yield(event)
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}

// MARK: - Hoyoverse API Helpers

/// Utility for fetching Hoyoverse launcher data.
enum HoyoverseAPI {

    struct GamePackage: Codable {
        let game: GameInfo
        let main: MainInfo?
        let preDownload: PreDownloadInfo?

        struct GameInfo: Codable {
            let id: String
            let biz: String
        }

        struct MainInfo: Codable {
            let major: MajorInfo?
        }

        struct MajorInfo: Codable {
            let version: String
            let resListURL: String?
            let gamePkgs: [GamePkg]?

            enum CodingKeys: String, CodingKey {
                case version
                case resListURL = "res_list_url"
                case gamePkgs = "game_pkgs"
            }
        }

        struct PreDownloadInfo: Codable {
            let major: MajorInfo?
        }

        struct GamePkg: Codable {
            let url: String
            let md5: String
            let size: String
            let decompressedSize: String?

            enum CodingKeys: String, CodingKey {
                case url, md5, size
                case decompressedSize = "decompressed_size"
            }

            var sizeBytes: Int64 {
                Int64(size) ?? 0
            }
        }

        enum CodingKeys: String, CodingKey {
            case game
            case main
            case preDownload = "pre_download"
        }
    }

    struct GamePackageResponse: Codable {
        let data: GamePackageData?

        struct GamePackageData: Codable {
            let gamePackages: [GamePackage]?
            enum CodingKeys: String, CodingKey {
                case gamePackages = "game_packages"
            }
        }
    }

    /// Fetch version info from Hoyoverse API.
    static func fetchVersionInfo(server: GameServer) async throws -> String? {
        let package = try await fetchPackage(for: server)
        return package?.main?.major?.version
    }

    /// Fetch full game package data including download URLs.
    static func fetchPackage(for server: GameServer) async throws -> GamePackage? {
        guard let url = URL(string: server.updateURL) else { return nil }

        let session = URLSession.shared
        let (data, _) = try await session.data(from: url)

        let response = try JSONDecoder().decode(GamePackageResponse.self, from: data)
        return response.data?.gamePackages?.first { $0.game.biz == server.biz }
    }

    /// Fetch pre-download info if available.
    static func fetchPreDownloadPackage(for server: GameServer) async throws -> GamePackage? {
        guard let url = URL(string: server.updateURL) else { return nil }

        let session = URLSession.shared
        let (data, _) = try await session.data(from: url)

        let response = try JSONDecoder().decode(GamePackageResponse.self, from: data)
        return response.data?.gamePackages?.first {
            $0.game.biz == server.biz && $0.preDownload?.major != nil
        }
    }
}
