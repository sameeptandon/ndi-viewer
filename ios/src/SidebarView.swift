import SwiftUI

struct SidebarView: View {
    @ObservedObject var manager: NDIConnectionManager
    @Binding var selectedSource: String?
    
    var body: some View {
        List(selection: $selectedSource) {
            Section {
                if manager.sources.isEmpty {
                    HStack(spacing: 12) {
                        ProgressView()
                            .tint(.blue)
                        Text("Searching network...")
                            .foregroundColor(.secondary)
                            .font(.subheadline)
                    }
                    .padding(.vertical, 8)
                } else {
                    ForEach(manager.sources, id: \.self) { source in
                        HStack {
                            Image(systemName: "video.fill")
                                .foregroundColor(selectedSource == source ? .white : .blue)
                            Text(source)
                                .font(.body)
                                .lineLimit(1)
                            Spacer()
                            if selectedSource == source {
                                Image(systemName: "checkmark")
                                    .foregroundColor(.white)
                            }
                        }
                        .padding(.vertical, 4)
                        .tag(source)
                    }
                }
            } header: {
                Text("NDI Sources")
                    .font(.footnote)
                    .fontWeight(.bold)
                    .foregroundColor(.secondary)
            }
            
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Picker("Transport", selection: Binding(
                        get: { manager.preferredTransport },
                        set: { newTransport in
                            manager.updateTransport(newTransport)
                        }
                    )) {
                        Text("Multi-TCP").tag("multi-tcp")
                        Text("Reliable UDP").tag("udp")
                        Text("Single TCP").tag("tcp")
                    }
                    .pickerStyle(.segmented)
                    
                    Text("Multi-TCP is best for congested WiFi. Reliable UDP yields lower latency on high-quality networks.")
                        .font(.system(size: 9))
                        .foregroundColor(.secondary)
                        .lineLimit(nil)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.vertical, 6)
            } header: {
                Text("Connection Settings")
                    .font(.footnote)
                    .fontWeight(.bold)
                    .foregroundColor(.secondary)
            }
        }
        .listStyle(.sidebar)
    }
}
