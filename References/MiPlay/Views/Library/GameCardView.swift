//
//  GameCardView.swift
//  MiPlay
//
//  Created by Steve Tan on 2026/6/20.
//

import SwiftUI

struct GameCardView: View {
    let game: Game
    var isLaunching: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ZStack {
                gameBackground
                    .frame(height: 160)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                gameIcon
            }

            VStack(alignment: .leading, spacing: 4) {
                Text(game.type.displayName)
                    .font(.headline)
                    .lineLimit(1)

                Text(game.type.englishName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)

                HStack(spacing: 6) {
                    StatusBadge(status: game.installStatus)
                    Spacer()
                    if let version = game.version {
                        Text("v\(version)")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                }
            }
            .padding(.horizontal, 4)
        }
        .padding(12)
        .cardStyle()
        .overlay {
            if isLaunching {
                    CardLaunchingOverlay()
            }
        }
    }

    private var gameBackground: some View {
        LinearGradient(
            colors: gradientColors,
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
    }

    private var gradientColors: [Color] {
        switch game.type {
        case .genshinImpact: return [.genshinGold.opacity(0.6), .genshinGold.opacity(0.2)]
        case .starRail: return [.starRailBlue.opacity(0.6), .starRailBlue.opacity(0.2)]
        case .zenlessZoneZero: return [.zenlessOrange.opacity(0.6), .zenlessOrange.opacity(0.2)]
        }
    }

    private var gameIcon: some View {
        Image(systemName: gameIconName)
            .font(.system(size: 48))
            .foregroundStyle(.white.opacity(0.8))
    }

    private var gameIconName: String {
        switch game.type {
        case .genshinImpact: return "wind"
        case .starRail: return "star.fill"
        case .zenlessZoneZero: return "flame.fill"
        }
    }
}

