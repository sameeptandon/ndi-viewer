# NDI Network Viewer & Tools

A native codebase featuring NDI (Network Device Interface) tools including a Python virtual sender, a PySide6 Python viewer, and a native SwiftUI/Metal iOS/macOS viewer.

---

## Directory Structure

- [viewer.py](file:///Users/sameep/code/ndi_viewer/viewer.py): Python PySide6 desktop NDI viewer application.
- [virtual_sender.py](file:///Users/sameep/code/ndi_viewer/virtual_sender.py): Python helper script to broadcast a virtual NDI test pattern.
- [ios/](file:///Users/sameep/code/ndi_viewer/ios): Native SwiftUI, Metal, and Objective-C++ bridging application targeting iOS, visionOS, and macOS.
  - [ios/src/MainDashboard.swift](file:///Users/sameep/code/ndi_viewer/ios/src/MainDashboard.swift): Main dashboard dashboard container.
  - [ios/src/MetalVideoView.swift](file:///Users/sameep/code/ndi_viewer/ios/src/MetalVideoView.swift): Metal-backed video presentation view.
  - [ios/src/NDIEngine.cpp](file:///Users/sameep/code/ndi_viewer/ios/src/NDIEngine.cpp): C++ wrapper for the NDI SDK library.

---

## Python Tools

All dependencies are preconfigured in your conda environment.

### 1. Start a Virtual Stream (Optional)
If you do not have physical NDI devices on your local network, launch the virtual sender to broadcast a test stream:
```bash
conda run -n pygame_playground python virtual_sender.py
```
This stream bounces a red/white box over a dynamically changing gradient and is broadcast as `"Python Virtual Test Stream"`.

### 2. Run the PySide6 Desktop Viewer
Launch the PySide6 desktop client to discover and stream NDI sources:
```bash
conda run -n pygame_playground python viewer.py
```

---

## iOS / macOS Swift App (SwiftUI & Metal)

The iOS application is located in the [ios/](file:///Users/sameep/code/ndi_viewer/ios) directory and can be opened/configured via Xcode or CMake.

### Setup and Build
To configure the native Swift app for iOS or macOS:
```bash
mkdir -p build_ios && cd build_ios
# For macOS build
conda run -n pygame_playground cmake -G Xcode ../ios
# For iOS device build
conda run -n pygame_playground cmake -G Xcode -DCMAKE_SYSTEM_NAME=iOS ../ios
```
Then, open the generated Xcode project in Xcode.

---

## Agent Guidelines
AI Coding Agents working on this repository should review the [AGENTS.md](file:///Users/sameep/code/ndi_viewer/AGENTS.md) guide for environment setup, architecture maps, and git limits.

