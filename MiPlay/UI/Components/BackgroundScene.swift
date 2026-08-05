//
//  BackgroundScene.swift
//  MiPlay
//

import SwiftUI
import AVFoundation

// Source: Architecture Design → BackgroundScene 组件化重构

/// 单款游戏的背景媒体数据
public struct BackgroundMedia: Sendable {
    public let imagePath: String
    public let videoPath: String?
    public let themePath: String?

    public init(imagePath: String, videoPath: String? = nil, themePath: String? = nil) {
        self.imagePath = imagePath
        self.videoPath = videoPath
        self.themePath = themePath
    }
}

/// 播放器池：按 gameId 缓存 AVQueuePlayer + AVPlayerLooper
@Observable
final class PlayerPool {
    private struct Entry {
        let player: AVQueuePlayer
        let looper: AVPlayerLooper
    }
    private var players: [String: Entry] = [:]

    func player(for gameId: String, videoPath: String) -> AVQueuePlayer {
        if let existing = players[gameId] { return existing.player }
        let item = AVPlayerItem(url: URL(fileURLWithPath: videoPath))
        let queue = AVQueuePlayer()
        queue.isMuted = true  // Source: P1-03 — 素材音频不期望播放
        let looper = AVPlayerLooper(player: queue, templateItem: item)
        queue.play()
        players[gameId] = Entry(player: queue, looper: looper)
        return queue
    }
}

/// NSView 承载 AVPlayerLayer，非 opaque，clear 背景。
final class PlayerLayerView: NSView {
    private let playerLayer: AVPlayerLayer

    init(playerLayer: AVPlayerLayer) {
        self.playerLayer = playerLayer
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        layer?.masksToBounds = true
        layer?.addSublayer(playerLayer)
    }

    required init?(coder: NSCoder) { fatalError() }
    override var isOpaque: Bool { false }


    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        playerLayer.frame = bounds
        CATransaction.commit()
    }
}

/// 视频视图：从 PlayerPool 取 AVQueuePlayer
struct PoolVideoView: NSViewRepresentable {
    let player: AVQueuePlayer

    func makeNSView(context: Context) -> PlayerLayerView {
        let layer = AVPlayerLayer()
        layer.player = player
        layer.videoGravity = .resizeAspectFill
        return PlayerLayerView(playerLayer: layer)
    }

    func updateNSView(_ nsView: PlayerLayerView, context: Context) {}
}

/// 图片背景
struct ImageBackgroundView: View {
    let imagePath: String
    var body: some View {
        if let image = NSImage(contentsOfFile: imagePath) {
            // Source: P3-016 — 清理调试死代码
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
        }
    }
}

/// Theme 装饰叠加层
struct ThemeOverlayView: View {
    let imagePath: String
    var body: some View {
        if let image = NSImage(contentsOfFile: imagePath) {
            // Source: P3-016 — 清理调试死代码
            Image(nsImage: image)
                .resizable()
                .aspectRatio(contentMode: .fill)
                .allowsHitTesting(false)
        }
    }
}

/// 自包含背景场景：内部决定视频/图片 + theme 的渲染组合
struct BackgroundScene: View {
    let media: BackgroundMedia
    let gameId: String
    @State private var pool = PlayerPool()

    var body: some View {
        ZStack {
            if let videoPath = media.videoPath {
                PoolVideoView(player: pool.player(for: gameId, videoPath: videoPath))
                    .offset(y: -16)
            } else {
                ImageBackgroundView(imagePath: media.imagePath)
                    .offset(y: -16)
            }

            if let themePath = media.themePath {
                ThemeOverlayView(imagePath: themePath)
                    .offset(y: -16)
            }
        }
        // Source: P3-016 — 清理调试死代码
    }
}
