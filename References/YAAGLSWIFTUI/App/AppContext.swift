import Foundation
import Observation

/// Central dependency injection container.
/// Holds all long-lived services as singletons to avoid redundant
/// instantiation and ensure consistent state across the app.
@Observable
final class AppContext {
    let configService: ConfigService
    let wineService: WineService
    let downloadService: DownloadService
    let sophonService: SophonService
    let githubService: GitHubService
    let gameService: GameService
    let updaterService: UpdaterService

    init() {
        let config = ConfigService()
        let wine = WineService()
        let download = DownloadService()
        let sophon = SophonService()
        let github = GitHubService()
        let game = GameService(
            configService: config,
            wineService: wine,
            downloadService: download,
            sophonService: sophon
        )
        let updater = UpdaterService(
            githubService: github,
            downloadService: download,
            configService: config
        )

        self.configService = config
        self.wineService = wine
        self.downloadService = download
        self.sophonService = sophon
        self.githubService = github
        self.gameService = game
        self.updaterService = updater
    }
}
