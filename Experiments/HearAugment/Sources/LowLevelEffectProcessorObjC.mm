#import "LowLevelEffectProcessorObjC.h"
#import "LowLevelEffectEngine.hpp"

#include <algorithm>
#include <memory>
#include <vector>

@implementation LowLevelEffectProcessorObjC {
  std::unique_ptr<HearAugmentDSP::LowLevelEffectEngine> _engine;
}

- (instancetype)init {
  self = [super init];
  if (self) {
    _engine = std::make_unique<HearAugmentDSP::LowLevelEffectEngine>();
  }
  return self;
}

- (void)prepareWithSampleRate:(double)sampleRate
                 channelCount:(NSInteger)channelCount
            maximumFrameCount:(NSInteger)maximumFrameCount {
  _engine->prepare(sampleRate, static_cast<int>(channelCount), static_cast<int>(maximumFrameCount));
}

- (void)updateWithEffectTypes:(NSArray<NSNumber *> *)effectTypes
                      amounts:(NSArray<NSNumber *> *)amounts
                  parametersA:(NSArray<NSNumber *> *)parametersA
                  parametersB:(NSArray<NSNumber *> *)parametersB
                  parametersC:(NSArray<NSNumber *> *)parametersC
                       enabled:(NSArray<NSNumber *> *)enabled {
  const NSUInteger count = std::min({
    effectTypes.count,
    amounts.count,
    parametersA.count,
    parametersB.count,
    parametersC.count,
    enabled.count,
  });

  std::vector<HearAugmentDSP::EffectDescriptor> chain;
  chain.reserve(count);

  for (NSUInteger index = 0; index < count; ++index) {
    HearAugmentDSP::EffectDescriptor descriptor;
    descriptor.type = effectTypes[index].intValue;
    descriptor.amount = amounts[index].floatValue;
    descriptor.parameterA = parametersA[index].floatValue;
    descriptor.parameterB = parametersB[index].floatValue;
    descriptor.parameterC = parametersC[index].floatValue;
    descriptor.enabled = enabled[index].boolValue;
    chain.push_back(descriptor);
  }

  _engine->updateChain(chain);
}

- (void)writeInputBuffer:(AVAudioPCMBuffer *)buffer {
  float * const *channels = buffer.floatChannelData;
  if (channels == nullptr) {
    return;
  }

  _engine->writeInput(
    reinterpret_cast<const float * const *>(channels),
    static_cast<int>(buffer.format.channelCount),
    static_cast<int>(buffer.frameLength)
  );
}

- (void)renderFrameCount:(AVAudioFrameCount)frameCount
   outputAudioBufferList:(AudioBufferList *)audioBufferList {
  _engine->render(static_cast<int>(frameCount), audioBufferList);
}

- (void)reset {
  _engine->reset();
}

@end
