//
//  SettingsPathRow.swift
//  MiPlay
//
//  Created by Steve Tan on 2026/6/21.
//

import SwiftUI

struct SettingsPathRow: View {
    let title: String
    let path: String?
    let onOpen: () -> Void

    var body: some View {
        HStack {
            Text(title)
                .frame(width: 70, alignment: .leading)
            if let path = path {
                Text(path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            } else {
                Text("未设置")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Button("打开") {
                onOpen()
            }
            .controlSize(.small)
            .disabled(path == nil)
        }
    }
}
