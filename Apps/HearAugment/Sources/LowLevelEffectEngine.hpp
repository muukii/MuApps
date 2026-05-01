#pragma once

#include <AudioToolbox/AudioToolbox.h>

#include <memory>
#include <vector>

namespace HearAugmentDSP {

struct EffectDescriptor {
  int type = 0;
  float amount = 0.0f;
  float parameterA = 0.0f;
  float parameterB = 0.0f;
  float parameterC = 0.5f;
  bool enabled = true;
};

class LowLevelEffectEngine {
public:
  LowLevelEffectEngine();
  ~LowLevelEffectEngine();

  LowLevelEffectEngine(const LowLevelEffectEngine &) = delete;
  LowLevelEffectEngine &operator=(const LowLevelEffectEngine &) = delete;

  void prepare(double sampleRate, int channelCount, int maximumFrameCount);
  void updateChain(const std::vector<EffectDescriptor> &chain);
  void writeInput(const float * const *channels, int sourceChannelCount, int frameCount);
  void render(int frameCount, AudioBufferList *outputAudioBufferList);
  void reset();

private:
  struct Impl;
  std::unique_ptr<Impl> impl;
};

}
