//
//  SpatialVideoConverter.swift
//  SpatialVideoGist
//
//  Created by Bryan on 12/15/23.
//

import AVFoundation
import CoreImage
import Foundation
import Observation
import VideoToolbox

/// A processor that converts a stereoscopic video to a Spatial Video.
@Observable final class SpatialVideoConverter {
    // MARK: - Properties
    
    // MARK: Public
    
    /// The total number of frames that need to be processed from the source video.
    var totalFrames: Double = .zero
    
    /// The number of frames that have been processed so far.
    var framesProcessed: Double = 0.0
    
    /// The time remaining until the convert completes.
    var timeRemaining: Double = .zero
    
    /// The timestamp in which processing began.
    var startTime: Date = .now
    
    /// A boolean flag determining if the processor is already in use.
    var isProcessing = false
    
    /// The last successfully converted file.
    var lastConvertedFileURL: LastConvertedFile?
    
    // MARK: Private
    
    /// A helper processor that can be used to crop and convert between underlying image types.
    private let processor = FrameProcessor()
    
    /// The video writer that writes video frames to a file.
    private var writer: AVAssetWriter?
    
    /// The queue in which to dispatch the `AVAssetWriter`'s video input on.
    private let videoInputQueue = DispatchQueue(label: "com.test.spatialWriterVideo")
    
    /// The queue in which to dispatch the `AVAssetWriter`'s audio input on.
    private let audioInputQueue = DispatchQueue(label: "com.test.spatialWriterAudio")
    
    /// The `AVAssetWriter`'s input for accepting video frames.
    private var writerVideoInput: AVAssetWriterInput?
    
    /// The `AVAssetWriter`'s input for accepting audio samples.
    private var writerAudioInput: AVAssetWriterInput?
    
    /// The reader that processes the source video.
    private var heroReader: AVAssetReader?
    
    /// The video track output of the `AVAssetReader`.
    private var readerVideoOutput: AVAssetReaderTrackOutput?
    
    /// The audio track output of the `AVAssetReader`.
    private var readerAudioOutput: AVAssetReaderTrackOutput?
    
    /// An internal flag indicating whether the video writer has finished processing all frames.
    private var videoWritingFinished = false
    
    /// An internal flag indicating whether the audio writer has finished processing all frames.
    private var audioWritingFinished = false
    
    /// A formatter that can be used for converting timestamps, such as processing time, to strings.
    private var dateFormatter: DateComponentsFormatter {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day, .hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        return formatter
    }
    
    // MARK: - Methods
    
    // MARK: Public
    
