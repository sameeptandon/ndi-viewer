import SwiftUI
import MetalKit
import Combine

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
                               texture2d<float> colorTexture [[texture(0)]]) {
    constexpr sampler textureSampler(mag_filter::linear, min_filter::linear);
    return colorTexture.sample(textureSampler, in.texCoords);
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
    #else
    public func makeUIView(context: Context) -> MTKView {
        return makeMTKView(context: context)
    }
    
    public func updateUIView(_ uiView: MTKView, context: Context) {}
    #endif
    
    private func makeMTKView(context: Context) -> MTKView {
        let mtkView = MTKView()
        mtkView.device = MTLCreateSystemDefaultDevice()
        mtkView.colorPixelFormat = .bgra8Unorm
        mtkView.framebufferOnly = true
        
        // Manual rendering mode (only render when new frames arrive)
        mtkView.isPaused = true
        mtkView.enableSetNeedsDisplay = false
        mtkView.delegate = context.coordinator
        
        context.coordinator.manager = manager
        context.coordinator.setupPipeline(with: mtkView)
        context.coordinator.subscribe(to: manager.framePublisher, view: mtkView)
        
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
        
        func subscribe(to publisher: PassthroughSubject<(data: Data, width: Int, height: Int, stride: Int, timestampMs: Int64), Never>, view: MTKView) {
            cancellable = publisher
                .sink { [weak self, weak view] frame in
                    guard let self = self, let view = view else { return }
                    
                    self.textureMutex.lock()
                    defer { self.textureMutex.unlock() }
                    
                    self.latestFrameTimestampMs = frame.timestampMs
                    
                    // Create texture if dimensions changed
                    if self.texture == nil || self.texture?.width != frame.width || self.texture?.height != frame.height {
                        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                            pixelFormat: .bgra8Unorm,
                            width: frame.width,
                            height: frame.height,
                            mipmapped: false
                        )
                        descriptor.usage = [.shaderRead]
                        self.texture = self.device?.makeTexture(descriptor: descriptor)
                    }
                    
                    // Upload raw frame data directly to the GPU texture
                    let region = MTLRegionMake2D(0, 0, frame.width, frame.height)
                    frame.data.withUnsafeBytes { rawBufferPointer in
                        if let baseAddress = rawBufferPointer.baseAddress {
                            self.texture?.replace(
                                region: region,
                                mipmapLevel: 0,
                                withBytes: baseAddress,
                                bytesPerRow: frame.stride
                            )
                        }
                    }
                    
                    // Force the MTKView to draw immediately
                    DispatchQueue.main.async {
                        view.draw()
                    }
                }
        }
        
        public func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
        
        public func draw(in view: MTKView) {
            textureMutex.lock()
            defer { textureMutex.unlock() }
            
            guard let drawable = view.currentDrawable,
                  let renderPassDescriptor = view.currentRenderPassDescriptor,
                  let pipelineState = pipelineState,
                  let commandQueue = commandQueue,
                  let texture = texture else { return }
            
            // Set clear color to black
            renderPassDescriptor.colorAttachments[0].clearColor = MTLClearColor(red: 0.05, green: 0.05, blue: 0.07, alpha: 1.0)
            
            guard let commandBuffer = commandQueue.makeCommandBuffer(),
                  let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: renderPassDescriptor) else { return }
            
            encoder.setRenderPipelineState(pipelineState)
            encoder.setFragmentTexture(texture, index: 0)
            
            // Draw full-screen quad (4 vertices mapped inside the vertex shader)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            encoder.endEncoding()
            
            commandBuffer.present(drawable)
            commandBuffer.commit()
            
            // Calculate and publish rendering latency
            let now = Int64(Date().timeIntervalSince1970 * 1000)
            let latency = Double(now - latestFrameTimestampMs)
            if latency >= 0 && latency < 5000 {
                DispatchQueue.main.async { [weak self] in
                    self?.manager?.updateRenderLatency(latency)
                }
            }
        }
    }
}
