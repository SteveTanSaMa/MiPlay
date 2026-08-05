//
//  CompatibilitySolutionView.swift
//  MiPlay
//
//  Created by Steve Tan on 2026/7/7.
//

import SwiftUI

// Source: UI Design → 组件树 → CompatibilitySolutionView
// Source: UI Design → View Responsibility → CompatibilitySolutionView
// Source: UI Design → 游戏详情窗口状态映射

/// 兼容方案区视图。
struct CompatibilitySolutionView: View {
    let detailViewModel: GameDetailViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("兼容方案 (\(detailViewModel.availableSolutions.count))")
                .font(.headline)

            if detailViewModel.availableSolutions.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.shield")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)

                    Text("当前没有可用的兼容方案")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
            } else {
                ForEach(detailViewModel.availableSolutions) { solution in
                    SolutionCardView(
                        solution: solution,
                        detailViewModel: detailViewModel
                    )
                }
            }
        }
    }
}

/// 兼容方案卡片视图
struct SolutionCardView: View {
    let solution: CompatibilitySolution
    let detailViewModel: GameDetailViewModel

    @State private var showConfirmAlert = false
    @State private var showRollbackAlert = false

    /// 方案的应用状态
    private var applicationState: SolutionApplicationState? {
        detailViewModel.solutionHistory
            .filter { $0.solutionId == solution.id }
            .sorted(by: { $0.appliedDate > $1.appliedDate })
            .first?.state
    }

    private var isApplied: Bool {
        applicationState == .applied
    }

    private var isApplying: Bool {
        applicationState == .applying
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // 方案头部
            HStack {
                Text(solution.name)
                    .font(.body)
                    .fontWeight(.semibold)

                Spacer()

                // 风险等级徽章
                riskBadge(level: solution.riskLevel)
            }

            // 方案描述
            Text(solution.description)
                .font(.caption)
                .foregroundStyle(.secondary)

            // 详细说明（点击展开）
            Text(solution.details)
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(2)

            // 方案进行中进度
            if let progress = detailViewModel.solutionProgress, isApplying {
                HStack(spacing: 8) {
                    if let value = progress.progress {
                        ProgressView(value: value)
                            .frame(width: 90)
                    } else {
                        ProgressView()
                            .controlSize(.small)
                    }
                    Text(progress.phase)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(.vertical, 4)
                .accessibilityElement(children: .combine)
                .accessibilityLabel("\(solution.name)兼容方案任务：\(progress.phase)")
                .accessibilityValue(progress.progress.map { "\(Int($0 * 100))%" } ?? "进行中")
            }

            // 操作按钮
            HStack {
                if isApplied {
                    // 已应用状态标签
                    Label("已应用", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)

                    Spacer()

                    Button("回滚") {
                        showRollbackAlert = true
                    }
                    .buttonStyle(.bordered)
                    .tint(.orange)
                    .controlSize(.small)
                } else if isApplying {
                    ProgressView()
                        .scaleEffect(0.8)
                    Text("应用中…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Spacer()

                    Button("应用") {
                        showConfirmAlert = true
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel(solution.name)
        .accessibilityValue(applicationState.map(solutionStateLabel) ?? "未应用")
        .padding(16)
        .background(
            // Source: macOS 26 规范 §7.9 — 圆角标准化
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.white.opacity(0.05))
        )
        .overlay(
            // Source: macOS 26 规范 §7.9 — 圆角标准化
            RoundedRectangle(cornerRadius: 6)
                .stroke(isApplied ? Color.green.opacity(0.3) : Color.clear, lineWidth: 1)
        )
        .alert("应用兼容方案", isPresented: $showConfirmAlert) {
            Button("取消", role: .cancel) {}
            Button("确认应用") {
                Task { await detailViewModel.applySolution(solutionId: solution.id) }
            }
        } message: {
            Text("\(solution.name)\n\n\(solution.details)\n\n风险等级: \(solution.riskLevel.displayName)")
        }
        .alert("回滚兼容方案", isPresented: $showRollbackAlert) {
            Button("取消", role: .cancel) {}
            Button("确认回滚", role: .destructive) {
                if let app = detailViewModel.solutionHistory
                    .filter({ $0.solutionId == solution.id })
                    .sorted(by: { $0.appliedDate > $1.appliedDate })
                    .first {
                    Task { await detailViewModel.rollbackSolution(applicationId: app.id) }
                }
            }
        } message: {
            Text("确认回滚「\(solution.name)」？回滚后系统将恢复到应用前的状态。")
        }
    }

    private func riskBadge(level: SolutionRiskLevel) -> some View {
        Text(level.displayName)
            .font(.caption2)
            .fontWeight(.medium)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(
                // Source: macOS 26 规范 §7.9 — 圆角标准化
                RoundedRectangle(cornerRadius: 6)
                    .fill(riskColor(level).opacity(0.15))
            )
            .foregroundStyle(riskColor(level))
    }

    private func riskColor(_ level: SolutionRiskLevel) -> Color {
        switch level {
        case .low: return .green
        case .medium: return .orange
        case .high: return .red
        }
    }

    private func solutionStateLabel(_ state: SolutionApplicationState) -> String {
        switch state {
        case .applying: return "应用中"
        case .applied: return "已应用并验证，游戏尚未启动"
        case .failed: return "应用失败"
        case .rolledBack: return "未应用，应用前状态已恢复并确认"
        }
    }
}
