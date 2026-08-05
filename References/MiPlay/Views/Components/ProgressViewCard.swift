//
//  ProgressViewCard.swift
//  MiPlay
//
//  Created by Steve Tan on 2026/6/20.
//

import SwiftUI

struct ProgressViewCard: View {
    let title: String
    let description: String?
    let progress: Double
    let statusMessage: String?

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.headline)
                    if let description = description {
                        Text(description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer()
                ProgressView()
                    .scaleEffect(0.8)
                    .opacity(progress < 1.0 ? 1 : 0)
            }

            ProgressView(value: progress > 0 ? progress : nil)
                .tint(.accentColor)

            if let statusMessage = statusMessage {
                HStack {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("\(Int(progress * 100))%")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
        .padding()
        .cardStyle()
    }
}
