import SwiftUI

/// A progress overlay that shows status text and a progress bar.
/// Used during install, update, and other long-running operations.
struct ProgressOverlayView: View {
    let statusText: String
    let progress: Double
    let isBusy: Bool

    private var isIndeterminate: Bool {
        progress <= 0 && isBusy
    }

    var body: some View {
        VStack(spacing: 12) {
            if isBusy {
                if isIndeterminate {
                    ProgressView()
                        .scaleEffect(0.8)
                } else {
                    ProgressView(value: progress, total: 1.0)
                        .progressViewStyle(.linear)
                        .frame(maxWidth: 300)
                }

                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 16)
    }
}

/// Compact progress bar for inline use.
struct CompactProgressBar: View {
    let progress: Double
    let isIndeterminate: Bool

    var body: some View {
        if isIndeterminate {
            ProgressView()
                .scaleEffect(0.7)
                .frame(height: 8)
        } else {
            ProgressView(value: progress, total: 1.0)
                .progressViewStyle(.linear)
                .frame(height: 8)
        }
    }
}

#Preview {
    VStack(spacing: 20) {
        ProgressOverlayView(statusText: "Downloading...", progress: 0.45, isBusy: true)
        ProgressOverlayView(statusText: "Ready", progress: 1.0, isBusy: false)
        ProgressOverlayView(statusText: "Processing...", progress: 0, isBusy: true)
    }
    .padding()
    .frame(width: 400)
}
