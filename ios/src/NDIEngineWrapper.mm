#import "NDIEngineWrapper.h"
#include "NDIEngine.h"
#include <mutex>

@implementation NDIEngineWrapper {
    NDIEngine *m_engine;
    void (^m_discoveryCallback)(NSArray<NSString *> *);
    void (^m_videoCallback)(NSInteger, NSInteger, NSInteger, int64_t, BOOL);
    void (^m_audioCallback)(NSData *, NSInteger, NSInteger, NSInteger, NSInteger);
    id<MTLTexture> m_targetTexture;
    std::mutex m_textureMutex;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        m_engine = new NDIEngine();
    }
    return self;
}

- (void)dealloc {
    delete m_engine;
}

- (void)startDiscoveryWithCallback:(void (^)(NSArray<NSString *> *))callback {
    m_discoveryCallback = [callback copy];
    
    void *selfPointer = (__bridge void *)self;
    m_engine->startDiscovery([](const char** sources, int count, void* context) {
        NDIEngineWrapper *thisWrapper = (__bridge NDIEngineWrapper *)context;
        if (thisWrapper && thisWrapper->m_discoveryCallback) {
            NSMutableArray<NSString *> *srcArray = [NSMutableArray arrayWithCapacity:count];
            for (int i = 0; i < count; ++i) {
                if (sources[i]) {
                    [srcArray addObject:[NSString stringWithUTF8String:sources[i]]];
                }
            }
            // Execute on main thread
            dispatch_async(dispatch_get_main_queue(), ^{
                thisWrapper->m_discoveryCallback(srcArray);
            });
        }
    }, selfPointer);
}

- (void)stopDiscovery {
    m_engine->stopDiscovery();
    m_discoveryCallback = nil;
}

- (BOOL)connectTo:(NSString *)sourceName preferredTransport:(NSString *)transport {
    return m_engine->connectTo([sourceName UTF8String], [transport UTF8String]);
}

- (void)disconnect {
    m_engine->disconnect();
}

- (void)setTargetTexture:(id<MTLTexture>)texture {
    std::lock_guard<std::mutex> lock(m_textureMutex);
    m_targetTexture = texture;
}

- (void)startCaptureWithVideoCallback:(void (^)(NSInteger, NSInteger, NSInteger, int64_t, BOOL))videoCallback
                        audioCallback:(void (^)(NSData *, NSInteger, NSInteger, NSInteger, NSInteger))audioCallback {
    m_videoCallback = [videoCallback copy];
    m_audioCallback = [audioCallback copy];
    
    void *selfPointer = (__bridge void *)self;
    m_engine->startCapture([](const uint8_t* data, int width, int height, int stride, int64_t timestampMs, bool isYUV, void* context) {
        NDIEngineWrapper *thisWrapper = (__bridge NDIEngineWrapper *)context;
        if (thisWrapper && thisWrapper->m_videoCallback) {
            // Upload directly to the registered Metal texture in the background NDI thread
            {
                std::lock_guard<std::mutex> lock(thisWrapper->m_textureMutex);
                id<MTLTexture> texture = thisWrapper->m_targetTexture;
                if (texture && [texture width] == width && [texture height] == height) {
                    MTLRegion region = MTLRegionMake2D(0, 0, width, height);
                    [texture replaceRegion:region
                               mipmapLevel:0
                                 withBytes:data
                               bytesPerRow:stride];
                }
            }
            thisWrapper->m_videoCallback(width, height, stride, timestampMs, isYUV);
        }
    }, [](const float* data, int samples, int channels, int sampleRate, int channelStrideBytes, void* context) {
        NDIEngineWrapper *thisWrapper = (__bridge NDIEngineWrapper *)context;
        if (thisWrapper && thisWrapper->m_audioCallback) {
            NSInteger size = channels * channelStrideBytes;
            NSData *audioData = [NSData dataWithBytes:(void*)data length:size];
            thisWrapper->m_audioCallback(audioData, samples, channels, sampleRate, channelStrideBytes);
        }
    }, selfPointer);
}

- (void)stopCapture {
    m_engine->stopCapture();
    m_videoCallback = nil;
    m_audioCallback = nil;
    {
        std::lock_guard<std::mutex> lock(m_textureMutex);
        m_targetTexture = nil;
    }
}

- (NSDictionary<NSString *, id> *)getPerformanceStats {
    NDIEngine::PerformanceStats stats = m_engine->getPerformanceStats();
    return @{
        @"captureFps": @(stats.captureFps),
        @"totalFrames": @(stats.totalFrames),
        @"droppedFrames": @(stats.droppedFrames),
        @"queueDepth": @(stats.queueDepth),
        @"jitterMs": @(stats.jitterMs),
        @"bitrateMBs": @(stats.bitrateMBs)
    };
}

@end
