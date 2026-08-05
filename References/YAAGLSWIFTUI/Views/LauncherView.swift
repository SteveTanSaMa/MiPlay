import SwiftUI
import UniformTypeIdentifiers
import AVKit

/// Main launcher view for a specific game — replicates YAAGL's layout.
struct LauncherView: View {
    let game: Game

    @Environment(ConfigService.self) private var configService
    @Environment(GameService.self) private var gameService
    @Environment(WineService.self) private var wineService
    @Environment(DownloadService.self) private var downloadService

    @State private var isSettingsPresented = false
    @State private var isWineSetupPresented = false
    @State private var installState: GameInstallState = .notInstalled
    @State private var wineStatus: WineStatus = .notInstalled
    @State private var updateRequired = false
    @State private var statusText: String = ""
    @State private var progress: Double = 0
    @State private var isBusy: Bool = false
    @State private var showInstallDirPicker = false
    @State private var errorMessage: String?
    @State private var gameVersion: String?

    // Predownload
    @State private var showPredownloadPrompt = false
    @State private var predownloadVersion: String?

    // Adv content
    @State private var backgroundURL: URL?
    @State private var backgroundVideoURL: URL?
    @State private var logoURL: URL?
    @State private var iconURL: URL?
    @State private var videoLoaded = false

    var body: some View {
        ZStack {
            // Background image
            backgroundLayer

            // Background video overlay
            if let videoURL = backgroundVideoURL {
                videoLayer(url: videoURL)
            }

            // Logo
            if let logoURL {
                AsyncImage(url: logoURL) { phase in
                    if case .success(let image) = phase {
                        image.resizable().scaledToFit()
                            .frame(height: 234)
                    }
                }
                .position(x: 208, y: 117)
            }

            // Version icon
            if let iconURL, let website = game.websiteURL {
                GeometryReader { geo in
                    Button { NSWorkspace.shared.open(website) } label: {
                        AsyncImage(url: iconURL) { phase in
                            if case .success(let image) = phase {
                                image.resizable().scaledToFit()
                            }
                        }
                    }
                    .frame(width: 136, height: 40)
                    .buttonStyle(.plain)
                    .position(x: geo.size.width - 68, y: geo.size.height * 0.23)
                }
            }

            // Version info overlay (top-right)
            if let version = gameVersion {
                VStack {
                    HStack {
                        Spacer()
                        Text(version)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.7))
                            .padding(8)
                            .background(.black.opacity(0.3), in: .rect(cornerRadius: 4))
                            .padding(.trailing, 16)
                            .padding(.top, 8)
                    }
                    Spacer()
                }
            }

