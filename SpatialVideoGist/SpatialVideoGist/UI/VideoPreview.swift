//
//  VideoPreview.metal
//  SpatialVideoGist
//
//  Created by Bryan on 12/18/23.
//

import AVFoundation
import MetalKit
import SwiftUI

/// A SwiftUI view wrapping an underlying Metal view that provides a video preview of an in-progress file convert.
struct VideoPreview: NSViewRepresentable {
    // MARK: - Properties
    
    // MARK: Public
    
    /// The left eye view of the current frame being processed.
    var leftEyePreviewImage: CVPixelBuffer
    
    /// The right eye view of the current frame being processed.
    var rightEyePreviewImage: CVPixelBuffer
    
    // MARK: - Methods
    
    /// Creates a representable wrapping the underlying `MetalPlayer`.
    /// - Parameter context: The context of the representable.
    /// - Returns: The computed `MetalPlayer` made available to SwiftUI.
    func makeNSView(context: Context) -> MetalPlayer {
        let ciImage = CIImage(cvPixelBuffer: leftEyePreviewImage)
        let frame = CGRect(
            x: 0,
            y: 0,
            width: ciImage.extent.width * 2,
            height: ciImage.extent.height
        )
        return MetalPlayer(frame: frame)
    }
    
    /// Updates the underlying `MetalView` when the parent SwiftUI view injects new preview images.
    /// - Parameters:
    ///   - nsView: The `MetalPlayer` being updated.
    ///   - context: The context of the representable.
    func updateNSView(
        _ nsView: MetalPlayer,
        context: Context
    ) {
        nsView.render(
            leftPixelBuffer: leftEyePreviewImage,
            rightPixelBuffer: rightEyePreviewImage
        )
    }
}

/// A Metal view that renders a preview of the in-progress video convert.
class MetalPlayer: MTKView {
    // MARK: - Properties
    
    // MARK: Private
    
    /// The color space to use for displaying the video frames.
    private let colorSpace = CGColorSpaceCreateDeviceRGB()
    
    /// The command queue to use for processing graphics commans.
    private lazy var commandQueue: MTLCommandQueue? = {
        return self.device!.makeCommandQueue()
    }()
    
    /// The `CIContext` to use for writing textures to the view for preview.
    private lazy var context: CIContext = {
        return CIContext(
            mtlDevice: self.device!,
            options: [CIContextOption.workingColorSpace : NSNull()]
        )
    }()
    
    /// The Metal device that should be used for processing the pipeline.
    private let metalDevice = MTLCreateSystemDefaultDevice()!
    
    /// A texture cache for storing caches texture that can be written to.
    private var textureCache: CVMetalTextureCache?
    
    /// A pool that can provide `CVPixelBuffer`s for output.
    private var outputPixelBufferPool: CVPixelBufferPool?
    
    /// The pipeline state that can be used for writing video previews to the library.
    private var computePipelineState: MTLComputePipelineState?
    
    /// The image that should be drawn onto the view.
    private var image: CIImage? {
        didSet {
            draw()
        }
    }
    
    // MARK: - Methods
    
    // MARK: Public
    
    /// Initializes this view using the provided coordinates and size.
    /// - Parameter frameRect: The coordinates and size to render this view.
    init(frame frameRect: CGRect) {
        super.init(
            frame: frameRect,
            device: metalDevice
        )
        setup(frameSize: frameRect.size)
    }
    
    /// Required conformance for initializer.
    /// - Parameter aDecoder: The `NSCoder` to use to create this view.
    required init(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
        device = MTLCreateSystemDefaultDevice()
        setup(frameSize: .zero)
    }
    
    // MARK: Private
    
