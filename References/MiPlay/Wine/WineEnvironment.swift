//
//  WineEnvironment.swift
//  MiPlay
//
//  Created by Steve Tan on 2026/6/20.
//

import Foundation

struct WineEnvironment {
    var winePrefix: String
    var wineArch: String
    var winePath: String
    var dxmtEnabled: Bool = true
    var metalHUDEnabled: Bool = false
    var retinaModeEnabled: Bool = true
    var logLevel: String = "error"
    var shaderCacheEnabled: Bool = true
    var customVariables: [String: String] = [:]

    var environmentDict: [String: String] {
        var env: [String: String] = [:]

        env["WINEPREFIX"] = winePrefix
        env["WINEARCH"] = wineArch
        env["PATH"] = "\(winePath)/bin:/usr/bin:/bin"

        if dxmtEnabled {
            env["DXMT_LOG_LEVEL"] = logLevel
            if !shaderCacheEnabled {
                env["DXMT_SHADER_CACHE"] = "0"
            }
        }

        if metalHUDEnabled {
            env["MTL_HUD_ENABLED"] = "1"
        }

        if !retinaModeEnabled {
            env["WINEDLLOVERRIDES"] = (env["WINEDLLOVERRIDES"] ?? "") + ";dxgi=d"
        }

        for (key, value) in customVariables {
            env[key] = value
        }

        return env
    }

    static func forLaunch(
        winePath: String,
        prefix: String,
        arch: String = "win64",
        config: DXMTConfiguration? = nil
    ) -> WineEnvironment {
        WineEnvironment(
            winePrefix: prefix,
            wineArch: arch,
            winePath: winePath,
            dxmtEnabled: config != nil,
            metalHUDEnabled: config?.enableMetalHUD ?? false,
            retinaModeEnabled: config?.enableRetinaMode ?? true
        )
    }
}
