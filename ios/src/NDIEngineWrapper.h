#import <Foundation/Foundation.h>
#import <Metal/Metal.h>

@interface NDIEngineWrapper : NSObject

- (void)startDiscoveryWithCallback:(void (^)(NSArray<NSString *> *sources))callback;
- (void)stopDiscovery;

- (BOOL)connectTo:(NSString *)sourceName preferredTransport:(NSString *)transport;
- (void)disconnect;

- (void)setTargetTexture:(id<MTLTexture>)texture;

- (void)startCaptureWithVideoCallback:(void (^)(NSInteger width, NSInteger height, NSInteger stride, int64_t timestampMs, BOOL isYUV))videoCallback
                        audioCallback:(void (^)(NSData *data, NSInteger samples, NSInteger channels, NSInteger sampleRate, NSInteger channelStrideBytes))audioCallback;
- (void)stopCapture;

- (NSDictionary<NSString *, id> *)getPerformanceStats;

@end
