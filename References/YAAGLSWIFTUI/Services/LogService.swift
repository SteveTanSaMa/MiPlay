import Foundation
import OSLog

/// Unified logging service across the application.
enum LogService {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.stevetan.YAAGLSWIFTUI"

    private static let general = Logger(subsystem: subsystem, category: "general")
    private static let download = Logger(subsystem: subsystem, category: "download")
    private static let process = Logger(subsystem: subsystem, category: "process")
    private static let wine = Logger(subsystem: subsystem, category: "wine")
    private static let game = Logger(subsystem: subsystem, category: "game")
    private static let network = Logger(subsystem: subsystem, category: "network")

    // MARK: - General

    static func debug(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        general.debug("[\(sourceFile(file)):\(line) \(function)] \(message)")
    }

    static func info(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        general.info("[\(sourceFile(file)):\(line) \(function)] \(message)")
    }

    static func warning(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        general.warning("[\(sourceFile(file)):\(line) \(function)] \(message)")
    }

    static func error(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        general.error("[\(sourceFile(file)):\(line) \(function)] \(message)")
    }

    // MARK: - Category-specific

    static func downloadLog(_ message: String) {
        download.info("\(message)")
    }

    static func processLog(_ message: String) {
        process.info("\(message)")
    }

    static func wineLog(_ message: String) {
        wine.info("\(message)")
    }

    static func gameLog(_ message: String) {
        game.info("\(message)")
    }

    static func networkLog(_ message: String) {
        network.info("\(message)")
    }

    // MARK: - Helpers

    private static func sourceFile(_ path: String) -> String {
        URL(fileURLWithPath: path).lastPathComponent
    }

    // MARK: - Game Output Log

    /// Save game launch output (Wine/DXMT/MoltenVK logs) to a file.
    @discardableResult
    static func saveGameLog(gameName: String, stdout: String, stderr: String) -> URL? {
        let logsDir = FileSystemService.appSupportPath("logs")
        _ = try? FileSystemService.createDirectory(at: logsDir)

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd_HH-mm-ss"
        let timestamp = formatter.string(from: Date())
        let filename = "\(gameName)_\(timestamp).log"
        let logFile = logsDir.appendingPathComponent(filename)

        let header = "=== YAAGL SwiftUI Game Log ===\nGame: \(gameName)\nTime: \(Date())\n\n"
        let content = header + "[stdout]\n" + stdout + "\n\n[stderr]\n" + stderr + "\n"

        do {
            try content.write(to: logFile, atomically: true, encoding: .utf8)
            return logFile
        } catch {
            return nil
        }
    }
}

/// Convenience global functions for quick logging.
func logDebug(_ message: String) { LogService.debug(message) }
func logInfo(_ message: String) { LogService.info(message) }
func logWarning(_ message: String) { LogService.warning(message) }
func logError(_ message: String) { LogService.error(message) }
