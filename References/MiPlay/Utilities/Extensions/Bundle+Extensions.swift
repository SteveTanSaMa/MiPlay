//
//  Bundle+Extensions.swift
//  MiPlay
//
//  Created by Steve Tan on 2026/6/20.
//

import Foundation

extension Bundle {
    var appVersion: String {
        infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    var buildNumber: String {
        infoDictionary?["CFBundleVersion"] as? String ?? "0"
    }

    var appName: String {
        infoDictionary?["CFBundleName"] as? String ?? "MiPlay"
    }

    var fullVersionString: String {
        "v\(appVersion) (build \(buildNumber))"
    }
}
