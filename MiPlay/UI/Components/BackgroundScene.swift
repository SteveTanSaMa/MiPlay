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

/// 播放器池：按 gameId 缓存 AVQueuePlayer + AVPlayerLooper。
/// 视频路径变化（切换背景组、悬停预览、重新转码）时必须重建播放器，
/// 否则会继续播放旧文件，文件被清理后则整层黑屏。
@Observable
final class PlayerPool {
    private struct Entry {
        let player: AVQueuePlayer
        let looper: AVPlayerLooper
        let videoPath: String
    }
    private var players: [String: Entry] = [:]

    func player(for gameId: String, videoPath: String) -> AVQueuePlayer {
        if let existing = players[gameId], existing.videoPath == videoPath {
            return existing.player
        }
        players[gameId]?.player.pause()
        let item = AVPlayerItem(url: URL(fileURLWithPath: videoPath))
        let queue = AVQueuePlayer()
        queue.isMuted = true  // Source: P1-03 — 素材音频不期望播放
        let looper = AVPlayerLooper(player: queue, templateItem: item)
        players[gameId] = Entry(player: queue, looper: looper, videoPath: videoPath)
        return queue
    }

    func pauseAll() {
        for entry in players.values { entry.player.pause() }
    }
}

/// NSView 承载 AVPlayerLayer，非 opaque，clear 背景。
final class PlayerLayerView: NSView {
    fileprivate let playerLayer: AVPlayerLayer

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

    func updateNSView(_ nsView: PlayerLayerView, context: Context) {
        // The pool rebuilds the player when the video path changes; the layer
        // must follow, otherwise a stale or stopped player keeps the layer
        // blank.
        if (nsView.playerLayer.player as? AVQueuePlayer) !== player {
            nsView.playerLayer.player = player
        }
    }
}

/// 图片只在路径改变时读取；文件读取在后台执行，避免 body 反复访问磁盘。
struct ImageBackgroundView: View {
    let imagePath: String
    @State private var image: NSImage?

    var body: some View {
        ZStack {
            Color.clear
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            }
        }
        .task(id: imagePath) {
            let path = imagePath
            let data = await Task.detached(priority: .utility) {
                try? Data(contentsOf: URL(fileURLWithPath: path))
            }.value
            guard !Task.isCancelled else { return }
            image = data.flatMap { NSImage(data: $0) }
        }
    }
}

/// 自包含背景场景：内部决定视频/图片 + theme 的渲染组合
struct BackgroundScene: View {
    let media: BackgroundMedia
    let gameId: String
    var isSelected = true
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var player: AVQueuePlayer?
    @State private var pool = PlayerPool()

    var body: some View {
        ZStack {
            // The still image stays underneath a video background: it covers
            // first-frame loading and failed playback instead of a black layer.
            ImageBackgroundView(imagePath: media.imagePath)
                .offset(y: -16)

            if let player, !reduceMotion {
                PoolVideoView(player: player)
                    .offset(y: -16)
            }

            if let themePath = media.themePath {
                ImageBackgroundView(imagePath: themePath)
                    .allowsHitTesting(false)
                    .offset(y: -16)
            }
        }
        .task(id: media.videoPath) { updatePlayback() }
        .onChange(of: shouldPlay) { _, _ in updatePlayback() }
        .onDisappear { pool.pauseAll() }
    }

    private var shouldPlay: Bool {
        isSelected && !reduceMotion && scenePhase == .active
    }

    private func updatePlayback() {
        guard shouldPlay, let path = media.videoPath else {
            pool.pauseAll()
            if media.videoPath == nil { player = nil }
            return
        }
        let current = pool.player(for: gameId, videoPath: path)
        player = current
        current.play()
    }
}
