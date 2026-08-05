//
//  GameBackgroundRow.swift
//  MiPlay
//
//  Created by Steve Tan on 2026/6/21.
//

import SwiftUI
import UniformTypeIdentifiers

struct GameBackgroundRow: View {
    let game: GameType
    let viewModel: SettingsViewModel

    @State private var backgroundMode: BackgroundMode = .defaultDynamic
    @State private var customImagePath: String = ""
    @State private var showCustomImagePicker = false

    var body: some View {
        VStack(spacing: 8) {
            HStack {
                Image(systemName: game.placeholderIcon)
                    .foregroundStyle(game.themeColor)
                    .font(.title3)
                Text(game.displayName)
                Spacer()

                Picker("", selection: $backgroundMode) {
                    ForEach(BackgroundMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 280)
                .onChange(of: backgroundMode) { _, newMode in
                    if newMode == .customImage {
                        showCustomImagePicker = true
                    } else {
                        saveSettings()
                    }
                }
            }

            if backgroundMode == .customImage {
                HStack {
                    if customImagePath.isEmpty {
                        Text("未选择图片")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    } else {
                        Text(customImagePath)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    if !customImagePath.isEmpty {
                        Button("移除") {
                            customImagePath = ""
                            saveSettings()
                        }
                        .controlSize(.small)
                    }
                }
            }
        }
        .fileImporter(
            isPresented: $showCustomImagePicker,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first {
                    let cacheDir = Self.customBackgroundCacheDir(for: game)
                    let ext = url.pathExtension.isEmpty ? "png" : url.pathExtension
                    let destURL = cacheDir.appendingPathExtension(ext)
                    try? FileManager.default.removeItem(at: destURL)
                    try? FileManager.default.copyItem(at: url, to: destURL)
                    customImagePath = destURL.path
                    saveSettings()
                }
            case .failure: break
            }
        }
    }

    private func saveSettings() {
        Task {
            var settings = await viewModel.settingsStore.settings
            settings.perGameBackgroundMode[game] = backgroundMode
            if backgroundMode == .customImage, !customImagePath.isEmpty {
                settings.perGameCustomBackgroundPath[game] = customImagePath
            } else {
                settings.perGameCustomBackgroundPath[game] = nil
            }
            await viewModel.settingsStore.updateSettings(settings)
            try? await viewModel.settingsStore.saveSettings()
        }
    }

    private static func customBackgroundCacheDir(for game: GameType) -> URL {
        let urls = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)
        let dir = urls[0].appendingPathComponent("MiPlay/Backgrounds/\(game.hoyoBiz)_custom", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
