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
    
    /// The queue in which to dispatch the `AVAssetWriter` on.
    private let queue = DispatchQueue(label: "com.test.spatialwriter")
    
    /// The `AVAssetWriter`'s input for accepting video frames.
    var writerInput: AVAssetWriterInput?
    
    /// The reader that processes the source video.
    var heroReader: AVAssetReader?
    
    /// The track output of the `AVAssetReader`.
    var readerOutput: AVAssetReaderTrackOutput?
    
    /// A formatter that can be used for converting timestamps, such as processing time, to strings.
    private var dateFormatter: DateComponentsFormatter {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.day, .hour, .minute, .second]
        formatter.unitsStyle = .abbreviated
        return formatter
    }
    
    /// A formatter that can be used for converting byte counts, such as file sizes, to strings.
    private var byteCountFormatter: ByteCountFormatter {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useGB, .useMB, .useKB]
        formatter.countStyle = .file
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
        
        guard let formatDescription = try await videoTrack.load(.formatDescriptions).first else {
            return
        }
        
        if !processor.isPrepared {
            processor.prepare(with: formatDescription, outputRetainedBufferCountHint: 1)
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
        let dataRate = try await videoTrack.load(.estimatedDataRate)
        let duration = try await heroAsset.load(.duration)
        let frames = CMTimeGetSeconds(duration) * Double(frameRate)
        totalFrames = frames
        
        // TODO: Add functionality to specify desired output resolution, bitrate, and
        // TODO: horizontal disparity.
        
        // Setup the video output settings
        var videoSettings = AVOutputSettingsAssistant(preset: .mvhevc1440x1440)?.videoSettings
        videoSettings?[AVVideoWidthKey] = leftEyeRegion.width
        videoSettings?[AVVideoHeightKey] = leftEyeRegion.height
        var compressionProperties = videoSettings?[AVVideoCompressionPropertiesKey] as! [String: Any]
        compressionProperties[AVVideoAverageBitRateKey] = dataRate
        compressionProperties[kVTCompressionPropertyKey_HorizontalDisparityAdjustment as String] = 0
        compressionProperties[kCMFormatDescriptionExtension_HorizontalFieldOfView as String] = 90
        videoSettings?[AVVideoCompressionPropertiesKey] = compressionProperties
        
        // Setup the video input settings
        writerInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        guard let writerInput else { return }
        writerInput.expectsMediaDataInRealTime = false
        
        // Setup the pixel buffer group adaptor for writing left and right eye frames.
        let pixelBufferAdaptor = AVAssetWriterInputTaggedPixelBufferGroupAdaptor(
            assetWriterInput: writerInput,
            sourcePixelBufferAttributes: .none)
        
        // Setup the reader for the stereoscopic video file, or a left eye (hero eye) view, if views were provided for each
        // individual eye.
        let readerOutputSettings: [String:Any] = [
            kCVPixelBufferPixelFormatTypeKey as String:  NSNumber(value: kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: naturalSize.width,
            kCVPixelBufferHeightKey as String: naturalSize.height
        ]
        readerOutput = AVAssetReaderTrackOutput(
            track: videoTrack,
            outputSettings: readerOutputSettings)
        heroReader = try AVAssetReader(asset: heroAsset)
        
        // Add the necessary outputs to the reader and start reading.
        guard let heroReader,
              let readerOutput
        else { return }
        heroReader.add(readerOutput)
        heroReader.startReading()
        
        // Add the necessary inputs to the writer and start the session.
        guard let writer else { return }
        writer.add(writerInput)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        // Flag that we have begun processing.
        isProcessing = true
        
        // Set the start time for processing, which allows downstream estimated time to
        // completion calculations.
        startTime = Date.now
        
        // Inform the writer's input to request data when it's ready.
        writerInput.requestMediaDataWhenReady(on: queue) { [weak self] in
            guard let self else { return }
            while writerInput.isReadyForMoreMediaData {
                autoreleasepool {
                    guard self.processor.isPrepared else {
                        print("The processor is not prepared.  Cannot write video")
                        return
                    }
                    
                    if let frame = readerOutput.copyNextSampleBuffer(),
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
                            sourceVideoURL.stopAccessingSecurityScopedResource()
                            self.stop(with: outputVideoURL)
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
        writerInput?.markAsFinished()
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
            let writerInput
        else { return }
        writerInput.markAsFinished()
        
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
        
        self.writerInput = nil
        self.writer = nil
        self.readerOutput = nil
        self.heroReader = nil
    }
    
    /// Creates a reference to the last successfully completed file for processing, which can be used for
    /// showing a preview to the user for access to the last converted file.
    /// - Parameter outputURL: The output `URL` of the last converted file.
    private func saveLastConvertedFile(outputURL: URL) async throws {
        do {
            let attr = try FileManager.default.attributesOfItem(atPath: outputURL.path)
            let fileSize = attr[FileAttributeKey.size] as? Int64
            
            let asset = AVAsset(url: outputURL)
            let duration = try await asset.load(.duration)
            
            self.lastConvertedFileURL = LastConvertedFile(
                filePath: outputURL,
                timeToProcess: dateFormatter.string(from: startTime, to: Date.now) ?? "Unknown",
                fileSize: byteCountFormatter.string(fromByteCount: fileSize ?? 0),
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
