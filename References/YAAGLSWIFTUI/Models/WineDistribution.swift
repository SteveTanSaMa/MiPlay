import Foundation

/// A Wine distribution (version) available for download.
struct WineDistribution: Identifiable, Equatable, Codable {
    let id: String
    let displayName: String
    let remoteURL: URL
    let winePath: String
    let renderBackend: RenderBackend

    enum RenderBackend: String, Codable, Equatable {
        case dxmt
    }
}

// MARK: - Built-in Wine Distributions

extension WineDistribution {
    static let builtinDistributions: [WineDistribution] = [
        WineDistribution(
            id: "11.0-1-crossover-signed-experimental",
            displayName: "Wine 11.0-1 Crossover (signed, experimental)",
            remoteURL: URL(string: "https://github.com/yaagl/anime-game-wine/releases/download/wine-crossover-11.0-1-signed/wine-crossover-11.0-1-osx64-signed.tar.xz")!,
            winePath: "wine",
            renderBackend: .dxmt
        ),
        WineDistribution(
            id: "11.0-dxmt-signed-with-patches",
            displayName: "Wine 11.0 DXMT (signed, with patches)",
            remoteURL: URL(string: "https://github.com/yaagl/anime-game-wine/releases/download/wine-11.0-signed/wine-devel-11.0-osx64-signed.tar.xz")!,
            winePath: "wine",
            renderBackend: .dxmt
        ),
        WineDistribution(
            id: "11.8-dxmt-signed-experimental",
            displayName: "Wine 11.8 DXMT (signed, experimental)",
            remoteURL: URL(string: "https://github.com/yaagl/anime-game-wine/releases/download/wine-11.8-signed/wine-devel-11.8-osx64-signed.tar.xz")!,
            winePath: "wine",
            renderBackend: .dxmt
        ),
        WineDistribution(
            id: "11.4-dxmt-signed",
            displayName: "Wine 11.4 DXMT (signed)",
            remoteURL: URL(string: "https://github.com/dawn-winery/dawn-signed/releases/download/wine-gcenx-11.4-osx64/wine-devel-11.4-osx64-signed.tar.xz")!,
            winePath: "wine-devel-11.4-osx64-signed/Contents/Resources/wine",
            renderBackend: .dxmt
        ),
        WineDistribution(
            id: "11.0-dxmt-signed",
            displayName: "Wine 11.0 DXMT (signed)",
            remoteURL: URL(string: "https://github.com/dawn-winery/dawn-signed/releases/download/wine-stable-gcenx-11.0-osx64/wine-stable-11.0-osx64-signed.tar.xz")!,
            winePath: "Wine Stable.app/Contents/Resources/wine",
            renderBackend: .dxmt
        ),
        WineDistribution(
            id: "9.9-dxmt",
            displayName: "Wine 9.9 DXMT",
            remoteURL: URL(string: "https://github.com/3Shain/wine/releases/download/v9.9-mingw/wine.tar.gz")!,
            winePath: "",
            renderBackend: .dxmt
        ),
    ]

    static let `default` = builtinDistributions.first { $0.id == "11.0-dxmt-signed-with-patches" } ?? builtinDistributions[0]

    static func find(byID id: String) -> WineDistribution {
        builtinDistributions.first { $0.id == id } ?? `default`
    }
}

/// Wine environment status.
enum WineStatus: Equatable {
    case notInstalled
    case installed(distribution: WineDistribution)
    case needsUpdate(current: WineDistribution, target: WineDistribution)
}
