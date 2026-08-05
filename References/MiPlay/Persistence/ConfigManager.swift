//
//  ConfigManager.swift
//  MiPlay
//
//  Created by Steve Tan on 2026/6/20.
//

import Foundation

actor ConfigManager {
    enum ConfigError: LocalizedError {
        case notFound(String)
        case parseFailed(String)
        case writeFailed(String)

        var errorDescription: String? {
            switch self {
            case .notFound(let name): return "配置文件未找到: \(name)"
            case .parseFailed(let detail): return "配置解析失败: \(detail)"
            case .writeFailed(let detail): return "配置写入失败: \(detail)"
            }
        }
    }

    private let fileManager = FileManager.default
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private var configDirectory: URL {
        let urls = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        let dir = urls[0].appendingPathComponent("MiPlay/Configs", isDirectory: true)
        if !fileManager.fileExists(atPath: dir.path) {
            try? fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }

    func saveConfiguration<T: Codable>(_ config: T, name: String) throws {
        let url = configDirectory.appendingPathComponent("\(name).json")
        encoder.outputFormatting = .prettyPrinted
        let data = try encoder.encode(config)
        try data.write(to: url, options: .atomic)
    }

    func loadConfiguration<T: Codable>(_ type: T.Type, name: String) throws -> T {
        let url = configDirectory.appendingPathComponent("\(name).json")
        guard fileManager.fileExists(atPath: url.path) else {
            throw ConfigError.notFound(name)
        }

        let data = try Data(contentsOf: url)
        return try decoder.decode(type, from: data)
    }

    func deleteConfiguration(name: String) throws {
        let url = configDirectory.appendingPathComponent("\(name).json")
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    func listConfigurations() -> [String] {
        guard let contents = try? fileManager.contentsOfDirectory(atPath: configDirectory.path) else {
            return []
        }
        return contents.filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) }
    }
}
