#import <AVFoundation/AVFoundation.h>
#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface LowLevelEffectProcessorObjC : NSObject

- (void)prepareWithSampleRate:(double)sampleRate
                 channelCount:(NSInteger)channelCount
            maximumFrameCount:(NSInteger)maximumFrameCount;

- (void)updateWithEffectTypes:(NSArray<NSNumber *> *)effectTypes
                      amounts:(NSArray<NSNumber *> *)amounts
                  parametersA:(NSArray<NSNumber *> *)parametersA
                  parametersB:(NSArray<NSNumber *> *)parametersB
                  parametersC:(NSArray<NSNumber *> *)parametersC
                       enabled:(NSArray<NSNumber *> *)enabled;

- (void)writeInputBuffer:(AVAudioPCMBuffer *)buffer;

- (void)renderFrameCount:(AVAudioFrameCount)frameCount
   outputAudioBufferList:(AudioBufferList *)audioBufferList;

- (void)reset;

@end

NS_ASSUME_NONNULL_END
