//
//  StatusBadge.swift
//  MiPlay
//
//  Created by Steve Tan on 2026/6/20.
//

import SwiftUI

struct StatusBadge: View {
    let status: GameInstallStatus
    let showIcon: Bool

    init(status: GameInstallStatus, showIcon: Bool = true) {
        self.status = status
        self.showIcon = showIcon
    }

    var body: some View {
        HStack(spacing: 4) {
            if showIcon {
                Circle()
                    .fill(color)
                    .frame(width: 6, height: 6)
            }
            Text(text)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(color.opacity(0.1))
        .clipShape(Capsule())
    }

    private var color: Color {
        switch status {
        case .notInstalled: return .statusRed
        case .downloading: return .statusYellow
        case .installed: return .statusGreen
        case .needsUpdate: return .statusYellow
        case .broken: return .statusRed
        }
    }

    private var text: String {
        switch status {
        case .notInstalled: return "未安装"
        case .downloading: return "下载中"
        case .installed: return "已安装"
        case .needsUpdate: return "可更新"
        case .broken: return "异常"
        }
    }
}
