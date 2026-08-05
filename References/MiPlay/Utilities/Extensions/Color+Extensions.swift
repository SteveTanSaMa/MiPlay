//
//  Color+Extensions.swift
//  MiPlay
//
//  Created by Steve Tan on 2026/6/20.
//

import SwiftUI

extension Color {
    static let accent = Color.accentColor
    static let cardBackground = Color(nsColor: .controlBackgroundColor)
    static let sidebarBackground = Color(nsColor: .windowBackgroundColor)

    // Game-specific colors
    static let genshinGold = Color(red: 1.0, green: 0.84, blue: 0.0)
    static let starRailBlue = Color(red: 0.29, green: 0.57, blue: 0.95)
    static let zenlessOrange = Color(red: 1.0, green: 0.65, blue: 0.0)

    // Status colors
    static let statusGreen = Color.green
    static let statusYellow = Color.yellow
    static let statusRed = Color.red
}
