//
//  DownloadTask.swift
//  MiPlay
//
//  Created by Steve Tan on 2026/6/20.
//

import Foundation

struct DownloadTask: Identifiable {
    let id: UUID
    let url: URL
    let destination: URL
    let description: String
    var progress: Double
    var status: DownloadStatus
    var speed: Double?
    var estimatedTimeRemaining: TimeInterval?

    init(url: URL, destination: URL, description: String) {
        self.id = UUID()
        self.url = url
        self.destination = destination
        self.description = description
        self.progress = 0
        self.status = .pending
    }
}

enum DownloadStatus: Equatable {
    case pending
    case downloading
    case paused
    case completed
    case failed(String)
    case cancelled

    static func == (lhs: DownloadStatus, rhs: DownloadStatus) -> Bool {
        switch (lhs, rhs) {
        case (.pending, .pending): return true
        case (.downloading, .downloading): return true
        case (.paused, .paused): return true
        case (.completed, .completed): return true
        case (.failed, .failed): return true
        case (.cancelled, .cancelled): return true
        default: return false
        }
    }
}
