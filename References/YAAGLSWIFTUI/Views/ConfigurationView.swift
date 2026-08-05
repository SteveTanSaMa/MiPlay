import SwiftUI

/// Settings sheet with vertical tab layout, matching YAAGL's configuration UI.
struct ConfigurationView: View {
    let game: Game
    let onReinstallWine: (() -> Void)?

    @Environment(ConfigService.self) private var configService
    @Environment(WineService.self) private var wineService
    @Environment(GameService.self) private var gameService
    @Environment(UpdaterService.self) private var updaterService
    @Environment(\.dismiss) private var dismiss

    @State private var selectedTab: ConfigTab = .general
    @State private var showAdvanced = false
    @State private var versionClickCount = 0

    enum ConfigTab: String, CaseIterable, Identifiable {
        case general, game, wine, advanced, licenses
        var id: String { rawValue }
        var label: LocalizedStringKey {
            switch self {
            case .general:  "General"
            case .game:     "Game"
            case .wine:     "Wine"
            case .advanced: "Advanced"
            case .licenses: "Licenses"
            }
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            // Vertical tab sidebar
            VStack(alignment: .leading, spacing: 2) {
                ForEach(visibleTabs) { tab in
                    Button {
                        selectedTab = tab
                    } label: {
                        Text(tab.label)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                    }
                    .buttonStyle(.plain)
                    .background(selectedTab == tab ? Color.accentColor.opacity(0.15) : .clear)
                    .clipShape(.rect(cornerRadius: 6))
                }
                Spacer()
            }
            .frame(width: 120)
            .padding(.vertical, 12)
            .background(.regularMaterial)

            Divider()

            // Content area
            HStack(spacing: 0) {
                // Main content
                ScrollView {
                    contentForTab
                        .padding()
                }

                // Quick actions sidebar
                VStack(alignment: .leading, spacing: 4) {
                    Text("Quick Actions")
                        .font(.headline)
                        .padding(.leading, 12)
                        .padding(.bottom, 8)

                    Button("Check Integrity") { Task { await runCheckIntegrity() } }
                    Button("Open CMD Window") { openCMDWindow() }
                    Button("Open Game Folder") { openGameFolder() }
                    Button("Open YAAGL Folder") { openYAAGLFolder() }
                    Button("Check for Updates") { Task { await checkForUpdates() } }
                    Spacer()
                }
                .buttonStyle(.plain)
                .frame(width: 160)
                .padding(.vertical, 12)
                .padding(.horizontal, 8)
                .background(.regularMaterial)
            }
        }
        .frame(minWidth: 600, minHeight: 420)
    }

    // MARK: - Visible Tabs

    private var visibleTabs: [ConfigTab] {
        ConfigTab.allCases.filter { tab in
            if tab == .advanced { return showAdvanced }
            return true
        }
    }

    // MARK: - Content

    @ViewBuilder
    private var contentForTab: some View {
        switch selectedTab {
        case .general:  generalTab
        case .game:     gameTab
        case .wine:     wineTab
        case .advanced: advancedTab
        case .licenses: licensesTab
        }
    }

    // MARK: General Tab

    private var generalTab: some View {
        @Bindable var cfg = configService
        return VStack(alignment: .leading, spacing: 16) {
            Group {
                FormLabel("Game Install Directory")
                Text(configService.config.installDir(for: game))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Divider()

            Toggle("Metal HUD", isOn: $cfg.config.metalHudEnabled)
            Toggle("Retina Mode", isOn: $cfg.config.retinaMode)
            Toggle("Left Command as Ctrl", isOn: $cfg.config.leftCommandIsCtrl)
            Divider()

            Toggle("Enable Proxy", isOn: $cfg.config.proxyEnabled)
            if configService.config.proxyEnabled {
                TextField("Proxy Host (127.0.0.1:8080)", text: $cfg.config.proxyHost)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 200)
            }
            Text("Use an HTTP proxy for game connections.")
                .font(.caption2).foregroundStyle(.tertiary)
            Divider()

            Picker("UI Language", selection: $cfg.config.uiLocale) {
                Text("System Default").tag("")
                ForEach(LocaleService.supportedLanguages) { lang in
                    Text(lang.displayName).tag(lang.id)
                }
            }
            .frame(maxWidth: 200)

            HStack {
                Text("YAAGL Version: 1.0.0")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .onTapGesture { unlockAdvanced() }
            }
        }
    }

    // MARK: Game Tab

