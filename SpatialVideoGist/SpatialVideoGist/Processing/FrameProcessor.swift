//
//  FrameProcessor.swift
//  SpatialVideoGist
//
//
//  Created by Bryan on 12/15/23.
//

import AVFoundation
import CoreImage

/// A processor that can be used to crop and manipulate video frames as well as convert between underlying image types.
final class FrameProcessor {
    // MARK: - Properties
    
    // MARK: Public
    
    /// A flag determining if the processor has already been configured.
    var isPrepared = false

    // MARK: Private
    
    /// The `CIContext` that can be used for image manipulation.
    private var ciContext: CIContext?
    
    /// The output color space for the processing of the images.
    private var outputColorSpace: CGColorSpace?
    
    /// A `CVPixelBufferPool` for holding in-process pixel buffers.
    private var outputPixelBufferPool: CVPixelBufferPool?
    
    /// The input `CMFormatDescription` for configuring the processor.
    private(set) var inputFormatDescription: CMFormatDescription?
    
    /// The output `CMFormatDescription` for configuring the processor.
    private(set) var outputFormatDescription: CMFormatDescription?
    
    /// The system's Metal device for GPU processing.
    private let metalDevice = MTLCreateSystemDefaultDevice()!
    
    /// A cache for holding `CVMetalTexture` items.
    private var textureCache: CVMetalTextureCache!
    
    // MARK: - Methods
    
    /// Prepares this processor with the provided format description and buffers to retain.
    /// - Parameters:
    ///   - formatDescription: The injected `CMFormatDescription` to assist the processor with setup.
    ///   - outputRetainedBufferCountHint: The number of buffers to retain during processing.
    func prepare(
        with formatDescription: CMFormatDescription,
        outputRetainedBufferCountHint: Int
    ) {
        reset()

        (outputPixelBufferPool,
         outputColorSpace,
         outputFormatDescription) = allocateOutputBufferPool(
            with: formatDescription,
            outputRetainedBufferCountHint: outputRetainedBufferCountHint
         )
        
        if outputPixelBufferPool == nil {
            return
        }
        inputFormatDescription = formatDescription
        ciContext =  CIContext()

        var metalTextureCache: CVMetalTextureCache?
        if CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, metalDevice, nil, &metalTextureCache) != kCVReturnSuccess {
            assertionFailure("Unable to allocate texture cache")
        } else {
            textureCache = metalTextureCache
        }

        isPrepared = true
    }
    
    /// Crops the provided `CIImage` to the given `CGRect`, then converts to a `CVPixelBuffer`.
    /// - Parameters:
    ///   - pixelBufferImage: The source pixel buffer, as a `CIImage`.
    ///   - targetRect: The target `CGRect` that the pixel buffer image should be cropped to.
    /// - Returns: The cropped image as a `CVPixelBuffer`, if it can be processed.
    func cropPixelBuffer(
        pixelBufferImage: CIImage,
        targetRect: CGRect
    ) -> CVPixelBuffer? {
        guard let ciContext = ciContext,
              isPrepared
        else {
                isPrepared = false
                return nil
        }
        
        var croppedImage = pixelBufferImage.cropped(to: targetRect)
        
        let originTransform = CGAffineTransform(
            translationX: -croppedImage.extent.origin.x,
            y: -croppedImage.extent.origin.y
        )
        croppedImage = croppedImage.transformed(by: originTransform)
        
        var pbuf: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, outputPixelBufferPool!, &pbuf)
        guard let outputPixelBuffer = pbuf else {
            print("Allocation failure")
            return nil
        }

        // Render the filtered image out to a pixel buffer (no locking needed, as CIContext's render method will do that)
        ciContext.render(
            croppedImage,
            to: outputPixelBuffer,
            bounds: croppedImage.extent,
            colorSpace: outputColorSpace
        )
        
        return outputPixelBuffer
    }
    
    // MARK: - Private

    /// Resets the processor to its unprepared state.
    private func reset() {
        ciContext = nil
        outputColorSpace = nil
        outputPixelBufferPool = nil
        outputFormatDescription = nil
        inputFormatDescription = nil
        textureCache = nil
        isPrepared = false
    }
}

/// Helper methods for setup of the processor.
private extension FrameProcessor {
    
