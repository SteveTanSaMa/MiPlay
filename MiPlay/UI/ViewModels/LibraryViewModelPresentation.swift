//
//  LibraryViewModelPresentation.swift
//  MiPlay
//

import Foundation

// Source: Architecture Design -> ViewModel Layer -> LibraryViewModel
// Presentation-only derived state for the main window.
extension LibraryViewModel {
    /// 是否显示启动准备全屏遮罩。
    ///
    /// 由 `startupPhase` 决定（而不是某一刻的媒体状态快照）：`startupPhase` 的初值
    /// 就是 `.preparingWine`，所以遮罩从第一帧起就覆盖主页——修复此前"冷启动只见
    /// 黑底按钮、切换游戏后遮罩才出现"的问题（旧条件依赖 `backgroundMediaState`，
    /// 而该状态只在选中/任务事件时才刷新）。
    var isStartupPreparationVisible: Bool {
        if startupPhase != .ready { return true }
        return isLoading
    }
}
