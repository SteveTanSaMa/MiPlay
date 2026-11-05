import SwiftUI

/// Secondary content beside the game rail; bounded rows keep the artwork dominant.
struct GameNewsPanel: View {
    let game: GameType
    let imageCache: NewsBannerImageCache
    @State private var model: GameNewsViewModel
    @Environment(\.openURL) private var openURL

    init(game: GameType, provider: any GameNewsProviding, imageCache: NewsBannerImageCache) {
        self.game = game
        self.imageCache = imageCache
        _model = State(initialValue: GameNewsViewModel(provider: provider))
    }

    var body: some View {
        VStack(spacing: 0) {
            if let news = model.news, news.game == game, !news.banners.isEmpty {
                NewsBannerCarousel(game: game, banners: news.banners, imageCache: imageCache)
            }
            VStack(alignment: .leading, spacing: 8) {
                Picker("新闻分类", selection: $model.category) {
                    ForEach(GameNewsCategory.allCases, id: \.self) { category in
                        Text(category.title).tag(category)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .pickerStyle(.segmented)
                .controlSize(.large)
                .font(.system(size: 14))
                .labelsHidden()
                .focusable()
                .onKeyPress(keys: [.leftArrow, .rightArrow], phases: .down) { press in
                    let categories = GameNewsCategory.allCases
                    guard let index = categories.firstIndex(of: model.category) else { return .ignored }
                    let next = min(max(index + (press.key == .leftArrow ? -1 : 1), 0), categories.count - 1)
                    model.category = categories[next]
                    return .handled
                }
                newsRows
                    .frame(height: 96, alignment: .top)
            }
            .padding(12)
        }
        // Clip the artwork itself while allowing the glass surface to draw its
        // own edge and refraction outside the panel's content.
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .modifier(DarkGlassSurface(interactive: false))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(game.displayName)游戏新闻")
        .task(id: game) {
            await model.load(for: game)
        }
    }

    @ViewBuilder private var newsRows: some View {
        if model.news?.game == game, let news = model.news {
            let posts = news.posts(in: model.category)
            if posts.isEmpty {
                statusRow("暂无\(model.category.title)", symbol: "newspaper")
            } else {
                ScrollView(.vertical) {
                    VStack(spacing: 0) {
                        ForEach(posts) { post in
                            Link(destination: post.link) {
                                HStack(spacing: 8) {
                                    Text(post.title).lineLimit(1).truncationMode(.tail)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                    Text(post.date).font(.body).monospacedDigit().foregroundStyle(.secondary)
                                }
                                .font(.system(size: 14))
                                .frame(height: 32)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.link)
                            .focusable()
                            .onKeyPress(keys: [.return, .space], phases: .down) { _ in
                                openURL(post.link)
                                return .handled
                            }
                            .foregroundStyle(.primary)
                            .help(post.title)
                            .accessibilityLabel(post.title)
                            .accessibilityValue(post.date)
                            .accessibilityHint("在默认浏览器中打开")
                        }
                    }
                }
                .scrollDisabled(posts.count <= 3)
                .id("\(game.rawValue)-\(model.category.rawValue)")
            }
        } else if model.state == .failed {
            statusRow("暂时无法加载新闻", symbol: "wifi.exclamationmark")
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("正在加载新闻…").font(.system(size: 14)).foregroundStyle(.secondary)
            }.frame(minHeight: 56)
        }
    }

    private func statusRow(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.system(size: 14)).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 56, alignment: .leading)
    }
}

private struct NewsBannerCarousel: View {
    let game: GameType
    let banners: [GameNews.Banner]
    let imageCache: NewsBannerImageCache
    @State private var index = 0
    @State private var hovering = false
    @State private var resumeAfter: Date?
    @AccessibilityFocusState private var accessibilityFocus: BannerControl?
    @FocusState private var keyboardFocus: BannerControl?
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var current: GameNews.Banner? {
        guard !banners.isEmpty else { return nil }
        return banners[min(index, banners.count - 1)]
    }
    private var canRotate: Bool {
        banners.count > 1 && !reduceMotion && scenePhase == .active && !hovering
            && accessibilityFocus == nil && keyboardFocus == nil
    }

