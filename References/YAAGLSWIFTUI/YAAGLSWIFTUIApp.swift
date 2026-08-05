import SwiftUI

@main
struct YAAGLSWIFTUIApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @State private var appContext = AppContext()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(appContext.configService)
                .environment(appContext.gameService)
                .environment(appContext.wineService)
                .environment(appContext.downloadService)
                .environment(appContext.updaterService)
                .frame(minWidth: 800, minHeight: 500)
        }
        .windowResizability(.contentMinSize)
        .windowStyle(.titleBar)
    }
}
