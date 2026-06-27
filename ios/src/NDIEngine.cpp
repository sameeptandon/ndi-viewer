#include "NDIEngine.h"
#include <Processing.NDI.Lib.h>
#include <chrono>
#include <cmath>
#include <algorithm>

inline int64_t getCurrentTimeMs() {
    auto now = std::chrono::system_clock::now();
    return std::chrono::duration_cast<std::chrono::milliseconds>(now.time_since_epoch()).count();
}

NDIEngine::NDIEngine()
    : m_pFinder(nullptr)
    , m_pReceiver(nullptr)
    , m_discoveryRunning(false)
    , m_captureRunning(false)
    , m_sourcesCallback(nullptr)
    , m_sourcesContext(nullptr)
    , m_videoCallback(nullptr)
    , m_audioCallback(nullptr)
    , m_captureContext(nullptr)
    , m_lastFrameTime(0)
    , m_jitterSum(0.0)
{
    m_stats = {0.0, 0, 0, 0, 0.0};
}

NDIEngine::~NDIEngine() {
    stopCapture();
    stopDiscovery();
    disconnect();
}

void NDIEngine::startDiscovery(void (*sourcesCallback)(const char** sources, int count, void* context), void* context) {
    if (m_discoveryRunning) return;

    m_sourcesCallback = sourcesCallback;
    m_sourcesContext = context;
    m_discoveryRunning = true;

    NDIlib_find_create_t findSettings;
    findSettings.show_local_sources = true;
    findSettings.p_groups = nullptr;
    findSettings.p_extra_ips = nullptr;

    m_pFinder = NDIlib_find_create_v2(&findSettings);
    m_discoveryThread = std::thread(&NDIEngine::discoveryLoop, this);
}

void NDIEngine::stopDiscovery() {
    m_discoveryRunning = false;
    if (m_discoveryThread.joinable()) {
        m_discoveryThread.join();
    }
    if (m_pFinder) {
        NDIlib_find_destroy(m_pFinder);
        m_pFinder = nullptr;
    }
}

void NDIEngine::discoveryLoop() {
    std::vector<std::string> knownSources;

    while (m_discoveryRunning) {
        if (!m_pFinder) {
            std::this_thread::sleep_for(std::chrono::milliseconds(500));
            continue;
        }

        uint32_t numSources = 0;
        const NDIlib_source_t* pSources = NDIlib_find_get_current_sources(m_pFinder, &numSources);

        std::vector<std::string> currentSources;
        std::vector<const char*> cStrings;
        for (uint32_t i = 0; i < numSources; ++i) {
            if (pSources[i].p_ndi_name) {
                currentSources.push_back(pSources[i].p_ndi_name);
            }
        }

        // Trigger callback if list of sources changed
        if (currentSources != knownSources) {
            knownSources = currentSources;
            for (const auto& src : knownSources) {
                cStrings.push_back(src.c_str());
            }
            if (m_sourcesCallback) {
                m_sourcesCallback(cStrings.data(), static_cast<int>(cStrings.size()), m_sourcesContext);
            }
        }

        std::this_thread::sleep_for(std::chrono::milliseconds(1500));
    }
}

bool NDIEngine::connectTo(const char* sourceName) {
    std::lock_guard<std::mutex> lock(m_mutex);
    
    // Disconnect old receiver
    disconnect();

    NDIlib_recv_create_v3_t recvSettings;
    recvSettings.source_to_connect_to.p_ndi_name = nullptr; // Connect manually below
    recvSettings.color_format = NDIlib_recv_color_format_UYVY_BGRA; // Prefer native UYVY, fallback to BGRA
    recvSettings.bandwidth = NDIlib_recv_bandwidth_highest;
    recvSettings.allow_video_fields = false;
    recvSettings.p_ndi_recv_name = "iOS NDI Viewer Receiver";

    m_pReceiver = NDIlib_recv_create_v3(&recvSettings);
    if (!m_pReceiver) return false;

    // Negotiate low-latency Multi-TCP transport (highly optimized for mesh WiFi)
    NDIlib_metadata_frame_t transportMetadata;
    transportMetadata.p_data = (char*)"<ndi_transport preferred=\"multi-tcp\"/>";
    NDIlib_recv_add_connection_metadata(m_pReceiver, &transportMetadata);

    // Resolve target source pointer
    uint32_t numSources = 0;
    const NDIlib_source_t* pSources = NDIlib_find_get_current_sources(m_pFinder, &numSources);
    const NDIlib_source_t* pTarget = nullptr;

    for (uint32_t i = 0; i < numSources; ++i) {
        if (pSources[i].p_ndi_name && std::string(pSources[i].p_ndi_name) == sourceName) {
            pTarget = &pSources[i];
            break;
        }
    }

    if (pTarget) {
        NDIlib_recv_connect(m_pReceiver, pTarget);
        m_connectedSource = sourceName;
        return true;
    }

    return false;
}

