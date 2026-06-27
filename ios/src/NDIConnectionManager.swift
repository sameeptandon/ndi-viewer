import Foundation
import Combine
import SwiftUI

#if canImport(UIKit)
import UIKit
#endif

// Manage screen idle dimming and sleep prevention dynamically
public final class IdleTimerManager {
    public static let shared = IdleTimerManager()
    private init() {}
    
    #if os(macOS)
    private var activityToken: NSObjectProtocol?
    #endif
    
    public func disableIdleTimer(reason: String) {
        #if os(iOS) || os(visionOS)
        UIApplication.shared.isIdleTimerDisabled = true
        #elseif os(macOS)
        if activityToken == nil {
            activityToken = ProcessInfo.processInfo.beginActivity(
                options: .idleDisplaySleepDisabled,
                reason: reason
            )
        }
        #endif
    }
    
    public func enableIdleTimer() {
        #if os(iOS) || os(visionOS)
        UIApplication.shared.isIdleTimerDisabled = false
        #elseif os(macOS)
        if let token = activityToken {
            ProcessInfo.processInfo.endActivity(token)
            activityToken = nil
        }
        #endif
    }
}

// Declare performance stats locally in Swift
public struct NDIStats {
    public var captureFps: Double = 0.0
    public var totalFrames: Int64 = 0
    public var droppedFrames: Int64 = 0
    public var queueDepth: Int32 = 0
    public var jitterMs: Double = 0.0
    public var renderLatencyMs: Double = 0.0
    public var bitrateMBs: Double = 0.0
}

public class NDIConnectionManager: ObservableObject {
    private var wrapper = NDIEngineWrapper()
    private var statsTimer: Timer?
    private var audioPlayer = NDIAudioPlayer()
    private var latestRenderLatencyMs: Double = 0.0

    @Published public var sources: [String] = []
    @Published public var isStreaming = false
    @Published public var currentSource: String = ""
    @Published public var stats = NDIStats()
    @Published public var streamWidth: CGFloat = 16
    @Published public var streamHeight: CGFloat = 9
    @Published public var preferredTransport: String = "udp"

    // Publisher for the latest frame data (metadata only)
    public let framePublisher = PassthroughSubject<(width: Int, height: Int, stride: Int, timestampMs: Int64, isYUV: Bool), Never>()

    public init() {
        startDiscovery()
    }

    deinit {
        stopDiscovery()
        disconnect()
    }

    public func startDiscovery() {
        wrapper.startDiscovery { [weak self] sources in
            guard let self = self else { return }
            self.sources = sources as? [String] ?? []
        }
    }

    public func stopDiscovery() {
        wrapper.stopDiscovery()
    }

    public func connect(to sourceName: String) {
        guard !sourceName.isEmpty else { return }
        
        if wrapper.connect(to: sourceName, preferredTransport: preferredTransport) {
            isStreaming = true
            currentSource = sourceName
            audioPlayer.start()
            startCapture()
            
            // Disable screen dimming/idle sleep while streaming
            IdleTimerManager.shared.disableIdleTimer(reason: "Streaming NDI source: \(sourceName)")
            
            // Periodically fetch performance metrics (every 500ms)
            statsTimer?.invalidate()
            statsTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                self?.updateStats()
            }
        }
    }

    public func disconnect() {
        statsTimer?.invalidate()
        wrapper.stopCapture()
        wrapper.disconnect()
        audioPlayer.stop()
        
        // Re-enable screen dimming/idle sleep
        IdleTimerManager.shared.enableIdleTimer()
        
        isStreaming = false
        currentSource = ""
        stats = NDIStats()
        streamWidth = 16
        streamHeight = 9
    }


    public func setTargetTexture(_ texture: MTLTexture?) {
        wrapper.setTargetTexture(texture)
    }

    private func startCapture() {
        wrapper.startCapture(
            videoCallback: { [weak self] width, height, stride, timestampMs, isYUV in
                guard let self = self else { return }

                DispatchQueue.main.async {
                    if self.streamWidth != CGFloat(width) || self.streamHeight != CGFloat(height) {
                        self.streamWidth = CGFloat(width)
                        self.streamHeight = CGFloat(height)
                    }
                }

                self.framePublisher.send((
                    width: width,
                    height: height,
                    stride: stride,
                    timestampMs: timestampMs,
                    isYUV: isYUV
                ))
            },
            audioCallback: { [weak self] data, samples, channels, sampleRate, channelStrideBytes in
                guard let self = self, let data = data else { return }
                self.audioPlayer.playPCM(
                    data: data,
                    samples: samples,
                    channels: channels,
                    sampleRate: sampleRate,
                    channelStrideBytes: channelStrideBytes
                )
            }
        )
    }

    public func updateRenderLatency(_ latency: Double) {
        self.latestRenderLatencyMs = latency
    }

    private func updateStats() {
        guard let rawStats = wrapper.getPerformanceStats() as? [String: Any] else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.stats = NDIStats(
                captureFps: rawStats["captureFps"] as? Double ?? 0.0,
                totalFrames: rawStats["totalFrames"] as? Int64 ?? 0,
                droppedFrames: rawStats["droppedFrames"] as? Int64 ?? 0,
                queueDepth: rawStats["queueDepth"] as? Int32 ?? 0,
                jitterMs: rawStats["jitterMs"] as? Double ?? 0.0,
                renderLatencyMs: self.latestRenderLatencyMs,
                bitrateMBs: rawStats["bitrateMBs"] as? Double ?? 0.0
            )
        }
    }

    public func updateTransport(_ transport: String) {
        guard transport != preferredTransport else { return }
        self.preferredTransport = transport
        if isStreaming {
            let source = currentSource
            disconnect()
            // Wait 500ms to allow network sockets to clean up, then reconnect under new protocol
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.connect(to: source)
            }
        }
    }
}
