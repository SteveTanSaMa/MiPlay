//
//  SystemEnvironmentDetector.swift
//  MiPlay
//
//  Created by Steve Tan on 2026/7/7.
//

import Foundation

// Source: Architecture Design → Service Contract → SystemEnvironmentDetector

/// 系统环境检测器。检测和报告当前 macOS 系统的基本环境信息。
/// 
/// 所有方法均为 nonisolated 以便在 Actor 上下文中调用（无可变状态）。
public struct SystemEnvironmentDetector: Sendable {
    public enum DetectionError: Error, LocalizedError {
        case pathNotReachable(String)
        case detectionFailed(String)

        public var errorDescription: String? {
            switch self {
            case .pathNotReachable(let path):
                return "路径不可达: \(path)"
            case .detectionFailed(let detail):
                return "系统检测失败: \(detail)"
            }
        }
    }

    /// 系统环境信息
    public struct SystemInfo: Sendable {
        public let osVersion: String
        public let buildNumber: String
        public let isAppleSilicon: Bool
        public let chipModel: String
        public let physicalMemory: UInt64
        public let processorCount: Int
    }

    private let diskSpaceProvider: @Sendable (String) throws -> (free: UInt64, total: UInt64)

    /// The default provider reads the real volume. The injectable provider is a
    /// narrow test seam for launch checks, whose result must still satisfy the
    /// same production validation contract.
    public init(
        diskSpaceProvider: (@Sendable (String) throws -> (free: UInt64, total: UInt64))? = nil
    ) {
        self.diskSpaceProvider = diskSpaceProvider ?? { path in
            try Self.readDiskSpace(at: path)
        }
    }

    // MARK: - System Info

    /// 获取系统版本
    public nonisolated func getOSVersion() -> String {
        let processInfo = ProcessInfo.processInfo
        let version = processInfo.operatingSystemVersion
        return "\(version.majorVersion).\(version.minorVersion).\(version.patchVersion)"
    }

    /// 获取系统构建号
    public nonisolated func getBuildNumber() -> String {
        let size = UnsafeMutablePointer<Int>.allocate(capacity: 1)
        defer { size.deallocate() }

        size.pointee = 0
        sysctlbyname("kern.osversion", nil, size, nil, 0)
        let cString = UnsafeMutablePointer<CChar>.allocate(capacity: size.pointee)
        defer { cString.deallocate() }
        sysctlbyname("kern.osversion", cString, size, nil, 0)
        return String(cString: cString)
    }

    /// 检测是否为 Apple Silicon
    public nonisolated func isAppleSilicon() -> Bool {
        var result = 0
        var size = MemoryLayout.size(ofValue: result)
        sysctlbyname("hw.optional.arm64", &result, &size, nil, 0)
        return result != 0
    }

    /// 获取芯片型号
    public nonisolated func getChipModel() -> String {
        let size = UnsafeMutablePointer<Int>.allocate(capacity: 1)
        defer { size.deallocate() }

        size.pointee = 0
        sysctlbyname("machdep.cpu.brand_string", nil, size, nil, 0)
        let cString = UnsafeMutablePointer<CChar>.allocate(capacity: size.pointee)
        defer { cString.deallocate() }
        sysctlbyname("machdep.cpu.brand_string", cString, size, nil, 0)
        let brand = String(cString: cString)

        if isAppleSilicon() {
            // For Apple Silicon, get the chip model from sysctl
            size.pointee = 0
            sysctlbyname("hw.model", nil, size, nil, 0)
            let modelCString = UnsafeMutablePointer<CChar>.allocate(capacity: size.pointee)
            defer { modelCString.deallocate() }
            sysctlbyname("hw.model", modelCString, size, nil, 0)
            return String(cString: modelCString)
        }

        return brand.trimmingCharacters(in: .whitespaces)
    }

    /// 获取物理内存大小（字节）
    public nonisolated func getPhysicalMemory() -> UInt64 {
        return ProcessInfo.processInfo.physicalMemory
    }

    /// 获取处理器核心数
    public nonisolated func getProcessorCount() -> Int {
        return ProcessInfo.processInfo.processorCount
    }

    /// 获取完整系统信息
    public nonisolated func getSystemInfo() -> SystemInfo {
        SystemInfo(
            osVersion: getOSVersion(),
            buildNumber: getBuildNumber(),
            isAppleSilicon: isAppleSilicon(),
            chipModel: getChipModel(),
            physicalMemory: getPhysicalMemory(),
            processorCount: getProcessorCount()
        )
    }

    // MARK: - Disk Space

    /// 获取指定路径所在卷的磁盘空间信息
    // Path-based disk checks are an internal seam; callers must resolve the
    // path from an authorized URL before reaching this infrastructure layer.
    internal nonisolated func getDiskSpace(at path: String) throws -> (free: UInt64, total: UInt64) {
        try diskSpaceProvider(path)
    }

    private nonisolated static func readDiskSpace(at path: String) throws -> (free: UInt64, total: UInt64) {
        let fileManager = FileManager.default
        let url = URL(fileURLWithPath: path)

        guard url.startAccessingSecurityScopedResource() else {
            throw DetectionError.pathNotReachable(path)
        }
        defer { url.stopAccessingSecurityScopedResource() }

        do {
            let values = try url.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey, .volumeTotalCapacityKey])
            let free = values.volumeAvailableCapacityForImportantUsage ?? 0
            let total = values.volumeTotalCapacity ?? 0
            return (UInt64(free), UInt64(total))
        } catch {
            // Fallback to simpler API
            do {
                let attrs = try fileManager.attributesOfFileSystem(forPath: path)
                let free = (attrs[.systemFreeSize] as? NSNumber)?.uint64Value ?? 0
                let total = (attrs[.systemSize] as? NSNumber)?.uint64Value ?? 0
                return (free, total)
            } catch {
                throw DetectionError.detectionFailed("磁盘空间检测失败: \(error.localizedDescription)")
            }
        }
    }

    /// 检查磁盘空间是否充足（剩余空间 > 需要的空间 * 安全系数 1.5）
    internal nonisolated func hasSufficientDiskSpace(at path: String, neededBytes: UInt64) throws -> Bool {
        let (free, _) = try getDiskSpace(at: path)
        return free >= neededBytes * 2 // 2x safety margin
    }

    // MARK: - macOS Version Check

    /// 检查 macOS 版本是否满足最低要求
    public nonisolated func meetsMinimumOSVersion(major: Int, minor: Int = 0, patch: Int = 0) -> Bool {
        let version = ProcessInfo.processInfo.operatingSystemVersion
        if version.majorVersion > major { return true }
        if version.majorVersion < major { return false }
        if version.minorVersion > minor { return true }
        if version.minorVersion < minor { return false }
        return version.patchVersion >= patch
    }

    /// 检查是否满足 macOS 26+ 要求
    public nonisolated func meetsMinimumRequirement() -> Bool {
        return meetsMinimumOSVersion(major: 26)
    }
}
