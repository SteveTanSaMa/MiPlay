//
//  WineVersionRow.swift
//  MiPlay
//
//  Created by Steve Tan on 2026/6/21.
//

import SwiftUI

struct WineVersionRow: View {
    let version: WineVersion
    let viewModel: SettingsViewModel

    private var isInstalled: Bool {
        viewModel.availableWineVersions.contains(where: { $0.version == version.version })
    }

    private var isSelected: Bool {
        viewModel.selectedWineVersion == version.version
    }

    private var isDownloading: Bool {
        viewModel.installingVersionID == version.id
    }

    private var fileSizeText: String {
        guard let size = version.fileSize else { return "" }
        let mb = Double(size) / 1_000_000
        if mb > 1000 {
            return String(format: "%.1f GB", mb / 1000)
        }
        return String(format: "%.0f MB", mb)
    }

    var body: some View {
        HStack(spacing: 10) {
            if isSelected {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.tint)
                    .font(.body)
            } else {
                Circle()
                    .strokeBorder(.secondary.opacity(0.3), lineWidth: 1)
                    .frame(width: 16, height: 16)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(version.name)
                    .font(.body)
                    .foregroundStyle(isInstalled ? .primary : .secondary)
                    .lineLimit(1)

                if isDownloading {
                    if let progress = viewModel.wineInstallProgress {
                        Text("\(Int(progress * 100))% - \(fileSizeText)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                } else if isInstalled {
                    Text("\(version.version) · \(fileSizeText)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(fileSizeText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if isDownloading {
                ZStack {
                    Circle()
                        .stroke(.secondary.opacity(0.2), lineWidth: 3)
                        .frame(width: 24, height: 24)
                    Circle()
                        .trim(from: 0, to: viewModel.wineInstallProgress ?? 0)
                        .stroke(.tint, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                        .frame(width: 24, height: 24)
                        .rotationEffect(.degrees(-90))
                        .animation(.easeInOut(duration: 0.2), value: viewModel.wineInstallProgress)
                }
            } else if isInstalled {
                Button(role: .destructive) {
                    Task { await viewModel.removeWineVersion(version.version) }
                } label: {
                    Image(systemName: "trash")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .help("删除此版本")
            } else {
                Button {
                    Task { await viewModel.installWineVersion(version) }
                } label: {
                    Image(systemName: "icloud.and.arrow.down")
                        .foregroundStyle(.tint)
                }
                .buttonStyle(.plain)
                .help("下载并安装此版本")
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            if isInstalled {
                viewModel.selectedWineVersion = version.version
            }
        }
    }
}
