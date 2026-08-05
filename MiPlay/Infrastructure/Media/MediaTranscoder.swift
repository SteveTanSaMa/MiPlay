//
//  MediaTranscoder.swift
//  MiPlay
//
//  Created by Steve Tan on 2026/7/7.
//

import Foundation

// Source: Review Issue: F4 — 背景素材实现
// 调用内置 ffmpeg 将 webm 转码为 mp4

/// 媒体转码器。使用内置 ffmpeg 将 webm 转码为 mp4。
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

    /// ffmpeg 可执行文件路径（优先使用内置 ffmpeg）
    private var ffmpegPath: String {
        // 内置 ffmpeg 路径（放在 Resources/ 目录下）
        if let bundlePath = Bundle.main.path(forResource: "ffmpeg", ofType: nil) {
            return bundlePath
        }
        return "/usr/local/bin/ffmpeg"
    }

    public init(
        processManager: ProcessManager,
        logWriter: LogWriter
    ) {
        self.processManager = processManager
        self.logWriter = logWriter
    }

    // MARK: - 转码

    /// 将 webm 转码为 mp4
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

        do {
            _ = try await processManager.launchAndWait(
                executablePath: ffmpegPath,
                arguments: [
                    "-i", inputPath,
                    "-c:v", "libx264",
                    "-preset", "medium",
                    "-crf", "23",
                    "-an",
                    "-y",
                    outputPath
                ],
                timeout: 120
            )
        } catch {
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
        guard FileManager.default.fileExists(atPath: outputPath) else {
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
        do {
            _ = try await processManager.launchAndWait(
                executablePath: ffmpegPath,
                arguments: [
                    "-i", inputPath,
                    "-y",
                    outputPath
                ],
                timeout: 30
            )
        } catch {
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
