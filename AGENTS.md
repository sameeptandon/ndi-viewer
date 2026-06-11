# Agent Developer Onboarding & Guidelines (`AGENTS.md`)

This document provides technical context, environment configurations, and workflow guidelines for AI coding agents working on the `ndi-viewer` repository.

---

## 1. Architecture Overview

This repository has two primary components:
1. **Python NDI Utilities**:
   - [viewer.py](file:///Users/sameep/code/ndi_viewer/viewer.py): A desktop NDI receiver built using **PySide6** and `cyndilib`.
   - [virtual_sender.py](file:///Users/sameep/code/ndi_viewer/virtual_sender.py): A broadcasting test stream generator using `cyndilib`.
2. **SwiftUI / Metal iOS, visionOS, and macOS App**:
   - Located in the [ios/](file:///Users/sameep/code/ndi_viewer/ios) directory.
   - Utilizes Swift-C++ interoperability and a bridging header ([BridgingHeader.h](file:///Users/sameep/code/ndi_viewer/ios/src/BridgingHeader.h)) to call the NDI C/C++ SDK wrapper ([NDIEngine.cpp](file:///Users/sameep/code/ndi_viewer/ios/src/NDIEngine.cpp)).
   - Renders video frames with zero-copy efficiency via Metal ([MetalVideoView.swift](file:///Users/sameep/code/ndi_viewer/ios/src/MetalVideoView.swift) and [MetalVideoView.metal](file:///Users/sameep/code/ndi_viewer/ios/src/MetalVideoView.metal)).

---

## 2. Environment & Tooling

- **Conda Environment**: `pygame_playground`
  - Used to manage dependencies, run Python programs, and provide system utility runtimes (such as Qt6 paths, CMake, etc.).
- **Python Execution**:
  - Always run using the `pygame_playground` environment:
    ```bash
    conda run -n pygame_playground python viewer.py
    ```
- **CMake & Build Tools**:
  - Build processes (especially for the Swift application targets) should be configured under this Conda prefix to resolve dynamic library headers or generator definitions.

---

## 3. Libraries & Dependency Constraints

- **Local NDI Libraries**:
  - Headers are stored in [ios/include/](file:///Users/sameep/code/ndi_viewer/ios/include).
  - Platform-specific binaries reside in [ios/libs/](file:///Users/sameep/code/ndi_viewer/ios/libs):
    - `libndi.dylib` (macOS dynamic library)
    - `libndi_ios.a` (iOS static library)
    - `libndi_visionos.a` (visionOS static library)
- **Git Limits & Size Warning**:
  - The static libraries `libndi_ios.a` (268MB) and `libndi_visionos.a` (270MB) exceed GitHub's 100MB upload limit.
  - **CRITICAL**: Do not remove these from [.gitignore](file:///Users/sameep/code/ndi_viewer/.gitignore) or attempt to stage them into Git without LFS, as it will break push operations.

---

## 4. SwiftUI & C++ Interoperability Details

- **Bridge Interface**:
  - [NDIEngineWrapper.mm](file:///Users/sameep/code/ndi_viewer/ios/src/NDIEngineWrapper.mm) exposes an Objective-C++ bridging class `NDIEngineWrapper` to coordinate between SwiftUI views and [NDIEngine.cpp](file:///Users/sameep/code/ndi_viewer/ios/src/NDIEngine.cpp).
- **Target Settings**:
  - The iOS project specifies:
    ```cmake
    XCODE_ATTRIBUTE_SWIFT_COMPILER_CXX_INTEROPERABILITY "default"
    XCODE_ATTRIBUTE_SWIFT_OBJC_BRIDGING_HEADER "${CMAKE_CURRENT_SOURCE_DIR}/src/BridgingHeader.h"
    ```
  - When editing the C++ side ([NDIEngine.h](file:///Users/sameep/code/ndi_viewer/ios/src/NDIEngine.h) / [NDIEngine.cpp](file:///Users/sameep/code/ndi_viewer/ios/src/NDIEngine.cpp)), update `NDIEngineWrapper` as necessary so SwiftUI views can access modified methods.
