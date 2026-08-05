//
//  LaunchViewModel.swift
//  MiPlay
//
//  Created by Steve Tan on 2026/6/20.
//

import SwiftUI

@MainActor
@Observable
final class LaunchViewModel {
    private let gameManager: GameManager
    private let wineManager: WineManager
    private let gameLauncher: GameLauncher

    var isGameRunning = false
    var launchStatus: LaunchStatus = .idle
    var gameProcessInfo: GameProcessInfo?
    var performanceMetrics: PerformanceMetrics?

    struct GameProcessInfo {
        let gameType: GameType
        let startTime: Date
        let pid: Int32
    }

    struct PerformanceMetrics {
        var fps: Double?
        var frameTime: Double?
        var gpuUtilization: Double?
    }

    enum LaunchStatus: Equatable {
        case idle
        case validating
        case launching
        case running
        case failed(String)
        case terminated

        static func == (lhs: LaunchStatus, rhs: LaunchStatus) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle): return true
            case (.validating, .validating): return true
            case (.launching, .launching): return true
            case (.running, .running): return true
            case (.terminated, .terminated): return true
            case (.failed, .failed): return true
            default: return false
            }
        }
    }

    init(gameManager: GameManager, wineManager: WineManager, gameLauncher: GameLauncher) {
        self.gameManager = gameManager
        self.wineManager = wineManager
        self.gameLauncher = gameLauncher
    }

    func monitorGameProcess() {
        Task {
            while isGameRunning {
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    func stopGame() {
        Task { await gameLauncher.terminateGame() }
        isGameRunning = false
        launchStatus = .terminated
    }
}
