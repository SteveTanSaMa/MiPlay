import Foundation

/// Paths used to detect installed voice packages. Each supported game must
/// explicitly provide its own markers; a new game cannot inherit another
/// title's layout merely because it uses Sophon.
nonisolated enum SophonGameProfile {
    static func audioResources(for game: GameType) -> [(String, String, String)] {
        switch game {
        case .genshinImpact:
            return [("zh-cn", "Chinese", "YuanShen_Data/StreamingAssets/AudioAssets/Chinese"),
                    ("en-us", "English(US)", "YuanShen_Data/StreamingAssets/AudioAssets/English(US)"),
                    ("ja-jp", "Japanese", "YuanShen_Data/StreamingAssets/AudioAssets/Japanese"),
                    ("ko-kr", "Korean", "YuanShen_Data/StreamingAssets/AudioAssets/Korean")]
        case .honkaiStarRail:
            return [("zh-cn", "Chinese", "StarRail_Data/Persistent/Audio/AudioPackage/Windows/Chinese(PRC)"),
                    ("en-us", "English(US)", "StarRail_Data/Persistent/Audio/AudioPackage/Windows/English"),
                    ("ja-jp", "Japanese", "StarRail_Data/Persistent/Audio/AudioPackage/Windows/Japanese"),
                    ("ko-kr", "Korean", "StarRail_Data/Persistent/Audio/AudioPackage/Windows/Korean")]
        case .zenlessZoneZero:
            return [("zh-cn", "Chinese", "ZenlessZoneZero_Data/StreamingAssets/Audio/Windows/Full/Cn"),
                    ("en-us", "English(US)", "ZenlessZoneZero_Data/StreamingAssets/Audio/Windows/Full/En"),
                    ("ja-jp", "Japanese", "ZenlessZoneZero_Data/StreamingAssets/Audio/Windows/Full/Jp"),
                    ("ko-kr", "Korean", "ZenlessZoneZero_Data/StreamingAssets/Audio/Windows/Full/Kr")]
        }
    }
}