    private var gameTab: some View {
        @Bindable var cfg = configService
        return VStack(alignment: .leading, spacing: 12) {
            Text("\(game.displayName) Settings")
                .font(.headline)
                .padding(.bottom, 4)

            switch game {
            case .hk4eCN, .hk4eGlobal:
                Group {
                    Toggle("Enable HDR", isOn: $cfg.config.hk4eEnableHDR)
                    Toggle("Custom Resolution", isOn: $cfg.config.hk4eResolutionCustom)
                    if configService.config.hk4eResolutionCustom {
                        HStack {
                            TextField("Width", text: $cfg.config.hk4eResolutionWidth).frame(width: 80)
                            Text("×")
                            TextField("Height", text: $cfg.config.hk4eResolutionHeight).frame(width: 80)
                        }
                        .textFieldStyle(.roundedBorder)
                    }
                    Divider()
                    Toggle("Turn Off AC Patch", isOn: $cfg.config.hk4ePatchOff)
                    Toggle("Steam Patch", isOn: $cfg.config.hk4eSteamPatch)
                    Toggle("Block Network", isOn: $cfg.config.hk4eBlockNet)
                    Toggle("Timeout Fix", isOn: $cfg.config.hk4eTimeoutFix)
                    Toggle("Workaround #3", isOn: $cfg.config.hk4eWorkaround3Enabled)
                }

            case .hkrpgCN, .hkrpgGlobal:
                Group {
                    Toggle("Turn Off Patches", isOn: $cfg.config.patchOff)
                    Toggle("Block Network", isOn: $cfg.config.blockNet)
                }

            case .napCN, .napGlobal:
                Group {
                    Toggle("Turn Off Patches", isOn: $cfg.config.patchOff)
                    Toggle("Block Network", isOn: $cfg.config.blockNet)
                    Toggle("Steam Patch", isOn: $cfg.config.steamPatch)
                    Toggle("Timeout Fix", isOn: $cfg.config.timeoutFix)
                    Toggle("Custom Resolution", isOn: $cfg.config.resolutionCustom)
                    if configService.config.resolutionCustom {
                        HStack {
                            TextField("Width", text: $cfg.config.resolutionWidth).frame(width: 80)
                            Text("×")
                            TextField("Height", text: $cfg.config.resolutionHeight).frame(width: 80)
                        }
                        .textFieldStyle(.roundedBorder)
                    }
                }

            case .bh3Global:
                Text("No additional settings for Honkai Impact 3rd")
                    .foregroundStyle(.secondary)

            case .cbjqCN, .cbjqGlobal:
                Text("No additional settings for Snowbreak")
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: Wine Tab

    private var wineTab: some View {
        @Bindable var cfg = configService
        return VStack(alignment: .leading, spacing: 16) {
            Picker("Wine Version", selection: $cfg.config.wineTag) {
                ForEach(WineDistribution.builtinDistributions) { distro in
                    Text(distro.displayName).tag(distro.id)
                }
            }
            .frame(maxWidth: 300)

            HStack {
                Text("Status:")
                Spacer()
                statusBadge
            }
            .font(.subheadline)

            Button("Reinstall Wine") {
                dismiss()
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                    onReinstallWine?()
                }
            }
            .buttonStyle(.borderedProminent)
        }
    }

    @ViewBuilder
    private var statusBadge: some View {
        switch wineService.status {
        case .notInstalled:
            Text("Not Installed").foregroundStyle(.secondary)
        case .installed(let d):
            Text("\(d.displayName) ✓").foregroundStyle(.green)
        case .needsUpdate(let c, _):
            Text("Update available: \(c.displayName)").foregroundStyle(.orange)
        }
    }

    // MARK: Advanced Tab

    private var advancedTab: some View {
        @Bindable var cfg = configService
        return VStack(alignment: .leading, spacing: 16) {
            Label("These settings may cause instability.", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
                .font(.caption)

            Picker("FPS Unlock", selection: $cfg.config.fpsUnlock) {
                ForEach(FPSUnlockOption.allCases) { opt in
                    Text(opt.displayValue).tag(opt)
                }
            }
            .frame(maxWidth: 200)

            Toggle("ReShade", isOn: $cfg.config.reshadeEnabled)

            Toggle("Ignore Launcher Updates", isOn: $cfg.config.ignoreLauncherUpdate)

            Divider()

            Button("Reset All Settings", role: .destructive) {
                configService.resetToDefaults()
            }
        }
    }

    // MARK: Licenses Tab

    private var licensesTab: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 8) {
                Text("Copyright Notice")
                    .font(.headline)
                Text("steam.exe and lsteamclient.dll (in the sidecar folder) are copyright © 2015-2022 Valve Corporation. All rights reserved.")
                    .font(.caption)
                Text("Redistribution and use in source and binary forms, with or without modification, are permitted provided that the following conditions are met:")
                    .font(.caption)
                    .padding(.top, 4)
                Group {
                    Text("1. Redistributions of source code must retain the above copyright notice.")
                    Text("2. Redistributions in binary form must reproduce the above copyright notice.")
                    Text("3. Neither the name of the copyright holder nor the names of its contributors may be used to endorse or promote products derived from this software without specific prior written permission.")
                }
                .font(.caption2).foregroundStyle(.secondary)
                Text("THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS \"AS IS\" AND ANY EXPRESS OR IMPLIED WARRANTIES ARE DISCLAIMED.")
                    .font(.caption2).foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Actions

    private func unlockAdvanced() {
        versionClickCount += 1
        if versionClickCount >= 5 {
            showAdvanced = true
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
            versionClickCount = 0
        }
    }

    private func openCMDWindow() {
        guard wineService.wineBinaryPath != nil else { return }
        Task {
            try? await wineService.run(program: "cmd", arguments: [])
        }
    }

    private func openGameFolder() {
        let dir = configService.config.installDir(for: game)
        guard !dir.isEmpty else { return }
        NSWorkspace.shared.open(URL(fileURLWithPath: dir))
    }

    private func openYAAGLFolder() {
        NSWorkspace.shared.open(FileSystemService.appSupportPath())
    }

    private func runCheckIntegrity() async {
        _ = gameService.checkIntegrity(game: game)
    }

    private func checkForUpdates() async {
        await updaterService.checkForUpdates()
        await MainActor.run {
            let alert = NSAlert()
            switch updaterService.updateState {
            case .upToDate:
                alert.messageText = "No updates available"
                alert.informativeText = "You are running the latest version."
            case .updateAvailable(let version, let notes):
                alert.messageText = "Update Available: v\(version)"
                alert.informativeText = notes ?? "A new version is available."
            case .failed(let error):
                alert.messageText = "Update Check Failed"
                alert.informativeText = error
            default:
                alert.messageText = "Checking..."
                alert.informativeText = "Please wait."
            }
            alert.runModal()
        }
    }
}

// MARK: - Helper View

private struct FormLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(.subheadline).foregroundStyle(.secondary)
    }
}

#Preview {
    ConfigurationView(game: .hk4eCN, onReinstallWine: nil)
        .environment(ConfigService())
}
