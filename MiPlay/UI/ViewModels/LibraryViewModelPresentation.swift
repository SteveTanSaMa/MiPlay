//
//  LibraryViewModelPresentation.swift
//  MiPlay
//

import Foundation

// Source: Architecture Design -> ViewModel Layer -> LibraryViewModel
// Presentation-only derived state for the main window.
extension LibraryViewModel {
    /// 是否显示媒体加载遮罩（初始化中或素材加载中）
    /// Source: 用户反馈 — 遮罩层不可见：initialize() 中 loading 状态持续过短
    var shouldShowMediaLoadingOverlay: Bool {
        if isLoading { return true }
        if case .loading = backgroundMediaState { return true }
        return false
    }
}
