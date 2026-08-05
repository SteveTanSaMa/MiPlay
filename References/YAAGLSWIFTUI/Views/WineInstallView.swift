import SwiftUI
import UniformTypeIdentifiers

/// Wine installation / setup wizard.
/// Shown as a sheet when the user needs to install Wine.
struct WineInstallView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(ConfigService.self) private var configService
    @Environment(WineService.self) private var wineService
    @Environment(DownloadService.self) private var downloadService
    @State private var installState: WineSetupState = .checking
    @State private var showLocalFilePicker = false

    enum WineSetupState {
        case checking
        case ready(distribution: WineDistribution)
        case installing(phase: String)
        case complete(distribution: WineDistribution)
        case failed(String)
    }

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "wineglass")
                .font(.system(size: 48))
                .foregroundStyle(.tint)

            Text("Wine Setup")
                .font(.largeTitle)
                .fontWeight(.bold)

            switch installState {
            case .checking:
                ProgressView("Checking Wine installation...")

            case .ready(let distro):
                VStack(spacing: 16) {
                    Text("Wine is not installed or needs an update.")
                        .foregroundStyle(.secondary)

                    VStack(alignment: .leading, spacing: 8) {
                        Label("Distribution: \(distro.displayName)", systemImage: "info.circle")
                            .font(.subheadline)
                        Label("Download is ~500MB; or select a local archive file.",
                              systemImage: "clock")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    .padding()
                    .background(.regularMaterial, in: .rect(cornerRadius: 8))

                    VStack(spacing: 12) {
                        Button("Download & Install Wine") {
                            Task { await installWineFromRemote(distro) }
                        }
                        .buttonStyle(.borderedProminent)

                        Button("Use Local File...") {
                            showLocalFilePicker = true
                        }
                        .buttonStyle(.bordered)

                        Button("Cancel") { dismiss() }
                            .buttonStyle(.plain)
                    }
                }

            case .installing(let phase):
                VStack(spacing: 12) {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text(phase)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }

            case .complete:
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.green)
                    Text("Wine is ready!")
                        .font(.title2)
                    Button("Continue") { dismiss() }
                        .buttonStyle(.borderedProminent)
                }

            case .failed(let error):
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.red)
                    Text("Installation failed")
                        .font(.title2)
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                    HStack(spacing: 16) {
                        Button("Cancel") { dismiss() }
                            .buttonStyle(.bordered)
                        Button("Retry") {
                            installState = .checking
                            Task { await checkWine() }
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
            }
        }
        .padding(40)
        .frame(width: 500)
        .interactiveDismissDisabled(installState.isInProgress)
        .fileImporter(
            isPresented: $showLocalFilePicker,
            allowedContentTypes: [.init(filenameExtension: "tar.xz") ?? .data, .init(filenameExtension: "tar.gz") ?? .data],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    Task { await installWineFromLocal(url) }
                }
            case .failure(let error):
                installState = .failed(error.localizedDescription)
            }
        }
        .task {
            await checkWine()
        }
    }

    private func checkWine() async {
        installState = .checking
        let distro = configService.wineDistribution
        installState = .ready(distribution: distro)
    }

    private func installWineFromRemote(_ distro: WineDistribution) async {
        installState = .installing(phase: "Downloading and installing Wine...")
        do {
            try await wineService.installDistribution(distro, downloadService: downloadService)
            installState = .complete(distribution: distro)
        } catch {
            installState = .failed(error.localizedDescription)
        }
    }

    private func installWineFromLocal(_ url: URL) async {
        guard url.startAccessingSecurityScopedResource() else {
            installState = .failed("Permission denied")
            return
        }
        defer { url.stopAccessingSecurityScopedResource() }

        installState = .installing(phase: "Extracting and configuring Wine...")
        do {
            let distro = configService.wineDistribution
            try await wineService.installDistribution(fromLocalArchive: url, distribution: distro)
            installState = .complete(distribution: distro)
        } catch {
            installState = .failed(error.localizedDescription)
        }
    }
}

extension WineInstallView.WineSetupState {
    var isInProgress: Bool {
        if case .installing = self { return true }
        return false
    }
}

#Preview {
    WineInstallView()
        .environment(ConfigService())
}
