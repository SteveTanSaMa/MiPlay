//
//  StatusBadge.swift
//  MiPlay
//
//  Created by Steve Tan on 2026/7/7.
//

import SwiftUI

// Source: UI Design → 组件树 → StatusBadge
// Source: UI Design → 主界面状态映射 → 状态徽章

/// 游戏状态徽章组件。
/// 根据游戏业务状态显示不同的颜色和文字。
struct StatusBadge: View {
    let state: GameBusinessState

    var body: some View {
        HStack(spacing: 6) {
            Circle()
                .fill(statusColor)
                .frame(width: 8, height: 8)

            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(statusColor.opacity(0.1))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(statusColor.opacity(0.2), lineWidth: 1)
        )
    }

    private var statusColor: Color {
        switch state {
        case .notInstalled:
            return .gray
        case .installed:
            return .green
        case .updateAvailable:
            return .orange
        case .gameUpdating:
            return .blue
        case .launching:
            return .blue
        case .running:
            return .green
        case .launchFailed:
            return .red
        }
    }

    private var statusText: String {
        switch state {
        case .notInstalled:
            return "未安装"
        case .installed:
            return "已就绪"
        case .updateAvailable:
            return "可更新"
        case .gameUpdating:
            return "更新中"
        case .launching:
            return "启动中"
        case .running:
            return "运行中"
        case .launchFailed:
            return "启动失败"
        }
    }
}

#Preview {
    VStack {
        StatusBadge(state: .installed)
        StatusBadge(state: .notInstalled)
        StatusBadge(state: .running)
        StatusBadge(state: .launchFailed)
        StatusBadge(state: .updateAvailable)
    }
    .padding()
}