            // Bottom area
            VStack {
                Spacer()
                bottomArea
                    .padding(.horizontal, 40)
                    .padding(.bottom, 50)
            }
        }
        .ignoresSafeArea()
        .sheet(isPresented: $isSettingsPresented) {
            ConfigurationView(game: game, onReinstallWine: { isWineSetupPresented = true })
                .frame(minWidth: 700, minHeight: 500)
        }
        .sheet(isPresented: $isWineSetupPresented) {
            WineInstallView()
        }
        .fileImporter(
            isPresented: $showInstallDirPicker,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                handleInstallDirSelection(url)
            }
        }
        .alert("Error", isPresented: .init(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("OK") { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        // Predownload prompt
        .alert("Pre-download Available", isPresented: $showPredownloadPrompt) {
            Button("Download Now") { Task { await startPredownload() } }
            Button("Later", role: .cancel) { dismissPredownload() }
        } message: {
            if let ver = predownloadVersion {
                Text("Version \(ver) is available for pre-download.")
            } else {
                Text("A new version is available for pre-download.")
            }
        }
        .task { await initialize() }
        .onChange(of: game) { _, _ in Task { await initialize() } }
    }

    // MARK: - Background

    @ViewBuilder
    private var backgroundLayer: some View {
        if let bgURL = backgroundURL {
            AsyncImage(url: bgURL) { phase in
                if case .success(let image) = phase {
                    image.resizable().scaledToFill()
                }
            }
            .ignoresSafeArea()
        } else {
            LinearGradient(
                colors: [.accentColor.opacity(0.3), .black.opacity(0.6)],
                startPoint: .topLeading, endPoint: .bottomTrailing
            )
            .ignoresSafeArea()
        }
    }

    @ViewBuilder
    private func videoLayer(url: URL) -> some View {
        let player = AVPlayer(url: url)
        VideoPlayer(player: player)
            .onAppear {
                player.play()
                player.isMuted = true
                NotificationCenter.default.addObserver(
                    forName: .AVPlayerItemDidPlayToEndTime,
                    object: player.currentItem, queue: .main
                ) { _ in
                    player.seek(to: .zero)
                    player.play()
                }
            }
            .opacity(videoLoaded ? 1 : 0)
            .animation(.easeIn(duration: 0.5), value: videoLoaded)
            .allowsHitTesting(false)
            .ignoresSafeArea()
            .task {
                try? await Task.sleep(nanoseconds: 500_000_000)
                videoLoaded = true
            }
    }

    // MARK: - Bottom Area

    private var bottomArea: some View {
        HStack {
            // Version info on the left
            VStack(alignment: .leading, spacing: 4) {
                if let version = gameVersion {
                    Text("v\(version)")
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.8))
                }
                if updateRequired {
                    Label("Update available", systemImage: "arrow.down.circle")
                        .font(.caption2)
                        .foregroundStyle(.yellow)
                }
            }
            .shadow(radius: 2)

            Spacer()
            buttonGroup
        }
    }

    private var buttonGroup: some View {
        VStack(alignment: .trailing, spacing: 8) {
            // Status text + progress
            if isBusy || !statusText.isEmpty {
                VStack(alignment: .trailing, spacing: 4) {
                    if isBusy {
                        Text(statusText.isEmpty ? "Processing..." : statusText)
                            .font(.caption)
                            .foregroundStyle(.white)
                            .shadow(radius: 2)
                        ProgressView(value: progress > 0 ? progress : 0)
                            .progressViewStyle(.linear)
                            .frame(width: 200)
                            .opacity(progress > 0 ? 1 : 0)
                    }
                }
            }

            // Wine warning
            if case .notInstalled = wineStatus {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                    Text("Wine not installed").font(.caption2).foregroundStyle(.secondary)
                    Button("Setup") { isWineSetupPresented = true }
                        .buttonStyle(.borderedProminent).controlSize(.small)
                }
                .padding(8)
                .background(.ultraThinMaterial, in: .rect(cornerRadius: 6))
            }

            // Main buttons
            HStack(spacing: 0) {
                Button(action: handleActionButton) {
                    Text(buttonTitle)
                        .fontWeight(.semibold)
                        .frame(minWidth: 120, minHeight: 36)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(isBusy || (installState.isInstalled && wineStatus == .notInstalled))

                if installState.isInstalled {
                    Button { isSettingsPresented = true } label: {
                        Image(systemName: "gearshape")
                            .font(.title3)
                            .frame(minHeight: 36)
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.large)
                    .disabled(isBusy)
                }
            }
            .shadow(color: .black.opacity(0.2), radius: 2, y: 2)
        }
    }

    // MARK: - Button State

    private var buttonTitle: String {
        switch installState {
        case .notInstalled:
            return "Install"
        case .installed:
            return updateRequired ? "Update" : "Launch"
        case .installing:
            return "Installing..."
        case .updating:
            return "Updating..."
        case .launching:
            return "Launching..."
        }
    }

    // MARK: - Actions

    private func handleActionButton() {
        switch installState {
        case .notInstalled:
            showInstallDirPicker = true
        case .installed where updateRequired:
            Task { await startUpdate() }
        case .installed:
            Task { await launchGame() }
        default:
            break
        }
    }

    private func initialize() async {
        wineStatus = wineService.status
        let content = await HoyoverseAdvService.fetchAdvContent(for: game.server)
        backgroundURL = content.backgroundURL
        backgroundVideoURL = content.backgroundVideoURL
        logoURL = content.logoURL
        iconURL = content.iconURL
        await refreshState()
    }

    private func refreshState() async {
        let state = await gameService.installState(for: game)
        installState = state
        if case .installed(let version) = state { gameVersion = version }
        else { gameVersion = nil }

        updateRequired = await gameService.updateRequired(for: game)
        wineStatus = wineService.status
        statusText = ""
        progress = 0
        errorMessage = nil

        // Check predownload prompt
        let predownload = await gameService.predownloadInfo(for: game)
        if predownload.show, let ver = predownload.version {
            predownloadVersion = ver
            showPredownloadPrompt = true
        }
    }

    private func handleInstallDirSelection(_ url: URL) {
        guard url.startAccessingSecurityScopedResource() else {
            errorMessage = "Permission denied"
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }

        configService.setInstallDir(url.path, for: game)
        Task { await startInstall(to: url) }
    }

    // MARK: - Install

    private func startInstall(to directory: URL) async {
        isBusy = true
        installState = .installing(progress: 0)
        statusText = "Installing..."
        errorMessage = nil

        do {
            for try await event in gameService.install(game: game, to: directory) {
                handleProgressEvent(event)
            }
            await refreshState()
        } catch {
            errorMessage = error.localizedDescription
            installState = .notInstalled
        }
        isBusy = false
    }

    // MARK: - Update

    private func startUpdate() async {
        isBusy = true
        installState = .updating(progress: 0)
        statusText = "Updating..."
        errorMessage = nil

        do {
            for try await event in gameService.update(game: game) {
                handleProgressEvent(event)
            }
            await refreshState()
        } catch {
            errorMessage = error.localizedDescription
            await refreshState()
        }
        isBusy = false
    }

    // MARK: - Predownload

    private func startPredownload() async {
        isBusy = true
        statusText = "Pre-downloading..."
        errorMessage = nil

        do {
            for try await event in gameService.predownload(game: game) {
                handleProgressEvent(event)
            }
            statusText = "Pre-download complete"
        } catch {
            errorMessage = error.localizedDescription
        }
        isBusy = false
        showPredownloadPrompt = false
    }

    private func dismissPredownload() {
        if let client = gameService.client(for: game) {
            client.dismissPredownload()
        }
        showPredownloadPrompt = false
    }

    // MARK: - Launch

    private func launchGame() async {
        isBusy = true
        installState = .launching
        errorMessage = nil
        statusText = "Launching..."

        do {
            for try await event in gameService.launch(game: game) {
                handleProgressEvent(event)
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        installState = await gameService.installState(for: game)
        isBusy = false
    }

    // MARK: - Progress

    private func handleProgressEvent(_ event: ProgressEvent) {
        switch event {
        case .message(let msg):
            statusText = msg
        case .download(let dp):
            progress = dp.fraction
            if dp.speedBytesPerSecond > 0 {
                let speed = ByteCountFormatter.string(fromByteCount: Int64(dp.speedBytesPerSecond), countStyle: .file)
                statusText = "Downloading — \(speed)/s"
            }
        case .extraction(let current, let total):
            progress = total > 0 ? Double(current) / Double(total) : 0
            statusText = "Extracting (\(current)/\(total))..."
        case .patch(let current, let total):
            progress = total > 0 ? Double(current) / Double(total) : 0
            statusText = "Patching (\(current)/\(total))..."
        case .integrityCheck(let current, let total):
            progress = total > 0 ? Double(current) / Double(total) : 0
            statusText = "Verifying (\(current)/\(total))..."
        case .indeterminate:
            progress = 0
        case .completed:
            statusText = "Done"
            progress = 1.0
        case .failed(let err):
            errorMessage = err.localizedDescription
        }
    }
}

#Preview {
    NavigationStack {
        LauncherView(game: .hk4eCN)
            .environment(ConfigService())
    }
    .frame(width: 900, height: 600)
}
