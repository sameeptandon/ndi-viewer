import SwiftUI
import MetalKit
import Combine
import CoreVideo

#if os(macOS)
import AppKit
public typealias PlatformViewRepresentable = NSViewRepresentable
#else
import UIKit
public typealias PlatformViewRepresentable = UIViewRepresentable
#endif

// Inline Metal shader source code to avoid bundle loading dependencies in CMake
private let shaderSource = """
#include <metal_stdlib>
using namespace metal;

struct VertexOutput {
    float4 position [[position]];
    float2 texCoords;
};

vertex VertexOutput vertexShader(uint vertexId [[vertex_id]]) {
    VertexOutput out;
    
    // Texture coordinates mapped to [0.0, 1.0]
    float2 texCoords[4] = {
        float2(0.0, 1.0),
        float2(1.0, 1.0),
        float2(0.0, 0.0),
        float2(1.0, 0.0)
    };
    
    // Position mapped to clip space [-1.0, 1.0]
    float4 positions[4] = {
        float4(-1.0, -1.0, 0.0, 1.0),
        float4( 1.0, -1.0, 0.0, 1.0),
        float4(-1.0,  1.0, 0.0, 1.0),
        float4( 1.0,  1.0, 0.0, 1.0)
    };
    
    out.position = positions[vertexId];
    out.texCoords = texCoords[vertexId];
    return out;
}

fragment float4 fragmentShader(VertexOutput in [[stage_in]],
                               texture2d<float> colorTexture [[texture(0)]],
                               constant uint32_t &isYUV [[buffer(0)]]) {
    // Explicit clamp_to_edge is required for subsampled YUV format textures like bgrg422
    constexpr sampler textureSampler(mag_filter::linear, min_filter::linear, address::clamp_to_edge);
    float4 color = colorTexture.sample(textureSampler, in.texCoords);
    
    if (isYUV != 0) {
        // ITU-R BT.709 Limited Range (Studio Swing: Y: 16-235, Cb/Cr: 16-240) YUV-to-RGB matrix.
        // This expands the dynamic range to full [0, 255] RGB, restoring deep blacks, whites, and color saturation.
        float y = 1.164383 * (color.g - 0.062745); // (Y - 16/255) * (255 / 219)
        float cr = color.r - 0.501961;             // Cr - 128/255
        float cb = color.b - 0.501961;             // Cb - 128/255
        
        float r = y + 1.792741 * cr;
        float g = y - 0.213249 * cb - 0.532909 * cr;
        float b = y + 2.112402 * cb;
        return float4(r, g, b, 1.0);
    } else {
        return color;
    }
}
"""

public struct MetalVideoView: PlatformViewRepresentable {
    @ObservedObject var manager: NDIConnectionManager
    
    public init(manager: NDIConnectionManager) {
        self.manager = manager
    }
    
    #if os(macOS)
    public func makeNSView(context: Context) -> MTKView {
        return makeMTKView(context: context)
    }
    
    public func updateNSView(_ nsView: MTKView, context: Context) {}
    
    public func sizeThatFits(_ proposal: ProposedViewSize, nsView: MTKView, context: Context) -> CGSize? {
        return proposal.replacingUnspecifiedDimensions()
    }
    #else
    public func makeUIView(context: Context) -> MTKView {
        return makeMTKView(context: context)
    }
    
    public func updateUIView(_ uiView: MTKView, context: Context) {}
    
    public func sizeThatFits(_ proposal: ProposedViewSize, uiView: MTKView, context: Context) -> CGSize? {
        return proposal.replacingUnspecifiedDimensions()
    }
    #endif
    
    private func makeMTKView(context: Context) -> MTKView {
        let mtkView = NDIMetalView()
        mtkView.device = MTLCreateSystemDefaultDevice()
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.framebufferOnly = true
        mtkView.delegate = context.coordinator
        
        context.coordinator.manager = manager
        context.coordinator.setupPipeline(with: mtkView)
        context.coordinator.subscribe(to: manager.framePublisher)
        
        return mtkView
    }
    
