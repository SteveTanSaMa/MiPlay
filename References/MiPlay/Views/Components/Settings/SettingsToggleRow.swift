//
//  SettingsToggleRow.swift
//  MiPlay
//
//  Created by Steve Tan on 2026/6/21.
//

import SwiftUI

struct SettingsToggleRow: View {
    let title: String
    @Binding var isOn: Bool
    let help: String?

    init(title: String, isOn: Binding<Bool>, help: String? = nil) {
        self.title = title
        self._isOn = isOn
        self.help = help
    }

    var body: some View {
        Toggle(title, isOn: $isOn)
            .help(help ?? "")
    }
}
