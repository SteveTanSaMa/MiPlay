//
//  UpdateManager.swift
//  MiPlay
//
//  Created by Steve Tan on 2026/6/20.
//

import Foundation

actor UpdateManager {
    enum UpdateError: LocalizedError {
        case networkError(String)
        case noUpdateAvailable
        case updateCheckFailed(String)

        var errorDescription: String? {
            switch self {
            case .networkError(let detail): return "网络错误: \(detail)"
            case .noUpdateAvailable: return "没有可用更新"
            case .updateCheckFailed(let detail): return "检查更新失败: \(detail)"
            }
        }
    }

    struct UpdateInfo: Codable {
        let latestVersion: String
        let downloadURL: URL
        let releaseNotes: String?
        let minimumOSVersion: String?
        let publishedAt: Date?

        func isNewerThanCurrent(_ currentVersion: String) -> Bool {
            latestVersion.compare(currentVersion, options: .numeric) == .orderedDescending
        }
    }

    private var launcherVersion: String = ""

    func configure(version: String) {
        launcherVersion = version
    }

    func checkForUpdates() async throws -> UpdateInfo {
        let url = URL(string: "https://api.github.com/repos/SteveTan/MiPlay/releases/latest")!
        let (data, response) = try await URLSession.shared.data(from: url)

        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            throw UpdateError.updateCheckFailed("无法获取更新信息")
        }

        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let tagName = json?["tag_name"] as? String,
              let assets = json?["assets"] as? [[String: Any]],
              let firstAsset = assets.first,
              let downloadURLString = firstAsset["browser_download_url"] as? String,
              let downloadURL = URL(string: downloadURLString) else {
            throw UpdateError.noUpdateAvailable
        }

        let releaseNotes = json?["body"] as? String

        return UpdateInfo(
            latestVersion: tagName,
            downloadURL: downloadURL,
            releaseNotes: releaseNotes,
            minimumOSVersion: nil,
            publishedAt: nil
        )
    }

    func downloadUpdate(_ update: UpdateInfo) async throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
        let destination = tempDir.appendingPathComponent("MiPlay-\(update.latestVersion).zip")

        let (tempURL, _) = try await URLSession.shared.download(from: update.downloadURL)

        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.moveItem(at: tempURL, to: destination)
        return destination
    }
}
