//
//  ContentView.swift
//  SpatialVideoGist
//
//  Created by Bryan on 12/15/23.
//

import SwiftUI
import UniformTypeIdentifiers

/// Main view
struct ContentView: View {
    // MARK: - Properties
    
    // MARK: Public
    
    /// The injected video converter, conforming to a `SpatialVideoConverter` and `Observable`.
    @Environment(SpatialVideoConverter.self) var videoConverter
    
    // MARK: Private
    
    /// A flag if the file import selection dialog should be shown to the user.
    @State private var showImportDestinationSelector = false
    
    /// A flag if the file export selection dialog should be shown to the user.
    @State private var showOutputDestinationSelector = false
    
    /// The path to the selected source file.
    @State private var selectedSourceFile: URL = URL(fileURLWithPath: "/")
    
    /// The path to the destination where the file should be output.
    @State private var selectedOutputDestination: URL?
    
    /// Main View
    var body: some View {
        GeometryReader { geometry in
            HStack {
                Spacer()
                
                VStack {
                    if !videoConverter.isProcessing {
                        Image(systemName: "visionpro.badge.play")
                            .font(.system(size: 100.0))
                            .foregroundStyle(.gray)
                        Text("Choose a video, and a destination, to convert a stereoscopic video to a Spatial Video.")
                    } else {
                        // TODO: Support a video preview of file being converted
                        EmptyView()
                    }
                    
                    
                    Spacer()
                    
                    if !videoConverter.isProcessing {
                        Button(action: {
                            showImportDestinationSelector.toggle()
                        }) {
                            Text("Choose Source Video")
                        }
                        
                        Spacer()
                        
                        Button(action: {
                            showOutputDestinationSelector.toggle()
                        }) {
                            Text("Choose Destination")
                        }
                        .disabled(selectedSourceFile.isEmpty)
                        
                        Spacer()
                        
                    } else {
                        
                        ProgressView(value: videoConverter.framesProcessed, total: videoConverter.totalFrames)
                            .padding(.bottom)
                        Text("Time Remaining: ") + Text(Date.now.addingTimeInterval(videoConverter.timeRemaining), style: .relative)
                    }
                    
                    Button(action: {
                        guard !selectedSourceFile.isEmpty,
                              let outputDestination = selectedOutputDestination
                        else {
                            return
                        }
                        
                        guard !videoConverter.isProcessing else {
                            videoConverter.cancel(expectedOutputURL: outputDestination)
                            selectedSourceFile.stopAccessingSecurityScopedResource()
                            outputDestination.stopAccessingSecurityScopedResource()
                            reset()
                            return
                        }
                        
                        Task {
                            try? await videoConverter.convertStereoscopicVideoToSpatialVideo(
                                sourceVideoURL: selectedSourceFile,
                                outputVideoURL: outputDestination
                            )
                        }
                    }) {
                        Text(videoConverter.isProcessing ? "Cancel": "Convert")
                    }
                    .disabled(selectedSourceFile.isEmpty || selectedOutputDestination == nil)
                    
                    Spacer()
                }
                
                Spacer()
                
                if let lastCompletedFile = videoConverter.lastConvertedFileURL {
                    VStack {
                        Spacer()
                        Text("Last Completed File")
                            .fontWeight(.bold)
                            .underline()
                            .padding()
                        
                        Text("File Name: ").font(.caption) + Text(lastCompletedFile.filePath.lastPathComponent).font(.caption)
                        Text("File Size: ").font(.caption) + Text(lastCompletedFile.fileSize).font(.caption).font(.caption)
                        Text("Video Duration: ").font(.caption) + Text(lastCompletedFile.duration).font(.caption).font(.caption)
                        Text("Time To Process: ").font(.caption) + Text(lastCompletedFile.timeToProcess).font(.caption).font(.caption)
                        HStack {
                            Spacer()
                            Button(action: {
                                NSWorkspace.shared.selectFile(
                                    lastCompletedFile.filePath.path,
                                    inFileViewerRootedAtPath: lastCompletedFile.filePath.path
                                )
                            }) {
                                Text("Open File")
                            }
                            Spacer()
                        }
                    }
                }

            }
        }
        .padding()
        .fileImporter(
            isPresented: $showImportDestinationSelector,
            allowedContentTypes: [.video, .quickTimeMovie, .mpeg4Movie, .movie],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let selectedFiles):
                if let firstFile = selectedFiles.first {
                    selectedSourceFile = firstFile
                }
            case .failure:
                break
            }
        }
        .fileDialogMessage("Choose source stereoscopic video file.")
        .fileDialogConfirmationLabel(Text("Select"))
        .fileExporter(
            isPresented: $showOutputDestinationSelector,
            document: VideoFile(),
            contentType: .quickTimeMovie,
            defaultFilename: selectedSourceFile.modifiedFileName
        ) { result in
            switch result {
            case .success(let success):
                selectedOutputDestination = success
            case .failure:
                break
            }
        }
        .fileExporterFilenameLabel("Destination for Spatial Video")
        .onChange(of: videoConverter.lastConvertedFileURL) { oldValue, newValue in
            if newValue != nil {
                reset()
            }
        }
    }
    
    /// Resets the source and destination URLs after a cancellation of a video convert or completion.
    private func reset() {
        selectedSourceFile = URL.empty
        selectedOutputDestination = nil
    }
}

/// Convenience extensions for `URL`.
fileprivate extension URL {
    var modifiedURL: URL {
        return self.deletingLastPathComponent().appending(path: suggestedSpatialVideoFileName())
    }
    
    var modifiedFileName: String {
        suggestedSpatialVideoFileName()
    }
    
    private func suggestedSpatialVideoFileName() -> String {
        let originalFileName = self.deletingPathExtension().lastPathComponent
        return originalFileName + "-SpatialVideo.mov"
    }
    
    var isEmpty: Bool {
        self == URL(fileURLWithPath: "/")
    }
    
    static var empty: URL {
        URL(fileURLWithPath: "/")
    }
}

/// Convenience extensions for `Double`.
extension Double {
    /// Rounds the double to decimal places value
    func rounded(toPlaces places:Int) -> Double {
        let divisor = pow(10.0, Double(places))
        return (self * divisor).rounded() / divisor
    }
}

#Preview {
    ContentView()
        .environment(SpatialVideoConverter())
}
