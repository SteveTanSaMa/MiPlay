//
//  Logger.swift
//  MiPlay
//
//  Created by Steve Tan on 2026/6/20.
//

import Foundation
import OSLog

final class Logger {
    static let shared = Logger()

    private let osLog: OSLog
    private let logQueue = DispatchQueue(label: "com.SteveTan.MiPlay.logger", qos: .utility)
    private var logFileHandle: FileHandle?

    private init() {
        self.osLog = OSLog(subsystem: "com.SteveTan.MiPlay", category: "General")
        setupFileLogging()
    }

    private func setupFileLogging() {
        let urls = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)
        guard let logsDir = urls.first?.appendingPathComponent("Logs/MiPlay") else { return }

        try? FileManager.default.createDirectory(at: logsDir, withIntermediateDirectories: true)

        let logURL = logsDir.appendingPathComponent("miplay.log")
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }

        logFileHandle = try? FileHandle(forWritingTo: logURL)
        logFileHandle?.seekToEndOfFile()
    }

    func debug(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        log(level: "DEBUG", message: message, file: file, function: function, line: line)
    }

    func info(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        log(level: "INFO", message: message, file: file, function: function, line: line)
    }

    func warning(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        log(level: "WARN", message: message, file: file, function: function, line: line)
    }

    func error(_ message: String, file: String = #file, function: String = #function, line: Int = #line) {
        log(level: "ERROR", message: message, file: file, function: function, line: line)
    }

    private func log(level: String, message: String, file: String, function: String, line: Int) {
        let fileName = (file as NSString).lastPathComponent
        let logMessage = "[\(level)] [\(fileName):\(line)] \(function) - \(message)"

        os_log("%{public}@", log: osLog, type: .default, logMessage)

        logQueue.async { [weak self] in
            guard let self = self else { return }
            let timestamp = ISO8601DateFormatter().string(from: Date())
            if let data = "\(timestamp) \(logMessage)\n".data(using: .utf8) {
                self.logFileHandle?.write(data)
            }
        }
    }

    deinit {
        logFileHandle?.closeFile()
    }
}
