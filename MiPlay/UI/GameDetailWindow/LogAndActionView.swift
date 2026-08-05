//
//  LogAndActionView.swift
//  MiPlay
//
//  Created by Steve Tan on 2026/7/7.
//

import SwiftUI

// Source: UI Design → 组件树 → LogAndActionView
// Source: UI Design → View Responsibility → LogAndActionView

/// 日志与操作区视图。
struct LogAndActionView: View {
    let detailViewModel: GameDetailViewModel
    let onRemoveGame: ((String) -> Void)?

    init(detailViewModel: GameDetailViewModel, onRemoveGame: ((String) -> Void)? = nil) {
        self.detailViewModel = detailViewModel
        self.onRemoveGame = onRemoveGame
    }

    @State private var showRemoveConfirm = false

    var body: some View {
        HStack {
            // 导出日志
            Button(action: {
                Task { await detailViewModel.exportLogs() }
            }) {
                Label("导出日志", systemImage: "doc.text")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)

            Spacer()

            // 从 MiPlay 移除
            Button(role: .destructive) {
                showRemoveConfirm = true
            } label: {
                Label("从 MiPlay 移除", systemImage: "trash")
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .tint(.red)
        }
        .alert("确认移除", isPresented: $showRemoveConfirm) {
            Button("取消", role: .cancel) {}
            Button("移除", role: .destructive) {
                if let gameId = detailViewModel.game?.id {
                    onRemoveGame?(gameId)
                }
            }
        } message: {
            Text("将从 MiPlay 管理范围中移除「\(detailViewModel.game?.type.displayName ?? "")」，游戏文件不会被删除。")
        }
    }
}