    /// Converts the source stereoscopic video into a Spatial Video.
    /// - Parameters:
    ///   - sourceVideoURL: The URL of the source stereoscopic video.  Must be a format supported by AVFoundation, such as a H.264, H.265, or ProRes file.
    ///   - outputVideoURL: The URL of the output video, if the convert completes successfully.
    func convertStereoscopicVideoToSpatialVideo(
        sourceVideoURL: URL,
        outputVideoURL: URL
    ) async throws {
        // Inform the system we need access to the source video file.
        guard sourceVideoURL.startAccessingSecurityScopedResource() else { return }
        guard outputVideoURL.startAccessingSecurityScopedResource() else { return }
        
        let heroAsset = AVAsset(url: sourceVideoURL)
        
        // Remove the temporary file, if it exists.
        try removeExistingFile(at: outputVideoURL)
        
        writer = try AVAssetWriter(outputURL: outputVideoURL, fileType: .mov)
        guard let videoTrack = try await heroAsset.loadTracks(withMediaType: .video).first else {
            return
        }
        let audioTrack = try await heroAsset.loadTracks(withMediaType: .audio).first
        
        guard let videoFormatDescription = try await videoTrack.load(.formatDescriptions).first else {
            return
        }
        
        if !processor.isPrepared {
            processor.prepare(with: videoFormatDescription, outputRetainedBufferCountHint: 1)
        }
        
        // Setup the source video size and calculate the region for the left and right eye images.
        let naturalSize = try await videoTrack.load(.naturalSize)
        let leftEyeRegion = CGRect(
            x: 0,
            y: 0,
            width: naturalSize.width / 2,
            height: naturalSize.height
        )
        let rightEyeRegion = CGRect(
            x: naturalSize.width / 2,
            y: 0,
            width: naturalSize.width / 2,
            height: naturalSize.height
        )

        // Configure the frame rate and number of frames to provide to the view for calculating time remaining.
        let frameRate = try await videoTrack.load(.nominalFrameRate)
        let duration = try await heroAsset.load(.duration)
        let frames = CMTimeGetSeconds(duration) * Double(frameRate)
        totalFrames = frames
        
        // Setup the video output settings
        var videoSettings = AVOutputSettingsAssistant(preset: .mvhevc1440x1440)?.videoSettings
        videoSettings?[AVVideoWidthKey] = leftEyeRegion.width
        videoSettings?[AVVideoHeightKey] = leftEyeRegion.height
        var compressionProperties = videoSettings?[AVVideoCompressionPropertiesKey] as! [String: Any]
        compressionProperties[kVTCompressionPropertyKey_HorizontalDisparityAdjustment as String] = 0
        compressionProperties[kCMFormatDescriptionExtension_HorizontalFieldOfView as String] = 90
        videoSettings?[AVVideoCompressionPropertiesKey] = compressionProperties
        
        // Setup the video input settings
        writerVideoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        guard let writerVideoInput else { return }
        writerVideoInput.expectsMediaDataInRealTime = false
        
        // Setup the audio input settings, if there is an audio track
        if audioTrack != nil {
            writerAudioInput = AVAssetWriterInput(mediaType: .audio, outputSettings: nil)
        }
        
        // Setup the pixel buffer group adaptor for writing left and right eye frames.
        let pixelBufferAdaptor = AVAssetWriterInputTaggedPixelBufferGroupAdaptor(
            assetWriterInput: writerVideoInput,
            sourcePixelBufferAttributes: .none)
        
        // Setup the reader for the stereoscopic video file, or a left eye (hero eye) view, if views were provided for each
        // individual eye.
        let readerOutputSettings: [String:Any] = [
            kCVPixelBufferPixelFormatTypeKey as String:  NSNumber(value: kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: naturalSize.width,
            kCVPixelBufferHeightKey as String: naturalSize.height
        ]
        readerVideoOutput = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: readerOutputSettings)
        if let audioTrack {
            readerAudioOutput = AVAssetReaderTrackOutput(track: audioTrack, outputSettings: nil)
        }
        heroReader = try AVAssetReader(asset: heroAsset)
        
        // Add the necessary outputs to the reader and start reading.
        guard let heroReader,
              let readerVideoOutput
        else { return }
        heroReader.add(readerVideoOutput)
        if let readerAudioOutput {
            heroReader.add(readerAudioOutput)
        }
        heroReader.startReading()
        
        // Add the necessary inputs to the writer and start the session.
        guard let writer else { return }
        writer.add(writerVideoInput)
        if let writerAudioInput {
            writer.add(writerAudioInput)
        }
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        // Flag that we have begun processing.
        isProcessing = true
        
        // Set the start time for processing, which allows downstream estimated time to
        // completion calculations.
        startTime = Date.now
        
        // Inform the writer's video input to request data when it's ready.
        writerVideoInput.requestMediaDataWhenReady(on: videoInputQueue) { [weak self] in
            guard let self else { return }
            while writerVideoInput.isReadyForMoreMediaData {
                autoreleasepool {
                    guard self.processor.isPrepared else {
                        print("The processor is not prepared.  Cannot write video")
                        return
                    }
                    
                    if let frame = readerVideoOutput.copyNextSampleBuffer(),
                       let frameBuffer = CMSampleBufferGetImageBuffer(frame) {
                            let sourceBuffer = CIImage(cvImageBuffer: frameBuffer)
                            
                            // Setup the left and right eye `CVPixelBuffer` references.
                            guard let leftEye = self.processor.cropPixelBuffer(
                                pixelBufferImage: sourceBuffer,
                                targetRect: leftEyeRegion
                            ),
                            let rightEye = self.processor.cropPixelBuffer(
                            pixelBufferImage: sourceBuffer,
                            targetRect: rightEyeRegion
                            )
                            else { return }
                            
                            // TODO: Add a video preview of what's being processed.

                            // Create an array of `CMTaggedBuffers, one for each eye's view.
                            let taggedBuffers: [CMTaggedBuffer] = [
                                .init(tags: [.videoLayerID(0), .stereoView(.leftEye)], pixelBuffer: leftEye),
                                .init(tags: [.videoLayerID(1), .stereoView(.rightEye)], pixelBuffer: rightEye)
                            ]
                            
                            let didAppend = pixelBufferAdaptor.appendTaggedBuffers(
                                taggedBuffers,
                                withPresentationTime: frame.presentationTimeStamp
                            )
                            if !didAppend {
                                print("Failed to append frame.")
                            }
                            
                            // Increment the number of frames processed.
                            if self.framesProcessed < (self.totalFrames - 1) {
                                self.framesProcessed += 1
                            }
                            
                            // Calculate the estimated time remaining based on how long this frame took to process.
                            self.calculateTimeRemaining()
                            
                        } else {
                            if !self.videoWritingFinished {
                                sourceVideoURL.stopAccessingSecurityScopedResource()
                                self.videoWritingFinished.toggle()
                                writerVideoInput.markAsFinished()
                                self.stop(with: outputVideoURL)
                            }
                        }
                }
            }
        }
        
        // Inform the writer's audio input to request data when it's ready.
        if let writerAudioInput,
           let readerAudioOutput {
            writerAudioInput.requestMediaDataWhenReady(on: audioInputQueue) { [weak self] in
                guard let self else { return }
                while writerAudioInput.isReadyForMoreMediaData {
                    autoreleasepool {
                        if let sample = readerAudioOutput.copyNextSampleBuffer() {
                            writerAudioInput.append(sample)
                        } else {
                            if !self.audioWritingFinished {
                                self.audioWritingFinished.toggle()
                                writerAudioInput.markAsFinished()
                                self.stop(with: outputVideoURL)
                            }
                        }
                    }
                }
            }
        }
    }
    
    
    /// Cancels the current video that is being converted and resets the writer to a state where it is ready to
    /// accept a new file for convert.
    /// - Parameter expectedOutputURL: The expected output `URL` of the file that is being cancelled, so the
    /// necessary temporary file can be removed and permissions reset.
    func cancel(expectedOutputURL: URL) {
        writerVideoInput?.markAsFinished()
        writerAudioInput?.markAsFinished()
        writer?.cancelWriting()
        try? removeExistingFile(at: expectedOutputURL)
        resetWriter()
    }
    
