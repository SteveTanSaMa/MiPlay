//
//  WineDownloader.swift
//  MiPlay
//
//  Created by Steve Tan on 2026/6/20.
//

import Foundation

actor WineDownloader {
    enum DownloadError: LocalizedError {
        case invalidURL
        case downloadFailed(String)
        case extractionFailed(String)
        case checksumMismatch(String, String)

        var errorDescription: String? {
            switch self {
            case .invalidURL:
                return "无效的下载链接"
            case .downloadFailed(let detail):
                return "下载失败: \(detail)"
            case .extractionFailed(let detail):
                return "解压失败: \(detail)"
            case .checksumMismatch(let expected, let actual):
                return "SHA256 校验不匹配，期望 \(expected)，实际 \(actual)"
            }
        }
    }

    private let fileManager = FileManager.default

    /// 下载 Wine 包到临时目录，返回本地文件 URL
    func downloadWine(version: WineVersion, to directory: URL) async throws -> URL {
        let (tempURL, response) = try await URLSession.shared.download(from: version.downloadURL)

        guard let httpResponse = response as? HTTPURLResponse,
              httpResponse.statusCode == 200 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            throw DownloadError.downloadFailed("HTTP \(code)")
        }

        let fileName = version.downloadURL.lastPathComponent
        let destinationURL = directory.appendingPathComponent(fileName)

        if fileManager.fileExists(atPath: destinationURL.path) {
            try fileManager.removeItem(at: destinationURL)
        }

        try fileManager.moveItem(at: tempURL, to: destinationURL)
        return destinationURL
    }

    /// 解压 .tar.xz 包到目标目录
    func extractWinePackage(at archiveURL: URL, to destination: URL) async throws {
        // yaagl 的包是 .tar.xz，先用 xz 解压再用 tar 解包
        // 或者直接用 tar 的自动检测（tar 支持 -xJf 或 -xaf）
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-xJf", archiveURL.path, "-C", destination.path]

        try process.run()
        process.waitUntilExit()

        guard process.terminationStatus == 0 else {
            throw DownloadError.extractionFailed(
                "tar 解压失败，退出码: \(process.terminationStatus)。" +
                "尝试使用 \"tar -xJf\" 解压 \(archiveURL.lastPathComponent)" +
                "，请确保已安装 xz 工具（brew install xz）"
            )
        }
    }

    /// 校验文件的 SHA256
    func verifyChecksum(filePath: URL, expectedSHA256: String) async throws -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/shasum")
        process.arguments = ["-a", "256", filePath.path]

        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8) ?? ""
        let actualHash = output.components(separatedBy: " ").first ?? ""

        return actualHash.lowercased() == expectedSHA256.lowercased()
    }
}