    /// Configures this view and its properties, then creates the necessary caches.
    /// - Parameter frameSize: The desired size of this view.
    private func setup(frameSize: CGSize) {
        framebufferOnly = false
        enableSetNeedsDisplay = false
        
        guard let defaultLibrary = metalDevice.makeDefaultLibrary() else {
            assertionFailure("Could not create default Metal device.")
            return
        }
        
        let kernelFunction = defaultLibrary.makeFunction(name: "sideBySideEffect")
        do {
          computePipelineState = try metalDevice.makeComputePipelineState(function: kernelFunction!)
        } catch {
          print("Could not create pipeline state: \(error)")
        }
        setupCache(
            outputRetainedBufferCountHint: 5,
            frameSize: frameSize
        )
    }
    
    /// Configures the necessary caches to hold the in-progress textures as they are being written to.
    /// - Parameters:
    ///   - outputRetainedBufferCountHint: The ideal number of buffers to retain.
    ///   - frameSize: The desired size of this view and its textures.
    private func setupCache(
        outputRetainedBufferCountHint: Int,
        frameSize: CGSize
    ) {
        reset()
      
        let outputSize = CGSize(
            width: frameSize.width,
            height: frameSize.height
        )
        
        guard let outputPixelBufferPool = createBufferPool(size: outputSize)  else {return}
        self.outputPixelBufferPool = outputPixelBufferPool
        var metalTextureCache: CVMetalTextureCache?
        if CVMetalTextureCacheCreate(
            kCFAllocatorDefault,
            nil,
            metalDevice,
            nil,
            &metalTextureCache
        ) != kCVReturnSuccess {
            assertionFailure("Unable to allocate texture cache")
        } else {
            textureCache = metalTextureCache
        }
    }
    
    /// Resets the caches for re-configuration.
    func reset() {
        outputPixelBufferPool = nil
        textureCache = nil
    }
    
    /// Renders the provided `CVPixelBuffer` images onto the view.
    /// - Parameters:
    ///   - leftPixelBuffer: The left eye preview image to render onto the view.
    ///   - rightPixelBuffer: The right eye preview image to render onto the view.
    func render(
        leftPixelBuffer: CVPixelBuffer,
        rightPixelBuffer: CVPixelBuffer
    ) {
        var outputPixelBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(
            kCFAllocatorDefault,
            outputPixelBufferPool!,
            &outputPixelBuffer
        )
        guard let outputBuffer = outputPixelBuffer else {
            print("Allocation failure: Could not get pixel buffer from pool. (\(self.description))")
            return
        }
            
        guard 
            let leftInputTexture = makeTextureFromCVPixelBuffer(
                pixelBuffer: leftPixelBuffer,
                textureFormat: .bgra8Unorm
            ),
            let rightInputTexture = makeTextureFromCVPixelBuffer(
                pixelBuffer: rightPixelBuffer,
                textureFormat: .bgra8Unorm
            ),
            let outputTexture = makeTextureFromCVPixelBuffer(
                pixelBuffer: outputBuffer,
                textureFormat: .bgra8Unorm
            )
        else { return }
            
        // Set up command queue, buffer, and encoder.
        guard let commandQueue = commandQueue,
            let commandBuffer = commandQueue.makeCommandBuffer(),
            let commandEncoder = commandBuffer.makeComputeCommandEncoder() else {
                print("Failed to create a Metal command queue.")
                CVMetalTextureCacheFlush(textureCache!, 0)
                return
        }
        
        commandEncoder.label = "BlendGPU"
        commandEncoder.setComputePipelineState(computePipelineState!)
        commandEncoder.setTexture(leftInputTexture, index: 0)
        commandEncoder.setTexture(rightInputTexture, index: 1)
        commandEncoder.setTexture(outputTexture, index: 2)
            
        // Set up the thread groups.
        let width = computePipelineState!.threadExecutionWidth
        let height = computePipelineState!.maxTotalThreadsPerThreadgroup / width
        let threadsPerThreadgroup = MTLSizeMake(width, height, 1)
        let threadgroupsPerGrid = MTLSize(width: (leftInputTexture.width + width - 1) / width,
                                          height: (leftInputTexture.height + height - 1) / height,
                                          depth: 1)
        commandEncoder.dispatchThreadgroups(threadgroupsPerGrid, threadsPerThreadgroup: threadsPerThreadgroup)
        commandEncoder.endEncoding()
        commandBuffer.commit()
        commandBuffer.waitUntilCompleted()
        
        guard let outputPixelBuffer else { return }
        self.image = CIImage(cvPixelBuffer: outputPixelBuffer)
    }
    
