import SwiftUI

struct MainDashboard: View {
    @StateObject private var manager = NDIConnectionManager()
    @State private var selectedSource: String? = nil
    @State private var showDiagnostics = false
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    
    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SidebarView(manager: manager, selectedSource: $selectedSource)
        } detail: {
            ZStack {
                Color(red: 0.05, green: 0.05, blue: 0.07)
                
                #if os(macOS)
                WindowAccessor { window in
                    window.titleVisibility = .hidden
                    window.titlebarAppearsTransparent = true
                    window.styleMask.insert(.fullSizeContentView)
                }
                .frame(width: 0, height: 0)
                #endif
                
                if manager.isStreaming {
                    MetalVideoView(manager: manager)
                        .aspectRatio(manager.streamWidth / manager.streamHeight, contentMode: .fit)
                        .onTapGesture(count: 2) {
                            #if os(macOS)
                            if let window = NSApp.windows.first(where: { $0.isKeyWindow }) {
                                window.toggleFullScreen(nil)
                            }
                            #endif
                        }
                    
                    // Diagnostics HUD overlay
                    if showDiagnostics {
                        DiagnosticsHUD(stats: manager.stats, sourceName: manager.currentSource)
                            .transition(.opacity.combined(with: .scale(scale: 0.95)))
                    }
                    
                    // Top-right controls overlay
                    VStack {
                        HStack {
                            Spacer()
                            HStack(spacing: 12) {
                                #if os(macOS)
                                Button(action: {
                                    if let window = NSApp.windows.first(where: { $0.isKeyWindow }) {
                                        window.toggleFullScreen(nil)
                                    }
                                }) {
                                    Image(systemName: "arrow.up.left.and.arrow.down.right")
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundColor(.white)
                                        .padding(10)
                                        .background(.ultraThinMaterial)
                                        .clipShape(Circle())
                                }
                                #endif
                                
                                Button(action: {
                                    withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) {
                                        showDiagnostics.toggle()
                                    }
                                }) {
                                    Image(systemName: showDiagnostics ? "chart.bar.xaxis" : "chart.bar")
                                        .font(.system(size: 16, weight: .semibold))
                                        .foregroundColor(.white)
                                        .padding(10)
                                        .background(.ultraThinMaterial)
                                        .clipShape(Circle())
                                }
                                
                                Button(action: {
                                    manager.disconnect()
                                    selectedSource = nil
                                }) {
                                    Text("Disconnect")
                                        .font(.subheadline)
                                        .fontWeight(.semibold)
                                        .foregroundColor(.white)
                                        .padding(.horizontal, 16)
                                        .padding(.vertical, 8)
                                        .background(Color.red.opacity(0.8))
                                        .cornerRadius(20)
                                }
                            }
                            .padding()
                        }
                        Spacer()
                    }
                } else {
                    // Empty/Idle State
                    VStack(spacing: 20) {
                        ZStack {
                            RoundedRectangle(cornerRadius: 20)
                                .fill(Color.blue.opacity(0.15))
                                .frame(width: 80, height: 80)
                            
                            Image(systemName: "video.fill")
                                .font(.system(size: 32))
                                .foregroundColor(.blue)
                        }
                        
                        Text(selectedSource == nil ? "Select an NDI source from the sidebar" : "Connecting to \(selectedSource!)...")
                            .font(.headline)
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 24)
                    }
                }
            }
            .ignoresSafeArea()
#if os(macOS)
            .toolbar(manager.isStreaming ? .hidden : .automatic, for: .windowToolbar)
#else
            .toolbar(manager.isStreaming ? .hidden : .automatic, for: .navigationBar)
#endif
        }
        .onChange(of: selectedSource) { newSource in
            if let src = newSource {
                manager.connect(to: src)
            } else {
                manager.disconnect()
            }
        }
        .onChange(of: manager.isStreaming) { isStreaming in
            #if os(macOS)
            withAnimation {
                columnVisibility = isStreaming ? .detailOnly : .all
            }
            #endif
        }
    }
}

// Glassmorphism Performance HUD
struct DiagnosticsHUD: View {
    var stats: NDIStats
    var sourceName: String
    
    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // Header
            Text("DIAGNOSTICS & SYSTEM HEALTH")
                .font(.caption2)
                .fontWeight(.bold)
                .foregroundColor(.white.opacity(0.9))
            
            Divider()
                .background(Color.white.opacity(0.2))
            
            // Source Info
            VStack(alignment: .leading, spacing: 4) {
                Text("STREAM SOURCE")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(.secondary)
                Text(sourceName)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundColor(.white)
                    .lineLimit(1)
            }
            
            // Network Stats
            VStack(alignment: .leading, spacing: 6) {
                Text("NETWORK TIME & LINK")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(.secondary)
                
                HStack(spacing: 8) {
                    Circle()
                        .fill(wifiColor)
                        .frame(width: 8, height: 8)
                    Text("Status: \(wifiStatus)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(wifiColor)
                }
                
                Text("• Net Jitter (Transit Var): \(String(format: "%.1f", stats.jitterMs)) ms")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.white)
                Text("• Capture Rate: \(String(format: "%.1f", stats.captureFps)) fps")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
            }
            
            // Engine Stats
            VStack(alignment: .leading, spacing: 6) {
                Text("RENDERING TIME & ENGINE")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundColor(.secondary)
                
                HStack(spacing: 8) {
                    Circle()
                        .fill(engineColor)
                        .frame(width: 8, height: 8)
                    Text("Status: \(engineStatus)")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundColor(engineColor)
                }
                
                Text("• Render Latency (GPU): \(String(format: "%.1f", stats.renderLatencyMs)) ms")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.white)
                Text("• Buffer Queue Depth: \(stats.queueDepth) frames")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                Text("• Dropped Packets: \(stats.droppedFrames)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
            }
        }
        .padding(16)
        .frame(width: 280)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.black.opacity(0.15))
                .background(.ultraThinMaterial.opacity(0.35))
        )
        .cornerRadius(12)
        .overlay(
            RoundedRectangle(cornerRadius: 12)
                .stroke(Color.blue.opacity(0.15), lineWidth: 1)
        )
        .shadow(color: Color.black.opacity(0.3), radius: 10, x: 0, y: 5)
        .padding()
        // Align to top-left corner
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }
    
    // Diagnostic logic properties
    private var wifiStatus: String {
        if stats.captureFps < 1.0 { return "Disconnected" }
        if stats.jitterMs > 15.0 { return "Poor (Jittery)" }
        return "Excellent"
    }
    
    private var wifiColor: Color {
        if stats.captureFps < 1.0 { return .gray }
        if stats.jitterMs > 15.0 { return .red }
        return .green
    }
    
    private var engineStatus: String {
        if stats.queueDepth > 3 { return "Busy (Queue clog)" }
        return "Healthy"
    }
    
    private var engineColor: Color {
        if stats.queueDepth > 3 { return .orange }
        return .green
    }
}

#if os(macOS)
import AppKit

struct WindowAccessor: NSViewRepresentable {
    var onChange: (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async {
            if let window = view.window {
                onChange(window)
            }
        }
        return view
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        if let window = nsView.window {
            onChange(window)
        }
    }
}
#endif
