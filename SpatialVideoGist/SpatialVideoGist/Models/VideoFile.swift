//
//  VideoFile.swift
//  SpatialVideoGist
//
//  Created by Bryan on 12/15/23.
//

import SwiftUI
import UniformTypeIdentifiers

/// An empty implementation of a `FileDocument` that allows SwiftUI's `fileExporter` to validate that we can write to the output destination.
struct VideoFile: FileDocument {
    static var readableContentTypes: [UTType] = [.movie, .quickTimeMovie, .mpeg4Movie]
    
    // empty data
    var data: Data
    
    init() {
        self.data = Data()
    }
    
    init(configuration: ReadConfiguration) throws {
        if let readData = configuration.file.regularFileContents {
            data = readData
        } else {
            data = Data()
        }
    }
    
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        FileWrapper(regularFileWithContents: data)
    }
}