    /// Draws the `image` onto this view.
    /// - Parameter rect: The coordinates and size to draw the image onto.
    override func draw(_ rect: CGRect) {
        guard let image = image,
            let currentDrawable = currentDrawable,
            let commandBuffer = commandQueue?.makeCommandBuffer()
              else {
          return
        }
        let currentTexture = currentDrawable.texture
        let drawingBounds = CGRect(origin: .zero, size: drawableSize)

        let scaleX = drawableSize.width / image.extent.width
        let scaleY = drawableSize.height / image.extent.height
        let scaledImage = image.transformed(by: CGAffineTransform(scaleX: scaleX, y: scaleY))

        context.render(scaledImage, to: currentTexture, commandBuffer: commandBuffer, bounds: drawingBounds, colorSpace: colorSpace)

        commandBuffer.present(currentDrawable)
        commandBuffer.commit()
    }
    
    /// Creates a `MTLTexture` from the provided `CVPixelBuffer` for use with the shader.
    /// - Parameters:
    ///   - pixelBuffer: The provided pixel buffer to convert to the texture.
    ///   - textureFormat: The texture's pixel format to use.
    /// - Returns: The converted `MTLTexture`, if one could be created.
    private func makeTextureFromCVPixelBuffer(
        pixelBuffer: CVPixelBuffer,
        textureFormat: MTLPixelFormat
    ) -> MTLTexture? {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard let textureCache else { return nil }
        // Create a Metal texture from the image buffer.
        var cvTextureOut: CVMetalTexture?
        CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault,
            textureCache,
            pixelBuffer,
            nil,
            textureFormat,
            width,
            height,
            0,
            &cvTextureOut
        )
        
        guard let cvTextureOut,
              let texture = CVMetalTextureGetTexture(cvTextureOut)
        else {
            CVMetalTextureCacheFlush(textureCache, 0)
            return nil
        }
        return texture
    }
    
    /// Creates the `CVPixelBufferPool` to vend pixel buffers for writing in-progress converted frames.
    /// - Parameter size: The size of each pixel buffer.
    /// - Returns: The `CVPixelBufferPool`, if it could be created.
    private func createBufferPool(size: CGSize) -> CVPixelBufferPool? {
        let allocationThreshold = 5
        let sourcePixelBufferAttributesDictionary = [
            kCVPixelBufferPixelFormatTypeKey as String: NSNumber(value: kCVPixelFormatType_32BGRA),
            kCVPixelBufferWidthKey as String: NSNumber(value: Float(size.width)),
            kCVPixelBufferHeightKey as String: NSNumber(value: Float(size.height)),
            kCVPixelBufferMetalCompatibilityKey as String: kCFBooleanTrue!,
            kCVPixelBufferIOSurfacePropertiesKey as String: [
                kCVPixelBufferIOSurfaceCoreAnimationCompatibilityKey:kCFBooleanTrue,
            ]
        ] as [String : Any]
        let poolAttributes = [kCVPixelBufferPoolMinimumBufferCountKey as String: allocationThreshold]

        var cvPixelBufferPool: CVPixelBufferPool?
        CVPixelBufferPoolCreate(kCFAllocatorDefault, poolAttributes as NSDictionary?, sourcePixelBufferAttributesDictionary as NSDictionary?, &cvPixelBufferPool)

        return cvPixelBufferPool
    }
}
