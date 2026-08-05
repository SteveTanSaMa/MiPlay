import Foundation

/// Protocol defining the interface for each game client (channel client).
/// Mirrors YAAGL's `ChannelClient` interface.
protocol GameClient {
    /// The game this client manages.
    var game: Game { get }

    /// Current installation state.
    var installState: GameInstallState { get async }

    /// Installation directory for this game.
    var installDir: URL? { get async }

    /// Whether an update is available.
    var updateRequired: Bool { get async }

    /// Pre-download version if available.
    var predownloadVersion: String? { get async }

    /// Whether the pre-download prompt should be shown.
    var showPredownloadPrompt: Bool { get async }

    // MARK: - UI Content

    /// URL for the launcher background image.
    var backgroundImageURL: URL? { get async }

    /// URL for the launcher background video.
    var backgroundVideoURL: URL? { get async }

    /// URL for the theme overlay image.
    var backgroundThemeURL: URL? { get async }

    /// URL for the game logo image.
    var logoImageURL: URL? { get async }

    /// URL for the version icon image.
    var iconImageURL: URL? { get async }

    /// Game's official website URL.
    var websiteURL: URL? { get }

    /// Where the launch button should be positioned.
    var launchButtonLocation: LaunchButtonLocation { get }

    // MARK: - Actions

    /// Install the game to the given directory.
    func install(to directory: URL) -> AsyncThrowingStream<ProgressEvent, Error>

    /// Update the game to the latest version.
    func update() -> AsyncThrowingStream<ProgressEvent, Error>

    /// Pre-download the next version.
    func predownload() -> AsyncThrowingStream<ProgressEvent, Error>

    /// Launch the game with the given configuration.
    func launch(config: AppConfig) -> AsyncThrowingStream<ProgressEvent, Error>

    /// Check game file integrity.
    func checkIntegrity() -> AsyncThrowingStream<ProgressEvent, Error>

    /// Initialize / prepare the game environment.
    func initialize(config: AppConfig) async throws

    /// Dismiss the pre-download prompt.
    func dismissPredownload()

    // MARK: - Configuration

    /// Create game-specific configuration views.
    /// Returns an array of config key-value pairs for the settings UI.
    func configSections() -> [GameConfigSection]
}

/// Launch button position.
enum LaunchButtonLocation: Equatable {
    case left
    case right
}

/// A section of game-specific configuration items.
struct GameConfigSection: Identifiable {
    let id: String
    let title: String
    let items: [GameConfigItem]
}

/// A single game configuration item.
enum GameConfigItem: Identifiable {
    case toggle(id: String, title: String, isOn: Bool, action: (Bool) -> Void)
    case textField(id: String, title: String, value: String, action: (String) -> Void)
    case picker(id: String, title: String, options: [(String, String)], selection: String, action: (String) -> Void)
    case info(id: String, title: String, value: String)

    var id: String {
        switch self {
        case .toggle(let id, _, _, _): return id
        case .textField(let id, _, _, _): return id
        case .picker(let id, _, _, _, _): return id
        case .info(let id, _, _): return id
        }
    }
}

// MARK: - Default Implementations

extension GameClient {
    var launchButtonLocation: LaunchButtonLocation { .right }
    var predownloadVersion: String? { nil }
    var showPredownloadPrompt: Bool { false }
    var backgroundThemeURL: URL? { nil }

    func dismissPredownload() {}
    func predownload() -> AsyncThrowingStream<ProgressEvent, Error> {
        AsyncThrowingStream { $0.finish() }
    }
}