void NDIEngine::disconnect() {
    if (m_pReceiver) {
        NDIlib_recv_connect(m_pReceiver, nullptr);
        NDIlib_recv_destroy(m_pReceiver);
        m_pReceiver = nullptr;
    }
    m_connectedSource.clear();

    // Reset stats
    std::lock_guard<std::mutex> statsLock(m_statsMutex);
    m_stats = {0.0, 0, 0, 0, 0.0};
    m_lastFrameTime = 0;
    m_jitterHistory.clear();
    m_jitterSum = 0.0;
}

void NDIEngine::startCapture(void (*videoCallback)(const uint8_t* data, int width, int height, int stride, int64_t timestampMs, bool isYUV, void* context),
                             void (*audioCallback)(const float* data, int samples, int channels, int sampleRate, int channelStrideBytes, void* context),
                             void* context) {
    if (m_captureRunning) return;

    m_videoCallback = videoCallback;
    m_audioCallback = audioCallback;
    m_captureContext = context;
    m_captureRunning = true;

    m_captureThread = std::thread(&NDIEngine::captureLoop, this);
}

void NDIEngine::stopCapture() {
    m_captureRunning = false;
    if (m_captureThread.joinable()) {
        m_captureThread.join();
    }
}

void NDIEngine::captureLoop() {
    std::vector<int64_t> arrivalTimestamps;
    int64_t lastStatsTime = getCurrentTimeMs();
    uint64_t intervalBytes = 0;
    double sourceFps = 0.0;

    while (m_captureRunning) {
        NDIlib_recv_instance_t pRecv = nullptr;
        {
            std::lock_guard<std::mutex> lock(m_mutex);
            pRecv = m_pReceiver;
        }

        if (!pRecv) {
            std::this_thread::sleep_for(std::chrono::milliseconds(10));
            continue;
        }

        NDIlib_video_frame_v2_t videoFrame;
        NDIlib_audio_frame_v3_t audioFrame;
        NDIlib_metadata_frame_t metadataFrame;

        // Block for up to 8ms waiting for next frame, avoiding busy polling
        NDIlib_frame_type_e type = NDIlib_recv_capture_v3(pRecv, &videoFrame, &audioFrame, &metadataFrame, 8);

        bool frameProcessed = false;

        if (type == NDIlib_frame_type_video) {
            frameProcessed = true;
            intervalBytes += videoFrame.line_stride_in_bytes * videoFrame.yres;
            
            // Flush any newer frames in NDI's receiver queue to stay in sync with the live feed
            NDIlib_video_frame_v2_t nextVideoFrame;
            NDIlib_audio_frame_v3_t nextAudioFrame;
            NDIlib_metadata_frame_t nextMetadataFrame;
            
            while (true) {
                NDIlib_frame_type_e nextType = NDIlib_recv_capture_v3(pRecv, &nextVideoFrame, &nextAudioFrame, &nextMetadataFrame, 0);
                if (nextType == NDIlib_frame_type_none) {
                    break;
                }
                
                if (nextType == NDIlib_frame_type_video) {
                    intervalBytes += nextVideoFrame.line_stride_in_bytes * nextVideoFrame.yres;
                    NDIlib_recv_free_video_v2(pRecv, &videoFrame);
                    videoFrame = nextVideoFrame;
                }
                else if (nextType == NDIlib_frame_type_audio) {
                    intervalBytes += nextAudioFrame.no_samples * nextAudioFrame.no_channels * sizeof(float);
                    // Do NOT drop audio frames to prevent crackling/stuttering
                    int sampleRate = nextAudioFrame.sample_rate;
                    int channels = nextAudioFrame.no_channels;
                    int samples = nextAudioFrame.no_samples;
                    if (samples > 0 && channels > 0 && m_audioCallback) {
                        m_audioCallback(
                            reinterpret_cast<const float*>(nextAudioFrame.p_data),
                            samples,
                            channels,
                            sampleRate,
                            nextAudioFrame.channel_stride_in_bytes,
                            m_captureContext
                        );
                    }
                    NDIlib_recv_free_audio_v3(pRecv, &nextAudioFrame);
                }
                else if (nextType == NDIlib_frame_type_metadata) {
                    NDIlib_recv_free_metadata(pRecv, &nextMetadataFrame);
                }
            }
            
            int64_t nowMs = getCurrentTimeMs();

            if (videoFrame.frame_rate_D > 0) {
                sourceFps = (double)videoFrame.frame_rate_N / videoFrame.frame_rate_D;
            }

            // Calculate network arrival jitter
            if (m_lastFrameTime > 0) {
                double expectedDelta = (sourceFps > 0.0) ? (1000.0 / sourceFps) : 33.3;
                double actualDelta = nowMs - m_lastFrameTime;
                double jitter = std::abs(actualDelta - expectedDelta);

                std::lock_guard<std::mutex> statsLock(m_statsMutex);
                m_jitterSum += jitter;
                m_jitterHistory.push_back(jitter);
                if (m_jitterHistory.size() > 30) {
                    m_jitterSum -= m_jitterHistory.front();
                    m_jitterHistory.erase(m_jitterHistory.begin());
                }
            }
            m_lastFrameTime = nowMs;

            arrivalTimestamps.push_back(nowMs);
            while (!arrivalTimestamps.empty() && nowMs - arrivalTimestamps.front() > 1000) {
                arrivalTimestamps.erase(arrivalTimestamps.begin());
            }

            // Fire Swift video callback
            if (videoFrame.p_data && m_videoCallback) {
                bool isYUV = (videoFrame.FourCC == NDIlib_FourCC_type_UYVY);
                m_videoCallback(videoFrame.p_data, videoFrame.xres, videoFrame.yres, videoFrame.line_stride_in_bytes, nowMs, isYUV, m_captureContext);
            }

            NDIlib_recv_free_video_v2(pRecv, &videoFrame);
        }
        else if (type == NDIlib_frame_type_audio) {
            frameProcessed = true;
            intervalBytes += audioFrame.no_samples * audioFrame.no_channels * sizeof(float);
            int sampleRate = audioFrame.sample_rate;
            int channels = audioFrame.no_channels;
            int samples = audioFrame.no_samples;

            if (samples > 0 && channels > 0 && audioFrame.p_data && m_audioCallback) {
                m_audioCallback(
                    reinterpret_cast<const float*>(audioFrame.p_data),
                    samples,
                    channels,
                    sampleRate,
                    audioFrame.channel_stride_in_bytes,
                    m_captureContext
                );
            }

            NDIlib_recv_free_audio_v3(pRecv, &audioFrame);
        }
        else if (type == NDIlib_frame_type_metadata) {
            frameProcessed = true;
            NDIlib_recv_free_metadata(pRecv, &metadataFrame);
        }

        // Periodic stats calculation (every 500ms)
        int64_t now = getCurrentTimeMs();
        if (now - lastStatsTime > 500) {
            double captureFps = 0.0;
            if (arrivalTimestamps.size() > 1) {
                double fpsDur = (arrivalTimestamps.back() - arrivalTimestamps.front()) / 1000.0;
                if (fpsDur > 0.0) {
                    captureFps = (arrivalTimestamps.size() - 1) / fpsDur;
                }
            }

            NDIlib_recv_performance_t total;
            NDIlib_recv_performance_t dropped;
            NDIlib_recv_queue_t queue;

            NDIlib_recv_get_performance(pRecv, &total, &dropped);
            NDIlib_recv_get_queue(pRecv, &queue);

            std::lock_guard<std::mutex> statsLock(m_statsMutex);
            double avgJitter = m_jitterHistory.empty() ? 0.0 : (m_jitterSum / m_jitterHistory.size());
            double dur = (now - lastStatsTime) / 1000.0;
            double bitrateMBs = 0.0;
            if (dur > 0.0) {
                bitrateMBs = (double)intervalBytes / dur / (1024.0 * 1024.0);
            }
            intervalBytes = 0; // Reset for next interval

            m_stats = {
                captureFps,
                total.video_frames,
                dropped.video_frames,
                queue.video_frames,
                avgJitter,
                bitrateMBs
            };

            lastStatsTime = now;
        }

        if (!frameProcessed) {
            std::this_thread::sleep_for(std::chrono::milliseconds(4));
        }
    }
}

NDIEngine::PerformanceStats NDIEngine::getPerformanceStats() {
    std::lock_guard<std::mutex> statsLock(m_statsMutex);
    return m_stats;
}
