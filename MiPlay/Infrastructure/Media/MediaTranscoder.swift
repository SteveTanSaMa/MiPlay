//
//  MediaTranscoder.swift
//  MiPlay
//
//  Created by Steve Tan on 2026/7/7.
//

import Foundation

// Source: Review Issue: F4 — 背景素材实现
// 调用内置 ffmpeg 将 webm 高品质转码为 mp4

/// 媒体转码器。使用内置 ffmpeg 将 webm 高品质转码为 mp4。
public actor MediaTranscoder {
    public enum TranscodeError: Error, LocalizedError {
        case ffmpegNotFound
        case transcodeFailed(String)
        case outputVerificationFailed

        public var errorDescription: String? {
            switch self {
            case .ffmpegNotFound:
                return "ffmpeg 未找到"
            case .transcodeFailed(let detail):
                return "转码失败: \(detail)"
            case .outputVerificationFailed:
                return "输出验证失败"
            }
        }
    }

    private let processManager: ProcessManager
    private let logWriter: LogWriter
    private let ffmpegPathOverride: String?

    /// ffmpeg 可执行文件路径（优先使用内置 ffmpeg）
    private var ffmpegPath: String {
        if let ffmpegPathOverride { return ffmpegPathOverride }
        // 内置 ffmpeg 路径（放在 Resources/ 目录下）
        if let bundlePath = Bundle.main.path(forResource: "ffmpeg", ofType: nil) {
            return bundlePath
        }
        return "/usr/local/bin/ffmpeg"
    }

    public init(
        processManager: ProcessManager,
        logWriter: LogWriter,
        ffmpegPath: String? = nil
    ) {
        self.processManager = processManager
        self.logWriter = logWriter
        self.ffmpegPathOverride = ffmpegPath
    }

    /// Included in the video cache marker so previous lossy outputs are regenerated.
    nonisolated internal static let videoQualityProfile = "h264-crf14-veryslow-yuv420p-v1"

    // MARK: - 转码

    /// 临时输出路径：`.part` 插在扩展名之前，保证 ffmpeg 仍能按扩展名选择
    /// 封装器/编码器（`video.mp4.part` 这类结尾会直接报
    /// "Unable to choose an output format" 而全部转码失败）。
    nonisolated internal static func temporaryOutputPath(for outputPath: String) -> String {
        let url = URL(fileURLWithPath: outputPath)
        let fileExtension = url.pathExtension
        guard !fileExtension.isEmpty else { return outputPath + ".part" }
        return url.deletingPathExtension()
            .appendingPathExtension("part")
            .appendingPathExtension(fileExtension)
            .path
    }

    /// 将 webm 高品质转码为 mp4。
    /// CRF 14 在高画质与体积之间取平衡，veryslow 提高压缩效率；
    /// 保留原始分辨率与帧率，不通过放大制造细节。
    /// PNG/WebP 转换仍是无损输出，不受该视频质量参数影响。
    /// - Parameters:
    ///   - inputPath: 输入 webm 文件路径
    ///   - outputPath: 输出 mp4 文件路径
    /// - Returns: 输出文件路径
    @discardableResult
    public func transcodeWebMToMP4(inputPath: String, outputPath: String) async throws -> String {
        let operationID = UUID()
        guard FileManager.default.fileExists(atPath: ffmpegPath) else {
            await logWriter.record(.init(
                level: .warning,
                module: "MediaTranscoder",
                eventName: "background.transcode",
                operationID: operationID,
                phase: "preflight",
                result: "unavailable",
                errorCategory: "resourceNotFound",
                messageCode: "background.transcode.ffmpeg_missing"
            ))
            throw TranscodeError.ffmpegNotFound
        }

        await logWriter.record(.init(
            level: .info,
            module: "MediaTranscoder",
            eventName: "background.transcode",
            operationID: operationID,
            phase: "started",
            result: "inProgress",
            messageCode: "background.transcode.started"
        ))

        // 先写临时文件，成功后再原子替换：中断或失败不会在缓存目录留下半截
        // 成品文件（缓存门槛只检查文件存在，半截文件会被误判为有效缓存）。
        let tempPath = Self.temporaryOutputPath(for: outputPath)
        try? FileManager.default.createDirectory(
            at: URL(fileURLWithPath: outputPath).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        do {
            _ = try await processManager.launchAndWait(
                executablePath: ffmpegPath,
                arguments: [
                    "-i", inputPath,
                    "-map", "0:v:0",
                    "-c:v", "libx264",
                    "-preset", "veryslow",
                    "-crf", "14",
                    "-pix_fmt", "yuv420p",
                    "-movflags", "+faststart",
                    "-an",
                    "-y",
                    tempPath
                ],
                timeout: 600
            )
        } catch {
            try? FileManager.default.removeItem(atPath: tempPath)
            await logWriter.record(.init(
                level: .error,
                module: "MediaTranscoder",
                eventName: "background.transcode",
                operationID: operationID,
                phase: "process",
                result: "failed",
                errorCategory: "processExitedAbnormally",
                messageCode: "background.transcode.failed"
            ))
            throw TranscodeError.transcodeFailed(error.localizedDescription)
        }

        // 验证输出
        let fileManager = FileManager.default
        let outputSize = (try? fileManager.attributesOfItem(atPath: tempPath))?[.size] as? Int64 ?? 0
        guard fileManager.fileExists(atPath: tempPath), outputSize > 0 else {
            try? fileManager.removeItem(atPath: tempPath)
            await logWriter.record(.init(
                level: .error,
                module: "MediaTranscoder",
                eventName: "background.transcode",
                operationID: operationID,
                phase: "verification",
                result: "failed",
                errorCategory: "integrityFailed",
                messageCode: "background.transcode.output_missing"
            ))
            throw TranscodeError.outputVerificationFailed
        }
        do {
            if fileManager.fileExists(atPath: outputPath) {
                try fileManager.removeItem(atPath: outputPath)
            }
            try fileManager.moveItem(atPath: tempPath, toPath: outputPath)
        } catch {
            try? fileManager.removeItem(atPath: tempPath)
            await logWriter.record(.init(
                level: .error,
                module: "MediaTranscoder",
                eventName: "background.transcode",
                operationID: operationID,
                phase: "verification",
                result: "failed",
                errorCategory: "integrityFailed",
                messageCode: "background.transcode.output_missing"
            ))
            throw TranscodeError.transcodeFailed(error.localizedDescription)
        }

        do {
            try Self.videoQualityProfile.write(toFile: outputPath + ".quality", atomically: true, encoding: .utf8)
        } catch {
            await logWriter.warning("视频质量缓存标记写入失败", module: "MediaTranscoder")
        }

        await logWriter.record(.init(
            level: .info,
            module: "MediaTranscoder",
            eventName: "background.transcode",
            operationID: operationID,
            phase: "completed",
            result: "completed",
            messageCode: "background.transcode.completed"
        ))
        return outputPath
    }

    /// 将 webp 转换为 png
    @discardableResult
    public func transcodeWebPToPNG(inputPath: String, outputPath: String) async throws -> String {
        let operationID = UUID()
        guard FileManager.default.fileExists(atPath: ffmpegPath) else {
            await logWriter.record(.init(
                level: .warning,
                module: "MediaTranscoder",
                eventName: "background.transcode",
                operationID: operationID,
                phase: "preflight",
                result: "unavailable",
                errorCategory: "resourceNotFound",
                messageCode: "background.transcode.ffmpeg_missing"
            ))
            throw TranscodeError.ffmpegNotFound
        }

        await logWriter.record(.init(
            level: .info,
            module: "MediaTranscoder",
            eventName: "background.transcode",
            operationID: operationID,
            phase: "started",
            result: "inProgress",
            messageCode: "background.transcode.started"
        ))
        // 与视频转码相同的原子提交策略：先写临时文件，成功后再替换。
        let tempPath = Self.temporaryOutputPath(for: outputPath)
        try? FileManager.default.createDirectory(
            at: URL(fileURLWithPath: outputPath).deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        do {
            _ = try await processManager.launchAndWait(
                executablePath: ffmpegPath,
                arguments: [
                    "-i", inputPath,
                    "-y",
                    tempPath
                ],
                timeout: 30
            )
        } catch {
            try? FileManager.default.removeItem(atPath: tempPath)
            await logWriter.record(.init(
                level: .error,
                module: "MediaTranscoder",
                eventName: "background.transcode",
                operationID: operationID,
                phase: "process",
                result: "failed",
                errorCategory: "processExitedAbnormally",
                messageCode: "background.transcode.failed"
            ))
            throw TranscodeError.transcodeFailed(error.localizedDescription)
        }

        let fileManager = FileManager.default
        let outputSize = (try? fileManager.attributesOfItem(atPath: tempPath))?[.size] as? Int64 ?? 0
        guard fileManager.fileExists(atPath: tempPath), outputSize > 0 else {
            try? fileManager.removeItem(atPath: tempPath)
            await logWriter.record(.init(
                level: .error,
                module: "MediaTranscoder",
                eventName: "background.transcode",
                operationID: operationID,
                phase: "verification",
                result: "failed",
                errorCategory: "integrityFailed",
                messageCode: "background.transcode.output_missing"
            ))
            throw TranscodeError.outputVerificationFailed
        }
        do {
            if fileManager.fileExists(atPath: outputPath) {
                try fileManager.removeItem(atPath: outputPath)
            }
            try fileManager.moveItem(atPath: tempPath, toPath: outputPath)
        } catch {
            try? fileManager.removeItem(atPath: tempPath)
            await logWriter.record(.init(
                level: .error,
                module: "MediaTranscoder",
                eventName: "background.transcode",
                operationID: operationID,
                phase: "verification",
                result: "failed",
                errorCategory: "integrityFailed",
                messageCode: "background.transcode.output_missing"
            ))
            throw TranscodeError.transcodeFailed(error.localizedDescription)
        }

        await logWriter.record(.init(
            level: .info,
            module: "MediaTranscoder",
            eventName: "background.transcode",
            operationID: operationID,
            phase: "completed",
            result: "completed",
            messageCode: "background.transcode.completed"
        ))
        return outputPath
    }
}