    var body: some View {
        VStack(spacing: 0) {
            if let banner = current {
                Link(destination: banner.link) {
                    NewsBannerImageView(url: banner.imageURL, imageCache: imageCache)
                }
                .buttonStyle(.plain)
                .focusable()
                .onKeyPress(keys: [.return, .space], phases: .down) { _ in
                    openURL(banner.link)
                    return .handled
                }
                .accessibilityLabel("\(game.displayName)官方活动，\(min(index + 1, banners.count))/\(banners.count)")
                .accessibilityHint("在默认浏览器中打开")
                .onKeyPress(keys: [.leftArrow, .rightArrow], phases: .down) { press in
                    manuallyAdvance(press.key == .leftArrow ? -1 : 1)
                    return .handled
                }
                .accessibilityAction(named: Text("上一个活动")) { manuallyAdvance(-1) }
                .accessibilityAction(named: Text("下一个活动")) { manuallyAdvance(1) }
                .focused($keyboardFocus, equals: .banner)
                .accessibilityFocused($accessibilityFocus, equals: .banner)
            }
        }
        .overlay {
            if banners.count > 1 {
                HStack {
                    bannerArrow("上一个活动", symbol: "chevron.left", delta: -1)
                    Spacer()
                    bannerArrow("下一个活动", symbol: "chevron.right", delta: 1)
                }
                .padding(.horizontal, 8)
                .opacity(hovering ? 1 : 0)
                .allowsHitTesting(hovering)
                .accessibilityHidden(!hovering)
                .animation(reduceMotion ? nil : .easeInOut(duration: 0.15), value: hovering)
            }
        }
        .onHover { hovering = $0 }
        .onChange(of: game) { _, _ in index = 0; resumeAfter = nil }
        .onChange(of: banners) { _, _ in index = 0; resumeAfter = nil }
        .task(id: RotationKey(game: game, ids: banners.map(\.id), enabled: canRotate, resumeAfter: resumeAfter)) {
            guard canRotate else { return }
            var delay = max(8, resumeAfter?.timeIntervalSinceNow ?? 0)
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(delay)) } catch { return }
                guard !Task.isCancelled else { return }
                advance(1)
                delay = 8
            }
        }
    }

    private func bannerArrow(_ label: String, symbol: String, delta: Int) -> some View {
        Button {
            manuallyAdvance(delta)
        } label: {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .frame(width: 32, height: 36)
                .foregroundStyle(.white)
                .modifier(DarkGlassSurface())
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .help(label)
    }

    private func manuallyAdvance(_ delta: Int) {
        resumeAfter = Date().addingTimeInterval(20)
        advance(delta)
    }

    private func advance(_ delta: Int) {
        guard !banners.isEmpty else { index = 0; return }
        // Image replacement uses a short fade; accessibility motion disables all animation.
        withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) {
            index = (min(index, banners.count - 1) + delta + banners.count) % banners.count
        }
    }
    private enum BannerControl: Hashable { case banner }
    private struct RotationKey: Hashable { let game: GameType; let ids: [String]; let enabled: Bool; let resumeAfter: Date? }
}

private struct NewsBannerImageView: View {
    let url: URL
    let imageCache: NewsBannerImageCache
    @State private var loaded: NewsBannerImage?
    @State private var failed = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if let loaded {
                Image(decorative: loaded.cgImage, scale: 1)
                    .resizable().scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: 160)
                    .transition(.opacity)
            } else if failed {
                Label("查看官方活动", systemImage: "arrow.up.right")
                    .font(.system(size: 14))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView().controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(height: 160)
        .animation(reduceMotion ? nil : .easeInOut(duration: 0.2), value: loaded != nil)
        .task(id: url) {
            loaded = nil
            failed = false
            do {
                let image = try await imageCache.image(for: url)
                guard !Task.isCancelled else { return }
                loaded = image
            } catch {
                guard !Task.isCancelled else { return }
                failed = true
            }
        }
    }
}
