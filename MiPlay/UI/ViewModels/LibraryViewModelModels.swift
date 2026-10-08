//
//  LibraryViewModelModels.swift
//  MiPlay
//

import Foundation

// Source: Architecture Design -> ViewModel Layer -> LibraryViewModel

extension LibraryViewModel {
    /// 启动进度
    public struct LaunchProgress: Sendable {
        public let phase: String
        public let progress: Double?
    }

    /// 主按钮操作类型
    public enum PrimaryAction: Sendable {
        case locate
        case launch
        case update
    }

    /// 主按钮状态
    public enum PrimaryButtonState: Sendable {
        case enabled(label: String, action: PrimaryAction)
        case disabled(String)

        public var label: String {
            switch self {
            case .enabled(let label, _): return label
            case .disabled(let label): return label
            }
        }

        public var isEnabled: Bool {
            if case .enabled = self { return true }
            return false
        }

        public var action: PrimaryAction? {
            if case .enabled(_, let action) = self { return action }
            return nil
        }
    }
}
