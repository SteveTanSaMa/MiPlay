//
//  PerformanceOptionView.swift
//  MiPlay
//
//  Created by Steve Tan on 2026/7/7.
//

import SwiftUI

// Source: UI Design → 组件树 → PerformanceOptionView
// Source: UI Design → View Responsibility → PerformanceOptionView

/// 性能选项区视图。
struct PerformanceOptionView: View {
    let detailViewModel: GameDetailViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("性能选项")
                .font(.headline)

            if detailViewModel.performanceOptions.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "clock.badge.exclamationmark")
                        .font(.largeTitle)
                        .foregroundStyle(.secondary)

                    Text("高级性能配置当前为 Deferred，尚不可用")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 40)
            } else {
                ForEach(detailViewModel.performanceOptions) { option in
                    OptionItemView(
                        option: option,
                        detailViewModel: detailViewModel
                    )
                }
            }
        }
    }
}

/// 单个性能选项视图
struct OptionItemView: View {
    let option: PerformanceOption
    let detailViewModel: GameDetailViewModel

    var body: some View {
        VStack(spacing: 0) {
            if option.type == .gameResolution {
                // 分辨率选择器
                resolutionOptionView
            } else {
                // 开关型选项
                toggleOptionView
            }
        }
    }

    /// 开关型选项
    private var toggleOptionView: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(option.displayName)
                    .font(.body)
                    .fontWeight(.medium)

                Text(option.optionDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Toggle("", isOn: Binding(
                get: { option.isEnabled },
                set: { newValue in
                    Task { await detailViewModel.toggleOption(optionId: option.id, enabled: newValue) }
                }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)
        }
        .padding(12)
        .background(
            // Source: macOS 26 规范 §7.9 — 圆角标准化
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.white.opacity(0.05))
        )
    }

    /// 分辨率选择器
    private var resolutionOptionView: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                Text(option.displayName)
                    .font(.body)
                    .fontWeight(.medium)

                Text(option.optionDescription)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Picker("", selection: Binding(
                get: { option.value ?? "1920x1080" },
                set: { newValue in
                    Task { await detailViewModel.setOptionValue(optionId: option.id, value: newValue) }
                }
            )) {
                Text("1920 × 1080").tag("1920x1080")
                Text("2560 × 1440").tag("2560x1440")
                Text("3440 × 1440").tag("3440x1440")
                Text("3840 × 2160").tag("3840x2160")
            }
            .pickerStyle(.menu)
            .controlSize(.small)
        }
        .padding(12)
        .background(
            // Source: macOS 26 规范 §7.9 — 圆角标准化
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.white.opacity(0.05))
        )
    }
}
