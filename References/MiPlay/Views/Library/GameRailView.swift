//
//  GameRailView.swift
//  MiPlay
//
//  Created by Steve Tan on 2026/6/21.
//
//  左下角游戏栏：三个游戏图标纵向排列。
//  使用 Liquid Glass 毛玻璃效果。
//

import SwiftUI

/// 左下角游戏栏组件
struct GameRailView: View {
    @Binding var selectedGame: GameType
    let games: [GameType]

    @State private var hoveredGame: GameType?

    var body: some View {
        VStack(spacing: 14) {
            ForEach(games) { game in
                GameRailButton(
                    game: game,
                    isSelected: selectedGame == game,
                    isHovered: hoveredGame == game
                )
                .onTapGesture {
                    withAnimation(.spring(response: 0.4, dampingFraction: 0.7)) {
                        selectedGame = game
                    }
                }
                .onHover { hovering in
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) {
                        hoveredGame = hovering ? game : nil
                    }
                }
            }
        }
        .padding(12)
        .panelGlass()
    }
}

// MARK: - 单个游戏图标按钮

private struct GameRailButton: View {
    let game: GameType
    let isSelected: Bool
    let isHovered: Bool

    var body: some View {
        Image(systemName: game.placeholderIcon)
            .font(.title)
            .fontWeight(.medium)
            .foregroundStyle(foregroundColor)
            .frame(width: 64, height: 64)
            .background(
                RoundedRectangle(cornerRadius: 16)
                    .fill(backgroundColor)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(strokeColor, lineWidth: isSelected ? 2 : 0.5)
            )
            .scaleEffect(isHovered ? 1.12 : 1.0)
            .shadow(
                color: isSelected ? game.themeColor.opacity(0.5) : .clear,
                radius: isSelected ? 12 : 0,
                y: isSelected ? 4 : 0
            )
    }

    private var foregroundColor: Color {
        if isSelected {
            return .white
        }
        return isHovered ? .white.opacity(0.85) : .white.opacity(0.55)
    }

    private var backgroundColor: Color {
        if isSelected {
            return game.themeColor.opacity(0.35)
        }
        return .white.opacity(0.08)
    }

    private var strokeColor: Color {
        if isSelected {
            return .white.opacity(0.5)
        }
        return .white.opacity(0.12)
    }
}

#Preview {
    ZStack {
        Color.black

        GameRailView(
            selectedGame: .constant(.genshinImpact),
            games: GameType.allCases
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
        .padding(.leading, 30)
        .padding(.bottom, 40)
    }
    .frame(width: 800, height: 500)
}

