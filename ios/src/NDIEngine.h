#pragma once

#include <cstdint>
#include <vector>
#include <string>
#include <mutex>
#include <thread>
#include <atomic>

// Forward-declare NDI types to avoid exposing NDI headers to Swift compilation unit directly
struct NDIlib_find_instance_type;
typedef struct NDIlib_find_instance_type* NDIlib_find_instance_t;

struct NDIlib_recv_instance_type;
typedef struct NDIlib_recv_instance_type* NDIlib_recv_instance_t;

class NDIEngine {
public:
    NDIEngine();
    ~NDIEngine();

    // Discovery API
    void startDiscovery(void (*sourcesCallback)(const char** sources, int count, void* context), void* context);
    void stopDiscovery();

    // Streaming API
    bool connectTo(const char* sourceName);
    void disconnect();

    // Capture API
    void startCapture(void (*videoCallback)(const uint8_t* data, int width, int height, int stride, int64_t timestampMs, void* context),
                      void (*audioCallback)(const int16_t* data, int samples, int channels, int sampleRate, void* context),
                      void* context);
    void stopCapture();

    // Diagnostics
    struct PerformanceStats {
        double captureFps;
        int64_t totalFrames;
        int64_t droppedFrames;
        int queueDepth;
        double jitterMs;
    };
    PerformanceStats getPerformanceStats();

private:
    void discoveryLoop();
    void captureLoop();

    NDIlib_find_instance_t m_pFinder;
    NDIlib_recv_instance_t m_pReceiver;

    std::atomic<bool> m_discoveryRunning;
    std::atomic<bool> m_captureRunning;

    std::thread m_discoveryThread;
    std::thread m_captureThread;

    std::mutex m_mutex;
    std::string m_connectedSource;

    // Callbacks
    void (*m_sourcesCallback)(const char** sources, int count, void* context);
    void* m_sourcesContext;

    void (*m_videoCallback)(const uint8_t* data, int width, int height, int stride, int64_t timestampMs, void* context);
    void (*m_audioCallback)(const int16_t* data, int samples, int channels, int sampleRate, void* context);
    void* m_captureContext;

    // Diagnostics metrics
    std::mutex m_statsMutex;
    PerformanceStats m_stats;
    int64_t m_lastFrameTime;
    std::vector<double> m_jitterHistory;
    double m_jitterSum;
};
