import Foundation
import Observation

/// Central configuration service.
/// Persists `AppConfig` to `UserDefaults` as a JSON-encoded value.
/// Exposed to the SwiftUI environment as an `@Observable` class.
@Observable
final class ConfigService {
    private let defaults: UserDefaults
    private let suiteName = "com.stevetan.YAAGLSWIFTUI"
    private let configKey = "app_config"

    /// The current configuration. Mutations auto-save.
    var config: AppConfig = .default {
        didSet { save() }
    }

    /// The selected game — drives which launcher to show.
    var selectedGame: Game = .hk4eCN {
        didSet { saveSelectedGame() }
    }

    // MARK: - Initialization

    init() {
        self.defaults = UserDefaults(suiteName: suiteName) ?? .standard
        load()
    }

    // MARK: - Persistence

    private func load() {
        if let data = defaults.data(forKey: configKey),
           let decoded = try? JSONDecoder().decode(AppConfig.self, from: data) {
            config = decoded
        } else {
            config = .default
        }

        if let raw = defaults.string(forKey: "selected_game"),
           let game = Game(rawValue: raw) {
            selectedGame = game
        }
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(config) else { return }
        defaults.set(data, forKey: configKey)
    }

    private func saveSelectedGame() {
        defaults.set(selectedGame.rawValue, forKey: "selected_game")
    }

    // MARK: - Convenience Accessors

    var installDir: String {
        config.installDir(for: selectedGame)
    }

    func setInstallDir(_ path: String) {
        config.setInstallDir(path, for: selectedGame)
    }

    func setInstallDir(_ path: String, for game: Game) {
        config.setInstallDir(path, for: game)
    }

    /// Returns the effective Wine distribution based on current config.
    var wineDistribution: WineDistribution {
        WineDistribution.find(byID: config.wineTag)
    }

    // MARK: - Reset

    func resetToDefaults() {
        config = .default
        selectedGame = .hk4eCN
    }
}


