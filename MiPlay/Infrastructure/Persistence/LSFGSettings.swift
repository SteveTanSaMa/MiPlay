import Foundation

/// A per-game request, applied at the next launch. It is not evidence that
/// the runtime has generated or displayed frames in the current session.
nonisolated public struct LSFGSettings: Codable, Sendable, Equatable {
    public var enabled: Bool
    public var multiplier: Int
    public var flowScale: Double
    public var performanceMode: Bool
    /// Explicit display refresh rate for pacing; nil uses automatic detection.
    public var targetFPS: Int?

    public init(enabled: Bool = false, multiplier: Int = 2, flowScale: Double = 1,
                performanceMode: Bool = false, targetFPS: Int? = nil) {
        self.enabled = enabled
        self.multiplier = multiplier
        self.flowScale = flowScale
        self.performanceMode = performanceMode
        self.targetFPS = targetFPS
    }

    private enum CodingKeys: String, CodingKey {
        case enabled, multiplier, flowScale, performanceMode, targetFPS
    }

    public init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        multiplier = try values.decodeIfPresent(Int.self, forKey: .multiplier) ?? 2
        flowScale = try values.decodeIfPresent(Double.self, forKey: .flowScale) ?? 1
        performanceMode = try values.decodeIfPresent(Bool.self, forKey: .performanceMode) ?? false
        targetFPS = try values.decodeIfPresent(Int.self, forKey: .targetFPS)
    }

    @discardableResult
    public func validated() throws -> Self {
        guard (2...4).contains(multiplier) else { throw ValidationError.multiplier }
        guard flowScale.isFinite, (0.25...1).contains(flowScale) else { throw ValidationError.flowScale }
        guard targetFPS.map({ (1...1000).contains($0) }) ?? true else { throw ValidationError.targetFPS }
        return self
    }

    public enum ValidationError: Error, LocalizedError, Sendable {
        case multiplier, flowScale, targetFPS

        public var errorDescription: String? {
            switch self {
            case .multiplier: return "LSFG 插帧倍率应为 2、3 或 4。"
            case .flowScale: return "LSFG 光流分辨率应在 25% 至 100% 之间。"
            case .targetFPS: return "LSFG 目标帧率应在 1 至 1000 FPS 之间。"
            }
        }
    }
}
