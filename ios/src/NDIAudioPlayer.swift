import AVFoundation

public class NDIAudioPlayer {
    private let audioEngine = AVAudioEngine()
    private let playerNode = AVAudioPlayerNode()
    private var audioFormat: AVAudioFormat?
    private var isPlaying = false
    private let queue = DispatchQueue(label: "com.ndi-viewer.audioPlayer", qos: .userInteractive)

    public init() {
        audioEngine.attach(playerNode)
        
        // Connect with a default format to ensure audio graph validity on startup
        if let defaultFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48000.0,
            channels: 2,
            interleaved: false
        ) {
            audioEngine.connect(playerNode, to: audioEngine.mainMixerNode, format: defaultFormat)
            self.audioFormat = defaultFormat
        }
    }

    deinit {
        stop()
    }

    private func configureAudioSession() {
        #if os(iOS)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(AVAudioSession.Category.playback, mode: AVAudioSession.Mode.default, options: [])
            try session.setActive(true)
        } catch {
            print("Audio Session Error: Failed to configure audio session: \(error)")
        }
        #endif
    }

    public func start() {
        configureAudioSession()
        queue.async { [weak self] () -> Void in
            guard let self = self else { return }
            do {
                if !self.audioEngine.isRunning {
                    try self.audioEngine.start()
                }
                self.playerNode.play()
                self.isPlaying = true
            } catch {
                print("Audio Engine Error: Failed to start: \(error)")
            }
        }
    }

    public func stop() {
        queue.sync { [weak self] () -> Void in
            guard let self = self else { return }
            self.playerNode.stop()
            self.audioEngine.stop()
            self.isPlaying = false
            self.audioFormat = nil
        }
    }

    public func playPCM(data: Data, samples: Int, channels: Int, sampleRate: Int, channelStrideBytes: Int) {
        guard samples > 0, channels > 0 else { return }
        
        queue.async { [weak self] () -> Void in
            guard let self = self, self.isPlaying else { return }

            // Re-configure engine and player node if format changes
            if self.audioFormat == nil ||
               self.audioFormat?.sampleRate != Double(sampleRate) ||
               self.audioFormat?.channelCount != AVAudioChannelCount(channels) {
                
                guard let newFormat = AVAudioFormat(
                    commonFormat: .pcmFormatFloat32,
                    sampleRate: Double(sampleRate),
                    channels: AVAudioChannelCount(channels),
                    interleaved: false
                ) else {
                    print("Audio Error: Failed to create AVAudioFormat")
                    return
                }
                self.audioFormat = newFormat
                
                self.playerNode.stop()
                self.audioEngine.disconnectNodeOutput(self.playerNode)
                self.audioEngine.connect(self.playerNode, to: self.audioEngine.mainMixerNode, format: newFormat)
                self.playerNode.play()
            }

            guard let format = self.audioFormat else { return }

            // Safeguard: Ensure the player node is actively playing before scheduling
            if !self.playerNode.isPlaying {
                self.playerNode.play()
            }

            // Allocate non-interleaved float32 buffer
            guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(samples)) else {
                print("Audio Error: Failed to allocate AVAudioPCMBuffer")
                return
            }
            buffer.frameLength = AVAudioFrameCount(samples)

            // Copy planar float32 channels
            data.withUnsafeBytes { rawBuffer in
                guard let baseAddress = rawBuffer.baseAddress else { return }
                
                for c in 0..<channels {
                    if let dest = buffer.floatChannelData?[c] {
                        let source = baseAddress.advanced(by: c * channelStrideBytes)
                        memcpy(dest, source, samples * MemoryLayout<Float>.size)
                    }
                }
            }

            // Schedule the buffer to play immediately
            self.playerNode.scheduleBuffer(buffer, at: nil, options: [], completionHandler: nil)
        }
    }
}
