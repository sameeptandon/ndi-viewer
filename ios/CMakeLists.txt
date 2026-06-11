cmake_minimum_required(VERSION 3.20)
project(ndi_viewer_ios LANGUAGES CXX Swift)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)

# Configure target source files
add_executable(ndi_viewer_ios MACOSX_BUNDLE
    src/NDIViewerApp.swift
    src/MainDashboard.swift
    src/SidebarView.swift
    src/NDIConnectionManager.swift
    src/NDIAudioPlayer.swift
    src/MetalVideoView.swift
    src/MetalVideoView.metal
    src/NDIEngine.h
    src/NDIEngine.cpp
    src/NDIEngineWrapper.h
    src/NDIEngineWrapper.mm
)

# Specify Include Directories for C++ compiler
target_include_directories(ndi_viewer_ios PRIVATE
    ${CMAKE_CURRENT_SOURCE_DIR}/include
)

# Link common core frameworks
target_link_libraries(ndi_viewer_ios PRIVATE
    "-framework Foundation"
    "-framework AVFoundation"
    "-framework Metal"
    "-framework MetalKit"
    "-framework CoreGraphics"
    "-framework CoreVideo"
    "-framework VideoToolbox"
)

# Link platform-specific UI frameworks
if(CMAKE_SYSTEM_NAME STREQUAL "iOS" OR CMAKE_SYSTEM_NAME STREQUAL "visionOS")
    target_link_libraries(ndi_viewer_ios PRIVATE
        "-framework UIKit"
    )
else() # macOS
    target_link_libraries(ndi_viewer_ios PRIVATE
        "-framework AppKit"
    )
endif()

# Link appropriate NDI library depending on targeted platform SDK
if(CMAKE_SYSTEM_NAME STREQUAL "visionOS")
    target_link_libraries(ndi_viewer_ios PRIVATE
        ${CMAKE_CURRENT_SOURCE_DIR}/libs/libndi_visionos.a
    )
    set_target_properties(ndi_viewer_ios PROPERTIES
        XCODE_ATTRIBUTE_TARGETED_DEVICE_FAMILY "7" # Apple Vision
        XCODE_ATTRIBUTE_SUPPORTED_PLATFORMS "xros xrsimulator"
    )
elseif(CMAKE_SYSTEM_NAME STREQUAL "iOS")
    target_link_libraries(ndi_viewer_ios PRIVATE
        ${CMAKE_CURRENT_SOURCE_DIR}/libs/libndi_ios.a
    )
    set_target_properties(ndi_viewer_ios PROPERTIES
        XCODE_ATTRIBUTE_TARGETED_DEVICE_FAMILY "1,2" # iPhone, iPad
        XCODE_ATTRIBUTE_SUPPORTED_PLATFORMS "iphoneos iphonesimulator"
    )
else() # macOS
    target_link_libraries(ndi_viewer_ios PRIVATE
        ${CMAKE_CURRENT_SOURCE_DIR}/libs/libndi.dylib
    )
    # Set run path so the compiled macOS binary can find the dynamic library inside its bundle
    set_target_properties(ndi_viewer_ios PROPERTIES
        BUILD_RPATH "@executable_path/../Frameworks"
        INSTALL_RPATH "@executable_path/../Frameworks"
    )
    # Copy libndi.dylib to the Frameworks folder next to the binary post-build
    add_custom_command(TARGET ndi_viewer_ios POST_BUILD
        COMMAND ${CMAKE_COMMAND} -E make_directory $<TARGET_BUNDLE_CONTENT_DIR:ndi_viewer_ios>/Frameworks
        COMMAND ${CMAKE_COMMAND} -E copy_if_different
        "${CMAKE_CURRENT_SOURCE_DIR}/libs/libndi.dylib"
        $<TARGET_BUNDLE_CONTENT_DIR:ndi_viewer_ios>/Frameworks/libndi.dylib
    )
endif()

# Configure Xcode targets and build settings
set_target_properties(ndi_viewer_ios PROPERTIES
    MACOSX_BUNDLE_INFO_PLIST ${CMAKE_CURRENT_SOURCE_DIR}/Info.plist
    XCODE_ATTRIBUTE_PRODUCT_BUNDLE_IDENTIFIER "com.ndi-viewer.ios"
    XCODE_ATTRIBUTE_SWIFT_COMPILER_CXX_INTEROPERABILITY "default"
    XCODE_ATTRIBUTE_SWIFT_OBJC_BRIDGING_HEADER "${CMAKE_CURRENT_SOURCE_DIR}/src/BridgingHeader.h"
    XCODE_ATTRIBUTE_IPHONEOS_DEPLOYMENT_TARGET "16.0"
    XCODE_ATTRIBUTE_SWIFT_VERSION "5.0"
    "XCODE_ATTRIBUTE_EXCLUDED_ARCHS[sdk=iphonesimulator*]" "arm64"
)
