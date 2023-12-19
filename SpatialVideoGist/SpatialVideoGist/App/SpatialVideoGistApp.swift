//
//  SpatialVideoGistApp.swift
//  SpatialVideoGist
//
//  Created by Bryan on 12/15/23.
//

import SwiftUI

@main
struct SpatialVideoGistApp: App {
    
    @State private var videoConverter = SpatialVideoConverter()
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(videoConverter)
        }
    }
}
