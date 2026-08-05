//
//  PerGameSettingsRow.swift
//  MiPlay
//
//  Created by Steve Tan on 2026/6/21.
//

import SwiftUI

struct PerGameSettingsRow: View {
    let game: GameType
    let viewModel: SettingsViewModel

    @State private var useSeparateResolution = false
    @State private var resolutionWidth = ""
    @State private var resolutionHeight = ""

    var body: some View {
        Toggle("使用单独分辨率", isOn: $useSeparateResolution)

        if useSeparateResolution {
            HStack {
                Text("分辨率")
                Spacer()
                TextField("宽度", text: $resolutionWidth)
                    .frame(width: 70)
                Text("×")
                    .foregroundStyle(.secondary)
                TextField("高度", text: $resolutionHeight)
                    .frame(width: 70)
            }
        }
    }
}
