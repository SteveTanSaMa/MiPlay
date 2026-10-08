//
//  SystemEnvironmentDetector.swift
//  MiPlay
//
//  Created by Steve Tan on 2026/7/7.
//

import Foundation
import IOKit

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
        public let machineName: String
        public let chipName: String
        public let modelIdentifier: String
        public let physicalMemory: UInt64
        public let physicalMemoryText: String
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

    /// 获取芯片名称。芯片名称来自 brand_string，不使用硬件机型标识。
    public nonisolated func getChipName() -> String {
        readSysctlString("machdep.cpu.brand_string")
    }

    /// 获取硬件机型标识，例如 "MacBookPro17,1"。
    public nonisolated func getModelIdentifier() -> String {
        readSysctlString("hw.model")
    }

    /// System-provided machine marketing name, for example "MacBook Pro".
    /// Returns an empty string when the system does not expose one; it is never
    /// synthesized from the model identifier.
    public nonisolated func getMachineName() -> String {
        guard let productName = readPlatformProperty("product-name"), !productName.isEmpty else {
            return ""
        }
        let family = productName.split(separator: "(", maxSplits: 1).first.map {
            String($0).trimmingCharacters(in: .whitespaces)
        } ?? ""
        return family
    }

    public nonisolated func getPhysicalMemoryText() -> String {
        ByteCountFormatter.string(
            fromByteCount: Int64(getPhysicalMemory()),
            countStyle: .memory
        )
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
            machineName: getMachineName(),
            chipName: getChipName(),
            modelIdentifier: getModelIdentifier(),
            physicalMemory: getPhysicalMemory(),
            physicalMemoryText: getPhysicalMemoryText(),
            processorCount: getProcessorCount()
        )
    }

    private nonisolated func readPlatformProperty(_ key: String) -> String? {
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault,
            IOServiceMatching("IOPlatformExpertDevice")
        )
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }

        guard let value = IORegistryEntrySearchCFProperty(
            service,
            kIOServicePlane,
            key as CFString,
            kCFAllocatorDefault,
            IOOptionBits(kIORegistryIterateRecursively)
        ) else { return nil }
        if let data = value as? Data {
            return String(data: data, encoding: .utf8)?
                .trimmingCharacters(in: CharacterSet(charactersIn: "\0"))
        }
        return value as? String
    }

    private nonisolated func readSysctlString(_ name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 1 else { return "" }

        let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: size)
        defer { buffer.deallocate() }
        guard sysctlbyname(name, buffer, &size, nil, 0) == 0 else { return "" }
        return String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
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