    public func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    public class Coordinator: NSObject, MTKViewDelegate {
        weak var manager: NDIConnectionManager?
        private var device: MTLDevice?
        private var commandQueue: MTLCommandQueue?
        private var pipelineState: MTLRenderPipelineState?
        private var texture: MTLTexture?
        private var cancellable: AnyCancellable?
        private var latestFrameTimestampMs: Int64 = 0
        private var currentFrameIsYUV = false
        
        // Thread-safe state for storing incoming network frames
        private var pendingFrame: (width: Int, height: Int, stride: Int, isYUV: Bool)? = nil
        private let textureMutex = NSLock()
        
        func setupPipeline(with mtkView: MTKView) {
            guard let device = mtkView.device else { return }
            self.device = device
            self.commandQueue = device.makeCommandQueue()
            
            // Compile Metal shaders dynamically at runtime
            do {
                let library = try device.makeLibrary(source: shaderSource, options: nil)
                let pipelineDescriptor = MTLRenderPipelineDescriptor()
                pipelineDescriptor.vertexFunction = library.makeFunction(name: "vertexShader")
                pipelineDescriptor.fragmentFunction = library.makeFunction(name: "fragmentShader")
                pipelineDescriptor.colorAttachments[0].pixelFormat = mtkView.colorPixelFormat
                
                self.pipelineState = try device.makeRenderPipelineState(descriptor: pipelineDescriptor)
            } catch {
                print("Metal Error: Failed to compile shaders or create pipeline: \(error)")
            }
        }
        
        func subscribe(to publisher: PassthroughSubject<(width: Int, height: Int, stride: Int, timestampMs: Int64, isYUV: Bool), Never>) {
            cancellable = publisher
                .sink { [weak self] frame in
                    guard let self = self else { return }
                    
                    self.textureMutex.lock()
                    defer { self.textureMutex.unlock() }
                    
                    self.latestFrameTimestampMs = frame.timestampMs
                    self.currentFrameIsYUV = frame.isYUV
                    
                    let pixelFormat: MTLPixelFormat = frame.isYUV ? .bgrg422 : .bgra8Unorm
                    
                    // Create texture if dimensions or pixel format changed
                    if self.texture == nil ||
                       self.texture?.width != frame.width ||
                       self.texture?.height != frame.height ||
                       self.texture?.pixelFormat != pixelFormat {
                        
                        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                            pixelFormat: pixelFormat,
                            width: frame.width,
                            height: frame.height,
                            mipmapped: false
                        )
                        descriptor.usage = [.shaderRead]
                        descriptor.storageMode = .shared
                        self.texture = self.device?.makeTexture(descriptor: descriptor)
                        
                        // Register the new texture with the Connection Manager (and C++ bridge)
                        self.manager?.setTargetTexture(self.texture)
                    }
                    
                    self.pendingFrame = (width: frame.width, height: frame.height, stride: frame.stride, isYUV: frame.isYUV)
                }
        }
        
        public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
        
        public func draw(in view: MTKView) {
            self.textureMutex.lock()
            let hasFrame = (self.pendingFrame != nil)
            let timestamp = self.latestFrameTimestampMs
            let texture = self.texture
            let isYUV = self.currentFrameIsYUV
            self.textureMutex.unlock()
            
            guard let drawable = view.currentDrawable,
                  let renderPassDescriptor = view.currentRenderPassDescriptor,
                  let pipelineState = pipelineState,
                  let commandQueue = commandQueue else { return }
            
            // Set clear color to black
            renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0.05, green: 0.05, blue: 0.07, alpha: 1.0)
            
            guard hasFrame, let tex = texture else {
                // If no frame has arrived yet, just clear and present black
                guard let commandBuffer = commandQueue.makeCommandBuffer(),
                      let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else { return }
                encoder.endEncoding()
                commandBuffer.present(drawable)
                commandBuffer.commit()
                return
            }
            
            guard let commandBuffer = commandQueue.makeCommandBuffer(),
                  let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else { return }
            
            encoder.setRenderPipelineState(pipelineState)
            encoder.setFragmentTexture(tex, index: 0)
            
            var isYUVVal: UInt32 = isYUV ? 1 : 0
            encoder.setFragmentBytes(&isYUVVal, length: MemoryLayout<UInt32>.size, index: 0)
            
            // Draw full-screen quad (4 vertices mapped inside the vertex shader)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            encoder.endEncoding()
            
            commandBuffer.present(drawable)
            commandBuffer.commit()
            
            // Calculate and publish rendering latency
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            let latency = Double(now - timestamp)
            if latency >= 0 && latency < 5000 {
                DispatchQueue.main.async { [weak self] in
                    self?.manager?.updateRenderLatency(latency)
                }
            }
        }
    }
}

#if os(macOS)
class NDIMetalView: MTKView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if self.window != nil {
            // Enable CoreAnimation backing (required for MTKView display link on macOS)
            self.wantsLayer = true
            
            // Set isPaused = false and enableSetNeedsDisplay = false to run the continuous background VSYNC loop
            self.isPaused = false
            self.enableSetNeedsDisplay = false
            self.preferredFramesPerSecond = 60 // Lock to 60 FPS to match NDI source rate and prevent redundant rendering
        } else {
            self.isPaused = true
        }
    }
}
#else
class NDIMetalView: MTKView {
    override func didMoveToWindow() {
        super.didMoveToWindow()
        if self.window != nil {
            // Set isPaused = false and enableSetNeedsDisplay = false to run the continuous background VSYNC loop
            self.isPaused = false
            self.enableSetNeedsDisplay = false
            self.preferredFramesPerSecond = 60
        } else {
            self.isPaused = true
        }
    }
}
#endif
