import SwiftUI

// MARK: - ConfigService Environment Key

private struct ConfigServiceKey: EnvironmentKey {
    static let defaultValue = ConfigService()
}

// MARK: - GameService Environment Key

private struct GameServiceKey: EnvironmentKey {
    static let defaultValue = GameService(
        configService: ConfigService(),
        wineService: WineService(),
        downloadService: DownloadService(),
        sophonService: SophonService()
    )
}

// MARK: - WineService Environment Key

private struct WineServiceKey: EnvironmentKey {
    static let defaultValue = WineService()
}

// MARK: - DownloadService Environment Key

private struct DownloadServiceKey: EnvironmentKey {
    static let defaultValue = DownloadService()
}

// MARK: - UpdaterService Environment Key

private struct UpdaterServiceKey: EnvironmentKey {
    static let defaultValue = UpdaterService(
        githubService: GitHubService(),
        downloadService: DownloadService(),
        configService: ConfigService()
    )
}

extension EnvironmentValues {
    var configService: ConfigService {
        get { self[ConfigServiceKey.self] }
        set { self[ConfigServiceKey.self] = newValue }
    }

    var gameService: GameService {
        get { self[GameServiceKey.self] }
        set { self[GameServiceKey.self] = newValue }
    }

    var wineService: WineService {
        get { self[WineServiceKey.self] }
        set { self[WineServiceKey.self] = newValue }
    }

    var downloadService: DownloadService {
        get { self[DownloadServiceKey.self] }
        set { self[DownloadServiceKey.self] = newValue }
    }

    var updaterService: UpdaterService {
        get { self[UpdaterServiceKey.self] }
        set { self[UpdaterServiceKey.self] = newValue }
    }
}
