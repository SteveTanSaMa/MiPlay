import SwiftUI

/// Root navigation view — macOS-style sidebar with game picker and detail launcher.
struct RootView: View {
    @Environment(ConfigService.self) private var configService
    @State private var selectedGame: Game = .hk4eCN
    @State private var columnVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            GamePickerView(selectedGame: $selectedGame)
                .navigationSplitViewColumnWidth(min: 200, ideal: 260)
        } detail: {
            LauncherView(game: selectedGame)
        }
        .navigationSplitViewStyle(.balanced)
    }
}

#Preview {
    RootView()
        .environment(ConfigService())
}