    /// Allocates memory for the output pixel buffer pool.
    /// - Parameters:
    ///   - inputFormatDescription: The provided `CMFormatDescription` for configuring the processor.
    ///   - outputRetainedBufferCountHint: The number of buffers to retain hint.
    /// - Returns: A tuple containing the output pixel buffer pool, color space, and format description.
    private func allocateOutputBufferPool(
        with inputFormatDescription: CMFormatDescription,
        outputRetainedBufferCountHint: Int
    ) ->(
        outputBufferPool: CVPixelBufferPool?,
        outputColorSpace: CGColorSpace?,
        outputFormatDescription: CMFormatDescription?) {

            let inputDimensions = CMVideoFormatDescriptionGetDimensions(inputFormatDescription)
            var pixelBufferAttributes: [String: Any] = [
                kCVPixelBufferPixelFormatTypeKey as String: UInt(kCVPixelFormatType_32BGRA),
                kCVPixelBufferWidthKey as String: Int(inputDimensions.width / 2),
                kCVPixelBufferHeightKey as String: Int(inputDimensions.height),
                kCVPixelBufferIOSurfacePropertiesKey as String: [:]
            ]

            // Get pixel buffer attributes and color space from the input format description.
            var cgColorSpace = CGColorSpaceCreateDeviceRGB()
            if let inputFormatDescriptionExtension = CMFormatDescriptionGetExtensions(inputFormatDescription) as Dictionary? {
                let colorPrimaries = inputFormatDescriptionExtension[kCVImageBufferColorPrimariesKey]

                if let colorPrimaries = colorPrimaries {
                    var colorSpaceProperties: [String: AnyObject] = [kCVImageBufferColorPrimariesKey as String: colorPrimaries]

                    if let yCbCrMatrix = inputFormatDescriptionExtension[kCVImageBufferYCbCrMatrixKey] {
                        colorSpaceProperties[kCVImageBufferYCbCrMatrixKey as String] = yCbCrMatrix
                    }

                    if let transferFunction = inputFormatDescriptionExtension[kCVImageBufferTransferFunctionKey] {
                        colorSpaceProperties[kCVImageBufferTransferFunctionKey as String] = transferFunction
                    }

                    pixelBufferAttributes[kCVBufferPropagatedAttachmentsKey as String] = colorSpaceProperties
                }

                if let cvColorspace = inputFormatDescriptionExtension[kCVImageBufferCGColorSpaceKey] {
                    cgColorSpace = cvColorspace as! CGColorSpace
                } else if (colorPrimaries as? String) == (kCVImageBufferColorPrimaries_P3_D65 as String) {
                    cgColorSpace = CGColorSpace(name: CGColorSpace.displayP3)!
                }
            }

            // Create a pixel buffer pool with the same pixel attributes as the input format description.
            let poolAttributes = [kCVPixelBufferPoolMinimumBufferCountKey as String: outputRetainedBufferCountHint]
            var cvPixelBufferPool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(kCFAllocatorDefault, poolAttributes as NSDictionary?, pixelBufferAttributes as NSDictionary?, &cvPixelBufferPool)
            guard let pixelBufferPool = cvPixelBufferPool else {
                assertionFailure("Allocation failure: Could not allocate pixel buffer pool.")
                return (nil, nil, nil)
            }

            preallocateBuffers(pool: pixelBufferPool, allocationThreshold: outputRetainedBufferCountHint)

            // Get the output format description.
            var pixelBuffer: CVPixelBuffer?
            var outputFormatDescription: CMFormatDescription?
            let auxAttributes = [kCVPixelBufferPoolAllocationThresholdKey as String: outputRetainedBufferCountHint] as NSDictionary
            CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, pixelBufferPool, auxAttributes, &pixelBuffer)
            if let pixelBuffer = pixelBuffer {
                CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                                             imageBuffer: pixelBuffer,
                                                             formatDescriptionOut: &outputFormatDescription)
            }
            pixelBuffer = nil

            return (pixelBufferPool, cgColorSpace, outputFormatDescription)
    }

    
    /// Pre-allocates pixel buffers from the pool for processing.
    /// - Parameters:
    ///   - pool: The `CVPixelBufferPool` to preallocate from.
    ///   - allocationThreshold: The threshold of how many buffers can be allocated from the pool.
    private func preallocateBuffers(
        pool: CVPixelBufferPool,
        allocationThreshold: Int
    ) {
        var pixelBuffers = [CVPixelBuffer]()
        var error: CVReturn = kCVReturnSuccess
        let auxAttributes = [kCVPixelBufferPoolAllocationThresholdKey as String: allocationThreshold] as NSDictionary
        var pixelBuffer: CVPixelBuffer?
        while error == kCVReturnSuccess {
            error = CVPixelBufferPoolCreatePixelBufferWithAuxAttributes(kCFAllocatorDefault, pool, auxAttributes, &pixelBuffer)
            if let pixelBuffer = pixelBuffer {
                pixelBuffers.append(pixelBuffer)
            }
            pixelBuffer = nil
        }
        pixelBuffers.removeAll()
    }
}
