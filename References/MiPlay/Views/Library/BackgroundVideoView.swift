//
//  BackgroundVideoView.swift
//  MiPlay
//
//  Created by Steve Tan on 2026/6/21.
//
//  背景容器：mp4 视频 + theme 叠加层。
//  视频通过 ffmpeg 从 webm 转码得来，theme 为版本标题装饰图。
//

import SwiftUI
import AVKit

/// 无控制条的纯播放器
struct SilentPlayerView: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.player = player
        view.controlsStyle = .none
        view.showsFullScreenToggleButton = false
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        nsView.player = player
    }
}

/// 背景容器：视频 + theme 叠加
struct BackgroundVideoView: View {
    let assets: GameBackgroundAssets?
    let useCustomImage: Bool
    let customImage: NSImage?
    let fillMode: BackgroundFillMode
    let localVideoURL: URL?
    let localThemeURL: URL?      // 本地缓存的 theme 图片

    @State private var player: AVPlayer?
    @State private var looper: NSObjectProtocol?
    @State private var themeImage: NSImage?

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                defaultBackground

                if useCustomImage, let image = customImage {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: fillMode == .fill ? .fill : .fit)
                        .frame(width: geometry.size.width, height: geometry.size.height)
                } else if let player = player {
                    // 视频
                    SilentPlayerView(player: player)
                        .frame(width: geometry.size.width, height: geometry.size.height)

                    // theme 叠加层
                    if let theme = themeImage {
                        Image(nsImage: theme)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: geometry.size.width, height: geometry.size.height)
                    }
                } else if let bgURL = assets?.backgroundURL {
                    AsyncImage(url: bgURL) { phase in
                        if let image = phase.image {
                            image
                                .resizable()
                                .aspectRatio(contentMode: .fill)
                                .frame(width: geometry.size.width, height: geometry.size.height)
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        }
        .onAppear {
            loadThemeImage()
            setupPlayer()
        }
        .onDisappear { tearDownPlayer() }
        .onChange(of: localVideoURL) { _, _ in
            tearDownPlayer()
            loadThemeImage()
            setupPlayer()
        }
    }

    private func loadThemeImage() {
        if let themeURL = localThemeURL,
           let data = try? Data(contentsOf: themeURL) {
            themeImage = NSImage(data: data)
        } else if let themeURL = assets?.themeURL {
            // 回退：从网络加载
            Task {
                if let data = try? await URLSession.shared.data(from: themeURL).0,
                   let image = NSImage(data: data) {
                    await MainActor.run { themeImage = image }
                }
            }
        }
    }

    private func setupPlayer() {
        guard let videoURL = localVideoURL else { return }

        let playerItem = AVPlayerItem(url: videoURL)
        player = AVPlayer(playerItem: playerItem)
        player?.isMuted = true
        player?.actionAtItemEnd = .none
        player?.play()

        looper = NotificationCenter.default.addObserver(
            forName: .AVPlayerItemDidPlayToEndTime,
            object: playerItem,
            queue: .main
        ) { [weak player] _ in
            player?.seek(to: .zero)
            player?.play()
        }
    }

    private func tearDownPlayer() {
        player?.pause()
        player = nil
        if let looper = looper {
            NotificationCenter.default.removeObserver(looper)
        }
        looper = nil
    }

    private var defaultBackground: some View {
        DefaultGradientBackground()
    }
}
