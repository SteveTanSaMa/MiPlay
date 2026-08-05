import SwiftUI

/// Game selection sidebar for macOS.
/// Shows all available games with their regions.
struct GamePickerView: View {
    @Binding var selectedGame: Game

    var body: some View {
        List(Game.allCases, selection: $selectedGame) { game in
            NavigationLink(value: game) {
                HStack(spacing: 12) {
                    Image(systemName: gameIcon(for: game))
                        .font(.title3)
                        .foregroundStyle(.tint)
                        .frame(width: 24)

                    VStack(alignment: .leading, spacing: 2) {
                        Text(game.displayName)
                            .font(.headline)
                        Text(regionName(for: game))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.vertical, 6)
            }
        }
        .navigationTitle("YAAGL")
    }

    private func gameIcon(for game: Game) -> String {
        switch game {
        case .hk4eCN, .hk4eGlobal:          return "star.fill"
        case .hkrpgCN, .hkrpgGlobal:        return "tram.fill"
        case .napCN, .napGlobal:            return "bolt.fill"
        case .bh3Global:                     return "heart.fill"
        case .cbjqCN, .cbjqGlobal:          return "snowflake"
        }
    }

    private func regionName(for game: Game) -> String {
        switch game {
        case .hk4eCN, .hkrpgCN, .napCN, .cbjqCN: return "China"
        case .hk4eGlobal, .hkrpgGlobal, .napGlobal, .bh3Global, .cbjqGlobal: return "Global"
        }
    }
}

#Preview {
    GamePickerView(selectedGame: .constant(.hk4eCN))
}
