//
//  MiPlayApp.swift
//  MiPlay
//
//  Created by Steve Tan on 2026/6/20.
//

import SwiftUI

@main
struct MiPlayApp: App {
    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(width: 1270, height: 682)
        }
        .windowResizability(.contentSize)
        .windowStyle(.hiddenTitleBar)
    }
}