    // MARK: - Private
    
    /// Removes any file already existing at the output URL.
    /// - Parameter outputVideoURL: The provided output URL of the video.
    private func removeExistingFile(at outputVideoURL: URL) throws {
        try FileManager.default.removeItem(atPath: outputVideoURL.path)
    }
    
    /// Calculates the estimated time remaining for processing.
    private func calculateTimeRemaining() {
        let totalTimeElapsed = Date.now.timeIntervalSince1970 - startTime.timeIntervalSince1970
        let totalFramesCompleted = framesProcessed
        let averageTimeBetweenFrames = totalTimeElapsed / totalFramesCompleted
        let estimatedTimeRemaining = averageTimeBetweenFrames * (totalFrames - totalFramesCompleted)
        guard self.timeRemaining != 0 else {
            self.timeRemaining = estimatedTimeRemaining
            return
        }
        if estimatedTimeRemaining < self.timeRemaining + 100 {
            self.timeRemaining = estimatedTimeRemaining
        }
    }
    
    /// Ends the video writing session by marking the input as finished and completes writing.
    /// - Parameter outputURL: The output URL of the converted file.
    private func stop(with outputURL: URL) {
        guard isProcessing,
            let writerVideoInput,
            videoWritingFinished
        else { return }
        
        if let writerAudioInput {
            guard audioWritingFinished else { return }
        }
        
        self.writer?.finishWriting { [weak self] in
            guard let self else {return}
            Task {
                try? await self.saveLastConvertedFile(outputURL: outputURL)
                outputURL.stopAccessingSecurityScopedResource()
                self.resetWriter()
            }
            
            print("finished writing")
        }
    }
    
    /// Resets the reader, writer, and time calculations to their original state to prepare for the next
    /// file to convert.
    private func resetWriter() {
        isProcessing = false
        self.totalFrames = 0
        self.framesProcessed = 0
        self.timeRemaining = 0
        self.startTime = .now
        
        self.writerVideoInput = nil
        self.writerAudioInput = nil
        self.writer = nil
        self.readerVideoOutput = nil
        self.readerAudioOutput = nil
        self.heroReader = nil
        
        self.videoWritingFinished = false
        self.audioWritingFinished = false
    }
    
    /// Creates a reference to the last successfully completed file for processing, which can be used for
    /// showing a preview to the user for access to the last converted file.
    /// - Parameter outputURL: The output `URL` of the last converted file.
    private func saveLastConvertedFile(outputURL: URL) async throws {
        do {
            let attr = try FileManager.default.attributesOfItem(atPath: outputURL.path)
            var fileSize: Double = .zero
            
            if let size = attr[FileAttributeKey.size] as? NSNumber {
                fileSize = size.doubleValue / 1000000.0
            }
            
            let asset = AVAsset(url: outputURL)
            let duration = try await asset.load(.duration)
            
            self.lastConvertedFileURL = LastConvertedFile(
                filePath: outputURL,
                timeToProcess: dateFormatter.string(from: startTime, to: Date.now) ?? "Unknown",
                fileSize: "\(fileSize.rounded(toPlaces: 2))MB",
                duration: dateFormatter.string(from: duration.seconds) ?? "Unknown"
            )
        } catch {
            print("Error: \(error)")
        }
    }
}

/// A struct that provides basic metadata about the last converted video file.
struct LastConvertedFile: Codable, Equatable {
    /// The path of the last converted video file.
    let filePath: URL
    
    /// The amount of time it took to convert the last converted file, as a string.
    let timeToProcess: String
    
    /// The file size of the last converted file, as a string.
    let fileSize: String
    
    /// The video duration of the last converted file, as a string.
    let duration: String
}
