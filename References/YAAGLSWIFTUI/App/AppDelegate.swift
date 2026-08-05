import AppKit

/// Handles application lifecycle events.
/// Ensures proper cleanup of subprocesses (wine server, sophon server) on termination.
final class AppDelegate: NSObject, NSApplicationDelegate {

    func applicationWillTerminate(_ notification: Notification) {
        // Give wineserver a chance to shut down gracefully
        let winePrefix = FileSystemService.appSupportPath("wine_prefix")
        let wineserverPath = winePrefix
            .deletingLastPathComponent()
            .appendingPathComponent("wine/bin/wineserver")

        if FileSystemService.fileExists(at: wineserverPath) {
            let process = Process()
            process.executableURL = wineserverPath
            process.arguments = ["-w"]
            process.environment = [
                "WINEPREFIX": winePrefix.path,
                "WINEDEBUG": "fixme-all"
            ]
            try? process.run()
            process.waitUntilExit()
        }
    }
}
