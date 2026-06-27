#import "NDIEngineWrapper.h"
#include "NDIEngine.h"

@implementation NDIEngineWrapper {
    NDIEngine *m_engine;
    void (^m_discoveryCallback)(NSArray<NSString *> *);
    void (^m_videoCallback)(NSData *, NSInteger, NSInteger, NSInteger, int64_t, BOOL);
    void (^m_audioCallback)(NSData *, NSInteger, NSInteger, NSInteger, NSInteger);
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

- (BOOL)connectTo:(NSString *)sourceName {
    return m_engine->connectTo([sourceName UTF8String]);
}

- (void)disconnect {
    m_engine->disconnect();
}

- (void)startCaptureWithVideoCallback:(void (^)(NSData *, NSInteger, NSInteger, NSInteger, int64_t, BOOL))videoCallback
                        audioCallback:(void (^)(NSData *, NSInteger, NSInteger, NSInteger, NSInteger))audioCallback {
    m_videoCallback = [videoCallback copy];
    m_audioCallback = [audioCallback copy];
    
    void *selfPointer = (__bridge void *)self;
    m_engine->startCapture([](const uint8_t* data, int width, int height, int stride, int64_t timestampMs, bool isYUV, void* context) {
        NDIEngineWrapper *thisWrapper = (__bridge NDIEngineWrapper *)context;
        if (thisWrapper && thisWrapper->m_videoCallback) {
            NSInteger size = height * stride;
            NSData *frameData = [NSData dataWithBytesNoCopy:(void*)data length:size freeWhenDone:NO];
            thisWrapper->m_videoCallback(frameData, width, height, stride, timestampMs, isYUV);
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
