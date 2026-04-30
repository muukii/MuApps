#include "LowLevelEffectEngine.hpp"

#include <algorithm>
#include <atomic>
#include <cmath>
#include <memory>
#include <vector>

namespace HearAugmentDSP {
namespace {

constexpr float pi = 3.14159265358979323846f;
constexpr int maximumEffectSlots = 24;

enum EffectType {
  effectHighPass = 1,
  effectLowPass = 2,
  effectTiltEQ = 3,
  effectPresenceEQ = 4,
  effectCompressor = 5,
  effectNoiseGate = 6,
  effectSoftClip = 7,
  effectWaveFolder = 8,
  effectBitCrusher = 9,
  effectTremolo = 10,
  effectRingMod = 11,
  effectPanner = 12,
  effectAutoPan = 13,
  effectVibrato = 14,
  effectChorus = 15,
  effectFlanger = 16,
  effectPhaser = 17,
  effectSlapDelay = 18,
  effectAcceleratingDelay = 19,
  effectPingPongDelay = 20,
  effectReverse = 21,
  effectRoomReverb = 22,
  effectStereoReverb = 23,
  effectShimmer = 24,
  effectCombResonator = 25,
  effectSpaceWidener = 26,
  effectLongBloom = 27,
  effectConvergingBloom = 28,
  effectTapeRiserDelay = 29,
};

float clampFloat(float value, float lower, float upper) {
  return std::min(std::max(value, lower), upper);
}

float normalized(float value) {
  return clampFloat(value, 0.0f, 1.0f);
}

float lerp(float lower, float upper, float amount) {
  return lower + ((upper - lower) * amount);
}

float expMap(float lower, float upper, float amount) {
  return lower * std::pow(upper / lower, normalized(amount));
}

float dbToAmplitude(float db) {
  return std::pow(10.0f, db / 20.0f);
}

float amplitudeToDB(float amplitude) {
  return 20.0f * std::log10(std::max(amplitude, 0.000001f));
}

float smoothingCoefficient(float time, float sampleRate) {
  return std::exp(-1.0f / (std::max(time, 0.0001f) * sampleRate));
}

float mix(float dry, float wet, float amount) {
  const float clamped = normalized(amount);
  return (dry * (1.0f - clamped)) + (wet * clamped);
}

void advancePhase(float &phase, float frequency, float sampleRate) {
  phase += (2.0f * pi * std::max(frequency, 0.0f)) / sampleRate;
  if (phase >= 2.0f * pi) {
    phase -= 2.0f * pi;
  }
}

float softLimit(float sample) {
  const float x = clampFloat(sample, -3.0f, 3.0f);
  return x * (27.0f + (x * x)) / (27.0f + (9.0f * x * x));
}

float folded(float sample) {
  float wrapped = std::fmod(sample + 1.0f, 4.0f);
  if (wrapped < 0.0f) {
    wrapped += 4.0f;
  }
  return wrapped < 2.0f ? wrapped - 1.0f : 3.0f - wrapped;
}

float firstOrderAllPassCoefficient(float frequency, float sampleRate) {
  const float clamped = clampFloat(frequency, 20.0f, sampleRate * 0.45f);
  const float tangent = std::tan(pi * clamped / sampleRate);
  return (1.0f - tangent) / (1.0f + tangent);
}

struct BiquadCoefficients {
  float b0 = 1.0f;
  float b1 = 0.0f;
  float b2 = 0.0f;
  float a1 = 0.0f;
  float a2 = 0.0f;

  static float clampedFrequency(float frequency, float sampleRate) {
    return clampFloat(frequency, 20.0f, std::max(sampleRate * 0.49f, 21.0f));
  }

  static BiquadCoefficients normalize(float b0, float b1, float b2, float a0, float a1, float a2) {
    const float divisor = std::abs(a0) < 0.000001f ? 1.0f : a0;
    return {b0 / divisor, b1 / divisor, b2 / divisor, a1 / divisor, a2 / divisor};
  }

  static BiquadCoefficients highPass(float sampleRate, float frequency, float q) {
    frequency = clampedFrequency(frequency, sampleRate);
    const float omega = 2.0f * pi * frequency / sampleRate;
    const float cosine = std::cos(omega);
    const float alpha = std::sin(omega) / (2.0f * std::max(q, 0.001f));
    return normalize(
      (1.0f + cosine) / 2.0f,
      -(1.0f + cosine),
      (1.0f + cosine) / 2.0f,
      1.0f + alpha,
      -2.0f * cosine,
      1.0f - alpha
    );
  }

  static BiquadCoefficients lowPass(float sampleRate, float frequency, float q) {
    frequency = clampedFrequency(frequency, sampleRate);
    const float omega = 2.0f * pi * frequency / sampleRate;
    const float cosine = std::cos(omega);
    const float alpha = std::sin(omega) / (2.0f * std::max(q, 0.001f));
    return normalize(
      (1.0f - cosine) / 2.0f,
      1.0f - cosine,
      (1.0f - cosine) / 2.0f,
      1.0f + alpha,
      -2.0f * cosine,
      1.0f - alpha
    );
  }

  static BiquadCoefficients peak(float sampleRate, float frequency, float q, float gainDB) {
    frequency = clampedFrequency(frequency, sampleRate);
    const float amp = std::pow(10.0f, gainDB / 40.0f);
    const float omega = 2.0f * pi * frequency / sampleRate;
    const float cosine = std::cos(omega);
    const float alpha = std::sin(omega) / (2.0f * std::max(q, 0.001f));
    return normalize(
      1.0f + (alpha * amp),
      -2.0f * cosine,
      1.0f - (alpha * amp),
      1.0f + (alpha / amp),
      -2.0f * cosine,
      1.0f - (alpha / amp)
    );
  }

  static BiquadCoefficients shelf(float sampleRate, float frequency, float gainDB, bool isHighShelf) {
    frequency = clampedFrequency(frequency, sampleRate);
    const float amp = std::pow(10.0f, gainDB / 40.0f);
    const float omega = 2.0f * pi * frequency / sampleRate;
    const float sine = std::sin(omega);
    const float cosine = std::cos(omega);
    const float alpha = sine / 2.0f * std::sqrt(2.0f);
    const float beta = 2.0f * std::sqrt(amp) * alpha;

    if (isHighShelf) {
      return normalize(
        amp * ((amp + 1.0f) + ((amp - 1.0f) * cosine) + beta),
        -2.0f * amp * ((amp - 1.0f) + ((amp + 1.0f) * cosine)),
        amp * ((amp + 1.0f) + ((amp - 1.0f) * cosine) - beta),
        (amp + 1.0f) - ((amp - 1.0f) * cosine) + beta,
        2.0f * ((amp - 1.0f) - ((amp + 1.0f) * cosine)),
        (amp + 1.0f) - ((amp - 1.0f) * cosine) - beta
      );
    }

    return normalize(
      amp * ((amp + 1.0f) - ((amp - 1.0f) * cosine) + beta),
      2.0f * amp * ((amp - 1.0f) - ((amp + 1.0f) * cosine)),
      amp * ((amp + 1.0f) - ((amp - 1.0f) * cosine) - beta),
      (amp + 1.0f) + ((amp - 1.0f) * cosine) + beta,
      -2.0f * ((amp - 1.0f) + ((amp + 1.0f) * cosine)),
      (amp + 1.0f) + ((amp - 1.0f) * cosine) - beta
    );
  }
};

struct BiquadFilter {
  float b0 = 1.0f;
  float b1 = 0.0f;
  float b2 = 0.0f;
  float a1 = 0.0f;
  float a2 = 0.0f;
  float z1 = 0.0f;
  float z2 = 0.0f;

  void resetState() {
    z1 = 0.0f;
    z2 = 0.0f;
  }

  void setBypass() {
    b0 = 1.0f;
    b1 = 0.0f;
    b2 = 0.0f;
    a1 = 0.0f;
    a2 = 0.0f;
  }

  void apply(const BiquadCoefficients &coefficients) {
    b0 = coefficients.b0;
    b1 = coefficients.b1;
    b2 = coefficients.b2;
    a1 = coefficients.a1;
    a2 = coefficients.a2;
  }

  void setHighPass(float sampleRate, float frequency, float q) {
    apply(BiquadCoefficients::highPass(sampleRate, frequency, q));
  }

  void setLowPass(float sampleRate, float frequency, float q) {
    apply(BiquadCoefficients::lowPass(sampleRate, frequency, q));
  }

  void setPeak(float sampleRate, float frequency, float q, float gainDB) {
    std::abs(gainDB) < 0.001f ? setBypass() : apply(BiquadCoefficients::peak(sampleRate, frequency, q, gainDB));
  }

  void setLowShelf(float sampleRate, float frequency, float gainDB) {
    std::abs(gainDB) < 0.001f ? setBypass() : apply(BiquadCoefficients::shelf(sampleRate, frequency, gainDB, false));
  }

  void setHighShelf(float sampleRate, float frequency, float gainDB) {
    std::abs(gainDB) < 0.001f ? setBypass() : apply(BiquadCoefficients::shelf(sampleRate, frequency, gainDB, true));
  }

  float process(float input) {
    const float output = (b0 * input) + z1;
    z1 = (b1 * input) - (a1 * output) + z2;
    z2 = (b2 * input) - (a2 * output);
    return output;
  }
};

struct FractionalDelayLine {
  std::vector<float> buffer;
  int writeIndex = 0;

  void prepare(float maxDelaySeconds, float sampleRate) {
    const int frameCount = std::max(static_cast<int>(maxDelaySeconds * sampleRate) + 4, 8);
    buffer.assign(frameCount, 0.0f);
    writeIndex = 0;
  }

  void reset() {
    std::fill(buffer.begin(), buffer.end(), 0.0f);
    writeIndex = 0;
  }

  void write(float sample) {
    if (buffer.empty()) {
      return;
    }
    buffer[writeIndex] = sample;
    writeIndex = (writeIndex + 1) % static_cast<int>(buffer.size());
  }

  float readSeconds(float delaySeconds, float sampleRate) const {
    return readSamples(delaySeconds * sampleRate);
  }

  float readSamples(float delaySamples) const {
    if (buffer.empty()) {
      return 0.0f;
    }

    const float maximumDelay = static_cast<float>(buffer.size() - 2);
    delaySamples = clampFloat(delaySamples, 1.0f, maximumDelay);
    float readPosition = static_cast<float>(writeIndex) - delaySamples;
    while (readPosition < 0.0f) {
      readPosition += static_cast<float>(buffer.size());
    }

    const int lowerIndex = static_cast<int>(readPosition) % static_cast<int>(buffer.size());
    const int upperIndex = (lowerIndex + 1) % static_cast<int>(buffer.size());
    const float fraction = readPosition - static_cast<float>(static_cast<int>(readPosition));
    return buffer[lowerIndex] + ((buffer[upperIndex] - buffer[lowerIndex]) * fraction);
  }
};

struct FirstOrderAllPass {
  float coefficient = 0.0f;
  float state = 0.0f;

  void reset() {
    state = 0.0f;
  }

  float process(float input) {
    const float output = (-coefficient * input) + state;
    state = input + (coefficient * output);
    return output;
  }
};

struct PhaserNetwork {
  std::vector<FirstOrderAllPass> stages;
  float feedbackSample = 0.0f;

  void prepare(int stageCount) {
    stages.assign(std::max(stageCount, 1), FirstOrderAllPass());
  }

  void reset() {
    for (auto &stage : stages) {
      stage.reset();
    }
    feedbackSample = 0.0f;
  }

  float process(float input, float coefficient, float feedback) {
    float sample = input + (feedbackSample * clampFloat(feedback, -0.95f, 0.95f));
    for (auto &stage : stages) {
      stage.coefficient = coefficient;
      sample = stage.process(sample);
    }
    feedbackSample = sample;
    return sample;
  }
};

struct DelayAllPass {
  float feedback = 0.5f;
  std::vector<float> buffer;
  int index = 0;

  void prepare(float delaySeconds, float sampleRate, float newFeedback) {
    feedback = newFeedback;
    buffer.assign(std::max(static_cast<int>(delaySeconds * sampleRate), 2), 0.0f);
    index = 0;
  }

  void reset() {
    std::fill(buffer.begin(), buffer.end(), 0.0f);
    index = 0;
  }

  float process(float input) {
    const float delayed = buffer[index];
    const float output = delayed - (feedback * input);
    buffer[index] = input + (feedback * output);
    index = (index + 1) % static_cast<int>(buffer.size());
    return output;
  }
};

struct FeedbackComb {
  std::vector<float> buffer;
  int index = 0;
  float filterStore = 0.0f;

  void prepare(float delaySeconds, float sampleRate) {
    buffer.assign(std::max(static_cast<int>(delaySeconds * sampleRate), 2), 0.0f);
    index = 0;
    filterStore = 0.0f;
  }

  void reset() {
    std::fill(buffer.begin(), buffer.end(), 0.0f);
    index = 0;
    filterStore = 0.0f;
  }

  float process(float input, float feedback, float damping) {
    const float delayed = buffer[index];
    filterStore = (delayed * (1.0f - damping)) + (filterStore * damping);
    buffer[index] = input + (filterStore * feedback);
    index = (index + 1) % static_cast<int>(buffer.size());
    return delayed;
  }
};

struct ReverbTank {
  std::vector<FeedbackComb> combs;
  std::vector<DelayAllPass> allPasses;

  void prepare(float sampleRate, int variant) {
    const float offset = static_cast<float>(variant % 5) * 0.00083f;
    const float combDelays[] = {0.0297f, 0.0371f, 0.0411f, 0.0437f};
    const float allPassDelays[] = {0.0050f, 0.0017f};

    combs.assign(4, FeedbackComb());
    for (int index = 0; index < 4; ++index) {
      combs[index].prepare(combDelays[index] + offset, sampleRate);
    }

    allPasses.assign(2, DelayAllPass());
    for (int index = 0; index < 2; ++index) {
      allPasses[index].prepare(allPassDelays[index] + (offset * 0.35f), sampleRate, 0.5f);
    }
  }

  void reset() {
    for (auto &comb : combs) {
      comb.reset();
    }
    for (auto &allPass : allPasses) {
      allPass.reset();
    }
  }

  float process(float input, float roomSize, float damping) {
    const float feedback = clampFloat(0.66f + (normalized(roomSize) * 0.28f), 0.1f, 0.94f);
    const float damp = clampFloat(damping, 0.02f, 0.85f);
    float wet = 0.0f;
    for (auto &comb : combs) {
      wet += comb.process(input, feedback, damp);
    }
    wet *= 0.25f;
    for (auto &allPass : allPasses) {
      wet = allPass.process(wet);
    }
    return wet;
  }
};

struct LongBloomTank {
  std::vector<FeedbackComb> combs;
  std::vector<DelayAllPass> allPasses;

  void prepare(float sampleRate, int variant) {
    const float offset = static_cast<float>((variant % 7) + 1) * 0.0031f;
    const float combDelays[] = {0.113f, 0.173f, 0.241f, 0.337f, 0.463f, 0.617f};
    const float allPassDelays[] = {0.031f, 0.047f, 0.071f};

    combs.assign(6, FeedbackComb());
    for (int index = 0; index < 6; ++index) {
      combs[index].prepare(combDelays[index] + (offset * static_cast<float>(index + 1)), sampleRate);
    }

    allPasses.assign(3, DelayAllPass());
    for (int index = 0; index < 3; ++index) {
      allPasses[index].prepare(allPassDelays[index] + (offset * 0.21f), sampleRate, 0.62f);
    }
  }

  void reset() {
    for (auto &comb : combs) {
      comb.reset();
    }
    for (auto &allPass : allPasses) {
      allPass.reset();
    }
  }

  float process(float input, float length, float damping) {
    const float feedback = clampFloat(0.88f + (normalized(length) * 0.105f), 0.2f, 0.985f);
    const float damp = clampFloat(0.08f + (normalized(damping) * 0.74f), 0.02f, 0.88f);
    float wet = 0.0f;

    for (auto &comb : combs) {
      wet += comb.process(input * 0.32f, feedback, damp);
    }

    wet *= 0.24f;
    for (auto &allPass : allPasses) {
      wet = allPass.process(wet);
    }

    return softLimit(wet * 1.55f);
  }
};

struct ReverseGrain {
  std::vector<float> buffers[2];
  int activeLength = 256;
  int writeBuffer = 0;
  int writePosition = 0;
  bool primed = false;

  void prepare(float maximumSeconds, float sampleRate) {
    const int maximumFrames = std::max(static_cast<int>(maximumSeconds * sampleRate), 512);
    buffers[0].assign(maximumFrames, 0.0f);
    buffers[1].assign(maximumFrames, 0.0f);
    activeLength = std::min(2048, maximumFrames);
    writeBuffer = 0;
    writePosition = 0;
    primed = false;
  }

  void reset() {
    std::fill(buffers[0].begin(), buffers[0].end(), 0.0f);
    std::fill(buffers[1].begin(), buffers[1].end(), 0.0f);
    writeBuffer = 0;
    writePosition = 0;
    primed = false;
  }

  float process(float input, int requestedLength) {
    const int maximumFrames = static_cast<int>(buffers[0].size());
    if (maximumFrames <= 0) {
      return 0.0f;
    }

    const int grainLength = clampFloat(static_cast<float>(requestedLength), 64.0f, static_cast<float>(maximumFrames));
    if (grainLength != activeLength) {
      activeLength = grainLength;
      writePosition = 0;
      primed = false;
    }

    const int readBuffer = 1 - writeBuffer;
    const int readPosition = activeLength - 1 - writePosition;
    const float output = primed ? buffers[readBuffer][readPosition] : 0.0f;

    buffers[writeBuffer][writePosition] = input;
    ++writePosition;
    if (writePosition >= activeLength) {
      writePosition = 0;
      writeBuffer = readBuffer;
      primed = true;
    }

    return output;
  }
};

struct ChannelEffectState {
  BiquadFilter biquadA;
  BiquadFilter biquadB;
  float compressorEnvelope = 0.0f;
  float gateEnvelope = 0.0f;
  float gateGain = 1.0f;
  float dampingSample = 0.0f;
  float lfoPhase = 0.0f;
  float secondaryPhase = pi * 0.5f;
  float crushSample = 0.0f;
  float tapeDelayTime = 0.35f;
  float tapeFeedbackSample = 0.0f;
  float tapeInputEnvelope = 0.0f;
  float tapeRepeatInterval = 0.8f;
  float tapeRepeatCountdown = 0.8f;
  float tapeEchoEnvelope = 0.0f;
  float tapeReadDelaySamples = 48000.0f;
  float tapeReadSpeed = 1.0f;
  int crushCounter = 0;
  FractionalDelayLine delayA;
  FractionalDelayLine delayB;
  FractionalDelayLine delayC;
  PhaserNetwork phaser;
  ReverbTank reverb;
  LongBloomTank longBloom;
  ReverseGrain reverse;

  void prepare(float sampleRate, int channelIndex) {
    delayA.prepare(3.0f, sampleRate);
    delayB.prepare(0.16f, sampleRate);
    delayC.prepare(1.2f, sampleRate);
    phaser.prepare(6);
    reverb.prepare(sampleRate, channelIndex);
    longBloom.prepare(sampleRate, channelIndex);
    reverse.prepare(1.8f, sampleRate);
    reset();
    lfoPhase = channelIndex == 0 ? 0.0f : pi;
    secondaryPhase = lfoPhase + (pi * 0.5f);
  }

  void reset() {
    biquadA.resetState();
    biquadB.resetState();
    compressorEnvelope = 0.0f;
    gateEnvelope = 0.0f;
    gateGain = 1.0f;
    dampingSample = 0.0f;
    crushSample = 0.0f;
    tapeDelayTime = 0.35f;
    tapeFeedbackSample = 0.0f;
    tapeInputEnvelope = 0.0f;
    tapeRepeatInterval = 0.8f;
    tapeRepeatCountdown = 0.8f;
    tapeEchoEnvelope = 0.0f;
    tapeReadDelaySamples = 48000.0f;
    tapeReadSpeed = 1.0f;
    crushCounter = 0;
    delayA.reset();
    delayB.reset();
    delayC.reset();
    phaser.reset();
    reverb.reset();
    longBloom.reset();
    reverse.reset();
  }
};

struct EffectRuntime {
  int type = 0;
  int preparedChannelCount = 0;
  std::vector<ChannelEffectState> channels;
  ReverbTank stereoLeft;
  ReverbTank stereoRight;
  LongBloomTank bloomLeft;
  LongBloomTank bloomRight;
  float sharedPhase = 0.0f;
  float bloomEnergy = 0.0f;

  void prepare(int newType, int channelCount, float sampleRate) {
    type = newType;
    preparedChannelCount = channelCount;
    channels.assign(std::max(channelCount, 1), ChannelEffectState());
    for (int channel = 0; channel < static_cast<int>(channels.size()); ++channel) {
      channels[channel].prepare(sampleRate, channel);
    }
    stereoLeft.prepare(sampleRate, 0);
    stereoRight.prepare(sampleRate, 1);
    bloomLeft.prepare(sampleRate, 0);
    bloomRight.prepare(sampleRate, 1);
    sharedPhase = 0.0f;
    bloomEnergy = 0.0f;
  }
};

struct RingBuffer {
  int channelCount = 1;
  int capacityFrames = 1024;
  std::vector<std::vector<float>> storage;
  std::atomic<int> writeIndex {0};
  std::atomic<int> readIndex {0};

  void prepare(int channels, int capacity) {
    channelCount = std::max(channels, 1);
    capacityFrames = std::max(capacity, 1024);
    storage.assign(channelCount, std::vector<float>(capacityFrames, 0.0f));
    writeIndex.store(0, std::memory_order_release);
    readIndex.store(0, std::memory_order_release);
  }

  void reset() {
    for (auto &channel : storage) {
      std::fill(channel.begin(), channel.end(), 0.0f);
    }
    writeIndex.store(0, std::memory_order_release);
    readIndex.store(0, std::memory_order_release);
  }

  void write(const float * const *sourceChannels, int sourceChannelCount, int frameCount) {
    if (sourceChannels == nullptr || frameCount <= 0 || sourceChannelCount <= 0 || storage.empty()) {
      return;
    }

    int write = writeIndex.load(std::memory_order_relaxed);
    int read = readIndex.load(std::memory_order_acquire);

    for (int frame = 0; frame < frameCount; ++frame) {
      const int nextWrite = (write + 1) % capacityFrames;
      if (nextWrite == read) {
        read = (read + 1) % capacityFrames;
        readIndex.store(read, std::memory_order_release);
      }

      for (int channel = 0; channel < channelCount; ++channel) {
        const int sourceChannel = std::min(channel, sourceChannelCount - 1);
        storage[channel][write] = sourceChannels[sourceChannel][frame];
      }

      write = nextWrite;
      writeIndex.store(write, std::memory_order_release);
    }
  }

  void read(std::vector<std::vector<float>> &destination, int frameCount) {
    if (frameCount <= 0) {
      return;
    }

    for (auto &channel : destination) {
      if (static_cast<int>(channel.size()) < frameCount) {
        channel.assign(frameCount, 0.0f);
      }
    }

    int read = readIndex.load(std::memory_order_relaxed);
    const int write = writeIndex.load(std::memory_order_acquire);
    const int destinationChannelCount = static_cast<int>(destination.size());

    for (int frame = 0; frame < frameCount; ++frame) {
      if (read != write) {
        for (int channel = 0; channel < destinationChannelCount; ++channel) {
          const int sourceChannel = std::min(channel, channelCount - 1);
          destination[channel][frame] = storage[sourceChannel][read];
        }
        read = (read + 1) % capacityFrames;
      } else {
        for (int channel = 0; channel < destinationChannelCount; ++channel) {
          destination[channel][frame] = 0.0f;
        }
      }
    }

    readIndex.store(read, std::memory_order_release);
  }
};

std::vector<EffectDescriptor> sanitizedChain(const std::vector<EffectDescriptor> &chain) {
  std::vector<EffectDescriptor> sanitized;
  sanitized.reserve(std::min(static_cast<int>(chain.size()), maximumEffectSlots));

  for (const auto &descriptor : chain) {
    if (static_cast<int>(sanitized.size()) >= maximumEffectSlots) {
      break;
    }

    EffectDescriptor next = descriptor;
    next.amount = normalized(next.amount);
    next.parameterA = normalized(next.parameterA);
    next.parameterB = normalized(next.parameterB);
    if (next.type < effectHighPass || next.type > effectTapeRiserDelay) {
      continue;
    }
    sanitized.push_back(next);
  }

  return sanitized;
}

}

struct LowLevelEffectEngine::Impl {
  std::shared_ptr<const std::vector<EffectDescriptor>> pendingChain;
  std::shared_ptr<const std::vector<EffectDescriptor>> appliedChainPointer;
  std::vector<EffectDescriptor> appliedChain;
  std::vector<EffectRuntime> effectStates;
  RingBuffer ringBuffer;
  std::vector<std::vector<float>> inputScratch;
  std::vector<float> frameScratch;
  float sampleRate = 48000.0f;
  int channelCount = 1;

  Impl() {
    pendingChain = std::make_shared<std::vector<EffectDescriptor>>();
  }

  void prepare(double newSampleRate, int newChannelCount, int maximumFrameCount) {
    sampleRate = static_cast<float>(std::max(newSampleRate, 1.0));
    channelCount = std::max(newChannelCount, 1);
    ringBuffer.prepare(channelCount, static_cast<int>(sampleRate * 2.5f));
    inputScratch.assign(channelCount, std::vector<float>(std::max(maximumFrameCount, 1024), 0.0f));
    frameScratch.assign(channelCount, 0.0f);
    appliedChainPointer.reset();
    appliedChain.clear();
    effectStates.clear();
  }

  void updateChain(const std::vector<EffectDescriptor> &chain) {
    auto nextChain = std::make_shared<std::vector<EffectDescriptor>>(sanitizedChain(chain));
    std::shared_ptr<const std::vector<EffectDescriptor>> immutableChain = nextChain;
    std::atomic_store_explicit(&pendingChain, immutableChain, std::memory_order_release);
  }

  void writeInput(const float * const *channels, int sourceChannelCount, int frameCount) {
    ringBuffer.write(channels, sourceChannelCount, frameCount);
  }

  void render(int frameCount, AudioBufferList *outputAudioBufferList) {
    if (frameCount <= 0 || outputAudioBufferList == nullptr) {
      return;
    }

    ensureScratchCapacity(frameCount);
    refreshChainIfNeeded();
    ringBuffer.read(inputScratch, frameCount);

    for (int frame = 0; frame < frameCount; ++frame) {
      for (int channel = 0; channel < channelCount; ++channel) {
        frameScratch[channel] = inputScratch[channel][frame];
      }

      for (int effectIndex = 0; effectIndex < static_cast<int>(appliedChain.size()); ++effectIndex) {
        processEffect(effectStates[effectIndex], appliedChain[effectIndex]);
      }

      for (int channel = 0; channel < channelCount; ++channel) {
        frameScratch[channel] = softLimit(frameScratch[channel]);
      }

      writeFrame(frame, outputAudioBufferList);
    }
  }

  void reset() {
    ringBuffer.reset();
    for (auto &runtime : effectStates) {
      for (auto &channel : runtime.channels) {
        channel.reset();
      }
      runtime.stereoLeft.reset();
      runtime.stereoRight.reset();
      runtime.bloomLeft.reset();
      runtime.bloomRight.reset();
      runtime.sharedPhase = 0.0f;
      runtime.bloomEnergy = 0.0f;
    }
  }

  void ensureScratchCapacity(int frameCount) {
    for (auto &channel : inputScratch) {
      if (static_cast<int>(channel.size()) < frameCount) {
        channel.assign(frameCount, 0.0f);
      }
    }
  }

  void refreshChainIfNeeded() {
    auto chain = std::atomic_load_explicit(&pendingChain, std::memory_order_acquire);
    if (chain == appliedChainPointer) {
      return;
    }

    appliedChainPointer = chain;
    appliedChain = *chain;
    effectStates.resize(appliedChain.size());

    for (int index = 0; index < static_cast<int>(appliedChain.size()); ++index) {
      const int type = appliedChain[index].type;
      if (effectStates[index].type != type || effectStates[index].preparedChannelCount != channelCount) {
        effectStates[index].prepare(type, channelCount, sampleRate);
      }
      configureEffect(effectStates[index], appliedChain[index]);
    }
  }

  void configureEffect(EffectRuntime &runtime, const EffectDescriptor &descriptor) {
    const float amount = descriptor.amount;
    const float parameterA = descriptor.parameterA;
    const float parameterB = descriptor.parameterB;

    for (auto &channel : runtime.channels) {
      switch (descriptor.type) {
      case effectHighPass: {
        channel.biquadA.setHighPass(sampleRate, expMap(35.0f, 900.0f, parameterA), lerp(0.55f, 6.0f, parameterB));
        break;
      }
      case effectLowPass: {
        channel.biquadA.setLowPass(sampleRate, expMap(500.0f, 18000.0f, parameterA), lerp(0.55f, 5.0f, parameterB));
        break;
      }
      case effectTiltEQ: {
        const float tilt = (parameterA - 0.5f) * 20.0f * amount;
        channel.biquadA.setLowShelf(sampleRate, 250.0f, -tilt);
        channel.biquadB.setHighShelf(sampleRate, 4200.0f, tilt + ((parameterB - 0.5f) * 6.0f * amount));
        break;
      }
      case effectPresenceEQ: {
        channel.biquadA.setPeak(sampleRate, expMap(700.0f, 4200.0f, parameterA), 0.82f, lerp(2.0f, 10.0f, amount));
        channel.biquadB.setHighShelf(sampleRate, 5600.0f, (parameterB - 0.35f) * 8.0f * amount);
        break;
      }
      case effectShimmer: {
        channel.biquadA.setHighShelf(sampleRate, 5200.0f, 4.0f + (amount * 10.0f));
        break;
      }
      default:
        break;
      }
    }
  }

  void processEffect(EffectRuntime &runtime, const EffectDescriptor &descriptor) {
    if (!descriptor.enabled || descriptor.amount <= 0.0001f) {
      return;
    }

    switch (descriptor.type) {
    case effectHighPass:
    case effectLowPass:
    case effectTiltEQ:
    case effectPresenceEQ:
      processFilter(runtime, descriptor);
      break;
    case effectCompressor:
      processCompressor(runtime, descriptor);
      break;
    case effectNoiseGate:
      processNoiseGate(runtime, descriptor);
      break;
    case effectSoftClip:
      processSoftClip(descriptor);
      break;
    case effectWaveFolder:
      processWaveFolder(descriptor);
      break;
    case effectBitCrusher:
      processBitCrusher(runtime, descriptor);
      break;
    case effectTremolo:
      processTremolo(runtime, descriptor);
      break;
    case effectRingMod:
      processRingMod(runtime, descriptor);
      break;
    case effectPanner:
      processPanner(descriptor);
      break;
    case effectAutoPan:
      processAutoPan(runtime, descriptor);
      break;
    case effectVibrato:
      processVibrato(runtime, descriptor);
      break;
    case effectChorus:
      processChorus(runtime, descriptor);
      break;
    case effectFlanger:
      processFlanger(runtime, descriptor);
      break;
    case effectPhaser:
      processPhaser(runtime, descriptor);
      break;
    case effectSlapDelay:
      processSlapDelay(runtime, descriptor);
      break;
    case effectAcceleratingDelay:
      processAcceleratingDelay(runtime, descriptor);
      break;
    case effectTapeRiserDelay:
      processTapeRiserDelay(runtime, descriptor);
      break;
    case effectPingPongDelay:
      processPingPongDelay(runtime, descriptor);
      break;
    case effectReverse:
      processReverse(runtime, descriptor);
      break;
    case effectRoomReverb:
      processRoomReverb(runtime, descriptor);
      break;
    case effectStereoReverb:
      processStereoReverb(runtime, descriptor);
      break;
    case effectShimmer:
      processShimmer(runtime, descriptor);
      break;
    case effectCombResonator:
      processCombResonator(runtime, descriptor);
      break;
    case effectSpaceWidener:
      processSpaceWidener(descriptor);
      break;
    case effectLongBloom:
      processLongBloom(runtime, descriptor);
      break;
    case effectConvergingBloom:
      processConvergingBloom(runtime, descriptor);
      break;
    default:
      break;
    }
  }

  void processFilter(EffectRuntime &runtime, const EffectDescriptor &descriptor) {
    for (int channel = 0; channel < channelCount; ++channel) {
      auto &state = runtime.channels[channel];
      const float dry = frameScratch[channel];
      float wet = state.biquadA.process(dry);
      if (descriptor.type == effectTiltEQ || descriptor.type == effectPresenceEQ) {
        wet = state.biquadB.process(wet);
      }
      frameScratch[channel] = mix(dry, wet, descriptor.amount);
    }
  }

  void processCompressor(EffectRuntime &runtime, const EffectDescriptor &descriptor) {
    const float threshold = lerp(-42.0f, -12.0f, descriptor.parameterA);
    const float ratio = lerp(1.5f, 12.0f, descriptor.parameterB) * lerp(0.55f, 1.0f, descriptor.amount);
    const float makeup = lerp(0.0f, 7.0f, descriptor.amount);

    for (int channel = 0; channel < channelCount; ++channel) {
      auto &state = runtime.channels[channel];
      const float input = frameScratch[channel];
      const float rectified = std::abs(input);
      const float attack = smoothingCoefficient(0.004f, sampleRate);
      const float release = smoothingCoefficient(0.12f, sampleRate);
      const float coefficient = rectified > state.compressorEnvelope ? attack : release;
      state.compressorEnvelope = (coefficient * state.compressorEnvelope) + ((1.0f - coefficient) * rectified);

      const float envelopeDB = amplitudeToDB(state.compressorEnvelope);
      float compressedDB = envelopeDB;
      if (envelopeDB > threshold) {
        compressedDB = threshold + ((envelopeDB - threshold) / std::max(ratio, 1.0f));
      }
      frameScratch[channel] = input * dbToAmplitude(compressedDB - envelopeDB + makeup);
    }
  }

  void processNoiseGate(EffectRuntime &runtime, const EffectDescriptor &descriptor) {
    const float threshold = dbToAmplitude(lerp(-70.0f, -24.0f, descriptor.parameterA));
    const float floorGain = lerp(0.02f, 0.65f, descriptor.parameterB);
    const float attack = smoothingCoefficient(0.004f, sampleRate);
    const float release = smoothingCoefficient(0.09f, sampleRate);

    for (int channel = 0; channel < channelCount; ++channel) {
      auto &state = runtime.channels[channel];
      const float input = frameScratch[channel];
      const float rectified = std::abs(input);
      const float envelopeCoefficient = rectified > state.gateEnvelope ? attack : release;
      state.gateEnvelope = (envelopeCoefficient * state.gateEnvelope) + ((1.0f - envelopeCoefficient) * rectified);
      const float target = state.gateEnvelope >= threshold ? 1.0f : floorGain;
      state.gateGain += (target - state.gateGain) * 0.025f;
      frameScratch[channel] = mix(input, input * state.gateGain, descriptor.amount);
    }
  }

  void processSoftClip(const EffectDescriptor &descriptor) {
    const float drive = 1.0f + (descriptor.parameterA * 12.0f);
    const float trim = 1.0f / softLimit(drive);
    for (int channel = 0; channel < channelCount; ++channel) {
      const float input = frameScratch[channel];
      frameScratch[channel] = mix(input, softLimit(input * drive) * trim, descriptor.amount);
    }
  }

  void processWaveFolder(const EffectDescriptor &descriptor) {
    const float drive = 1.0f + (descriptor.parameterA * 8.0f);
    const float tone = lerp(0.4f, 1.2f, descriptor.parameterB);
    for (int channel = 0; channel < channelCount; ++channel) {
      const float input = frameScratch[channel];
      frameScratch[channel] = mix(input, folded(input * drive) * tone, descriptor.amount);
    }
  }

  void processBitCrusher(EffectRuntime &runtime, const EffectDescriptor &descriptor) {
    const int bitDepth = static_cast<int>(std::round(lerp(16.0f, 4.0f, descriptor.parameterA)));
    const float steps = std::pow(2.0f, static_cast<float>(bitDepth - 1));
    const int holdFrames = static_cast<int>(std::round(lerp(1.0f, 48.0f, descriptor.parameterB)));

    for (int channel = 0; channel < channelCount; ++channel) {
      auto &state = runtime.channels[channel];
      const float input = frameScratch[channel];
      if (state.crushCounter <= 0) {
        state.crushSample = std::round(input * steps) / steps;
        state.crushCounter = holdFrames;
      }
      --state.crushCounter;
      frameScratch[channel] = mix(input, state.crushSample, descriptor.amount);
    }
  }

  void processTremolo(EffectRuntime &runtime, const EffectDescriptor &descriptor) {
    const float rate = expMap(0.25f, 18.0f, descriptor.parameterA);
    const float shape = descriptor.parameterB;

    for (int channel = 0; channel < channelCount; ++channel) {
      auto &state = runtime.channels[channel];
      float lfo = 0.5f + (0.5f * std::sin(state.lfoPhase));
      const float square = lfo > 0.5f ? 1.0f : 0.0f;
      lfo = mix(lfo, square, std::max(0.0f, (shape - 0.5f) * 2.0f));
      frameScratch[channel] *= 1.0f - (lfo * descriptor.amount * 0.92f);
      advancePhase(state.lfoPhase, rate, sampleRate);
    }
  }

  void processRingMod(EffectRuntime &runtime, const EffectDescriptor &descriptor) {
    const float frequency = expMap(18.0f, 1800.0f, descriptor.parameterA);
    const float blend = normalized(descriptor.amount * lerp(0.45f, 1.0f, descriptor.parameterB));

    for (int channel = 0; channel < channelCount; ++channel) {
      auto &state = runtime.channels[channel];
      const float input = frameScratch[channel];
      const float wet = input * std::sin(state.lfoPhase);
      frameScratch[channel] = mix(input, wet, blend);
      advancePhase(state.lfoPhase, frequency, sampleRate);
    }
  }

  void processPanner(const EffectDescriptor &descriptor) {
    if (channelCount < 2) {
      return;
    }

    const float pan = (descriptor.parameterA * 2.0f - 1.0f) * descriptor.amount;
    const float angle = (pan + 1.0f) * pi * 0.25f;
    const float leftGain = std::cos(angle) * lerp(0.7f, 1.15f, descriptor.parameterB);
    const float rightGain = std::sin(angle) * lerp(0.7f, 1.15f, descriptor.parameterB);
    const float left = frameScratch[0];
    const float right = frameScratch[1];
    const float mono = (left + right) * 0.5f;
    frameScratch[0] = mix(left, mono * leftGain, descriptor.amount);
    frameScratch[1] = mix(right, mono * rightGain, descriptor.amount);
  }

  void processAutoPan(EffectRuntime &runtime, const EffectDescriptor &descriptor) {
    if (channelCount < 2) {
      return;
    }

    const float rate = expMap(0.08f, 8.0f, descriptor.parameterA);
    const float width = descriptor.parameterB * descriptor.amount;
    const float pan = std::sin(runtime.sharedPhase) * width;
    const float angle = (pan + 1.0f) * pi * 0.25f;
    const float mono = (frameScratch[0] + frameScratch[1]) * 0.5f;
    frameScratch[0] = mix(frameScratch[0], mono * std::cos(angle) * 1.24f, descriptor.amount);
    frameScratch[1] = mix(frameScratch[1], mono * std::sin(angle) * 1.24f, descriptor.amount);
    advancePhase(runtime.sharedPhase, rate, sampleRate);
  }

  void processVibrato(EffectRuntime &runtime, const EffectDescriptor &descriptor) {
    const float rate = expMap(0.25f, 7.0f, descriptor.parameterA);
    const float depth = lerp(0.001f, 0.014f, descriptor.parameterB) * descriptor.amount;

    for (int channel = 0; channel < channelCount; ++channel) {
      auto &state = runtime.channels[channel];
      const float input = frameScratch[channel];
      const float lfo = 0.5f + (0.5f * std::sin(state.lfoPhase));
      const float wet = state.delayB.readSeconds(0.006f + (depth * lfo), sampleRate);
      state.delayB.write(input);
      frameScratch[channel] = mix(input, wet, descriptor.amount);
      advancePhase(state.lfoPhase, rate, sampleRate);
    }
  }

  void processChorus(EffectRuntime &runtime, const EffectDescriptor &descriptor) {
    const float rate = expMap(0.05f, 3.2f, descriptor.parameterA);
    const float depth = lerp(0.003f, 0.022f, descriptor.parameterB);

    for (int channel = 0; channel < channelCount; ++channel) {
      auto &state = runtime.channels[channel];
      const float input = frameScratch[channel];
      const float lfoA = 0.5f + (0.5f * std::sin(state.lfoPhase));
      const float lfoB = 0.5f + (0.5f * std::sin(state.secondaryPhase));
      const float wetA = state.delayA.readSeconds(0.016f + (depth * lfoA), sampleRate);
      const float wetB = state.delayC.readSeconds(0.028f + (depth * 0.7f * lfoB), sampleRate);
      state.delayA.write(input);
      state.delayC.write(input);
      frameScratch[channel] = mix(input, (wetA + wetB) * 0.5f, descriptor.amount);
      advancePhase(state.lfoPhase, rate, sampleRate);
      advancePhase(state.secondaryPhase, rate * 0.73f, sampleRate);
    }
  }

  void processFlanger(EffectRuntime &runtime, const EffectDescriptor &descriptor) {
    const float rate = expMap(0.07f, 5.0f, descriptor.parameterA);
    const float feedback = lerp(-0.2f, 0.82f, descriptor.parameterB);

    for (int channel = 0; channel < channelCount; ++channel) {
      auto &state = runtime.channels[channel];
      const float input = frameScratch[channel];
      const float lfo = 0.5f + (0.5f * std::sin(state.lfoPhase));
      const float delay = 0.001f + (0.0075f * lfo * descriptor.amount);
      const float wet = state.delayB.readSeconds(delay, sampleRate);
      state.delayB.write(input + (wet * feedback));
      frameScratch[channel] = mix(input, wet, descriptor.amount);
      advancePhase(state.lfoPhase, rate, sampleRate);
    }
  }

  void processPhaser(EffectRuntime &runtime, const EffectDescriptor &descriptor) {
    const float rate = expMap(0.05f, 6.0f, descriptor.parameterA);
    const float feedback = lerp(-0.3f, 0.88f, descriptor.parameterB);

    for (int channel = 0; channel < channelCount; ++channel) {
      auto &state = runtime.channels[channel];
      const float input = frameScratch[channel];
      const float lfo = 0.5f + (0.5f * std::sin(state.lfoPhase));
      const float frequency = expMap(120.0f, 2600.0f, lfo);
      const float wet = state.phaser.process(input, firstOrderAllPassCoefficient(frequency, sampleRate), feedback);
      frameScratch[channel] = mix(input, wet, descriptor.amount);
      advancePhase(state.lfoPhase, rate, sampleRate);
    }
  }

  void processSlapDelay(EffectRuntime &runtime, const EffectDescriptor &descriptor) {
    const float delayTime = lerp(0.055f, 0.52f, descriptor.parameterA);
    const float feedback = descriptor.parameterB * 0.72f;

    for (int channel = 0; channel < channelCount; ++channel) {
      auto &state = runtime.channels[channel];
      const float input = frameScratch[channel];
      const float wet = state.delayA.readSeconds(delayTime, sampleRate);
      state.dampingSample += (wet - state.dampingSample) * 0.18f;
      state.delayA.write(input + (state.dampingSample * feedback));
      frameScratch[channel] = mix(input, state.dampingSample, descriptor.amount);
    }
  }

  void processAcceleratingDelay(EffectRuntime &runtime, const EffectDescriptor &descriptor) {
    const float baseTime = lerp(0.16f, 0.9f, descriptor.parameterA);
    const float acceleration = lerp(0.78f, 0.28f, descriptor.parameterB);

    for (int channel = 0; channel < channelCount; ++channel) {
      auto &state = runtime.channels[channel];
      const float input = frameScratch[channel];
      float wet = 0.0f;
      float gain = 0.74f;
      float delay = baseTime;
      for (int tap = 0; tap < 7; ++tap) {
        wet += state.delayA.readSeconds(delay, sampleRate) * gain;
        delay *= acceleration;
        gain *= 0.62f;
      }
      state.delayA.write(input);
      frameScratch[channel] = input + (wet * descriptor.amount * 0.55f);
    }
  }

  void processTapeRiserDelay(EffectRuntime &runtime, const EffectDescriptor &descriptor) {
    const float startInterval = lerp(0.58f, 2.45f, descriptor.parameterA);
    const float endInterval = lerp(0.24f, 0.045f, descriptor.parameterB);
    const float intervalMultiplier = lerp(0.88f, 0.52f, descriptor.parameterB);
    const float pitchDepth = lerp(0.35f, 1.25f, descriptor.parameterB);
    const float feedback = lerp(0.34f, 0.88f, descriptor.amount);
    const float wetGain = descriptor.amount * 0.92f;
    const float echoDecay = std::exp(-1.0f / (lerp(0.28f, 0.72f, descriptor.parameterA) * sampleRate));
    const float deltaTime = 1.0f / sampleRate;
    const float endDelaySamples = endInterval * sampleRate;

    for (int channel = 0; channel < channelCount; ++channel) {
      auto &state = runtime.channels[channel];
      const float input = frameScratch[channel];
      const float previousInputEnvelope = state.tapeInputEnvelope;
      const float inputLevel = std::abs(input);
      const float envelopeSpeed = inputLevel > previousInputEnvelope ? 0.018f : 0.0007f;
      state.tapeInputEnvelope += (inputLevel - state.tapeInputEnvelope) * envelopeSpeed;

      const float onsetThreshold = lerp(0.018f, 0.06f, descriptor.amount);
      if (state.tapeInputEnvelope > onsetThreshold && previousInputEnvelope <= onsetThreshold * 0.62f) {
        state.tapeRepeatInterval = startInterval;
        state.tapeRepeatCountdown = startInterval;
        state.tapeDelayTime = startInterval;
        state.tapeEchoEnvelope = 0.0f;
        state.tapeReadDelaySamples = startInterval * sampleRate;
        state.tapeReadSpeed = 1.0f;
      }

      state.tapeRepeatInterval = clampFloat(state.tapeRepeatInterval, endInterval, startInterval);
      state.tapeRepeatCountdown -= deltaTime;
      if (state.tapeRepeatCountdown <= 0.0f) {
        const float currentInterval = state.tapeRepeatInterval;
        const float pitchRatio = std::pow(startInterval / std::max(currentInterval, endInterval), pitchDepth);
        state.tapeEchoEnvelope = 1.0f;
        state.tapeReadDelaySamples = currentInterval * sampleRate;
        state.tapeReadSpeed = clampFloat(pitchRatio, 1.0f, 4.0f);
        state.tapeDelayTime = currentInterval;
        state.tapeRepeatInterval = std::max(endInterval, state.tapeRepeatInterval * intervalMultiplier);
        state.tapeRepeatCountdown += state.tapeRepeatInterval;
      }

      const float wet = state.delayA.readSamples(state.tapeReadDelaySamples) * state.tapeEchoEnvelope;
      if (state.tapeEchoEnvelope > 0.0f) {
        state.tapeReadDelaySamples = std::max(endDelaySamples, state.tapeReadDelaySamples - (state.tapeReadSpeed - 1.0f));
      }
      state.tapeEchoEnvelope *= echoDecay;
      if (state.tapeEchoEnvelope < 0.0004f) {
        state.tapeEchoEnvelope = 0.0f;
      }

      state.tapeFeedbackSample += (wet - state.tapeFeedbackSample) * 0.52f;
      state.delayA.write(input + (state.tapeFeedbackSample * feedback));
      frameScratch[channel] = input + (state.tapeFeedbackSample * wetGain);
    }
  }

  void processPingPongDelay(EffectRuntime &runtime, const EffectDescriptor &descriptor) {
    if (channelCount < 2) {
      processSlapDelay(runtime, descriptor);
      return;
    }

    const float delayTime = lerp(0.085f, 0.72f, descriptor.parameterA);
    const float feedback = descriptor.parameterB * 0.78f;
    const float left = frameScratch[0];
    const float right = frameScratch[1];
    const float wetLeft = runtime.channels[0].delayA.readSeconds(delayTime, sampleRate);
    const float wetRight = runtime.channels[1].delayA.readSeconds(delayTime * 1.11f, sampleRate);
    runtime.channels[0].delayA.write(left + (wetRight * feedback));
    runtime.channels[1].delayA.write(right + (wetLeft * feedback));
    frameScratch[0] = mix(left, wetLeft, descriptor.amount);
    frameScratch[1] = mix(right, wetRight, descriptor.amount);
  }

  void processReverse(EffectRuntime &runtime, const EffectDescriptor &descriptor) {
    const int grainFrames = static_cast<int>(lerp(0.08f, 1.05f, descriptor.parameterA) * sampleRate);
    const float smearTime = lerp(0.012f, 0.26f, descriptor.parameterB);

    for (int channel = 0; channel < channelCount; ++channel) {
      auto &state = runtime.channels[channel];
      const float input = frameScratch[channel];
      float wet = state.reverse.process(input, grainFrames);
      const float smear = state.delayC.readSeconds(smearTime, sampleRate);
      state.delayC.write(wet);
      wet = mix(wet, smear, descriptor.parameterB * 0.55f);
      frameScratch[channel] = mix(input, wet, descriptor.amount);
    }
  }

  void processRoomReverb(EffectRuntime &runtime, const EffectDescriptor &descriptor) {
    const float roomSize = descriptor.parameterA;
    const float damping = descriptor.parameterB;

    for (int channel = 0; channel < channelCount; ++channel) {
      auto &state = runtime.channels[channel];
      const float input = frameScratch[channel];
      const float wet = state.reverb.process(input, roomSize, damping);
      frameScratch[channel] = mix(input, wet, descriptor.amount);
    }
  }

  void processStereoReverb(EffectRuntime &runtime, const EffectDescriptor &descriptor) {
    if (channelCount < 2) {
      processRoomReverb(runtime, descriptor);
      return;
    }

    const float left = frameScratch[0];
    const float right = frameScratch[1];
    float wetLeft = runtime.stereoLeft.process(left + (right * 0.18f), descriptor.parameterA, descriptor.parameterB);
    float wetRight = runtime.stereoRight.process(right + (left * 0.18f), descriptor.parameterA, descriptor.parameterB);
    const float mid = (wetLeft + wetRight) * 0.5f;
    const float side = (wetLeft - wetRight) * (0.75f + descriptor.amount);
    wetLeft = mid + side;
    wetRight = mid - side;
    frameScratch[0] = mix(left, wetLeft, descriptor.amount);
    frameScratch[1] = mix(right, wetRight, descriptor.amount);
  }

  void processShimmer(EffectRuntime &runtime, const EffectDescriptor &descriptor) {
    const float roomSize = lerp(0.42f, 1.0f, descriptor.parameterA);
    const float damping = descriptor.parameterB * 0.55f;

    for (int channel = 0; channel < channelCount; ++channel) {
      auto &state = runtime.channels[channel];
      const float input = frameScratch[channel];
      float wet = state.reverb.process(input, roomSize, damping);
      wet = state.biquadA.process(wet);
      frameScratch[channel] = mix(input, wet, descriptor.amount);
    }
  }

  void processCombResonator(EffectRuntime &runtime, const EffectDescriptor &descriptor) {
    const float frequency = expMap(55.0f, 1800.0f, descriptor.parameterA);
    const float delayTime = 1.0f / frequency;
    const float feedback = lerp(0.15f, 0.9f, descriptor.parameterB) * descriptor.amount;

    for (int channel = 0; channel < channelCount; ++channel) {
      auto &state = runtime.channels[channel];
      const float input = frameScratch[channel];
      const float wet = state.delayB.readSeconds(delayTime, sampleRate);
      state.delayB.write(input + (wet * feedback));
      frameScratch[channel] = mix(input, wet, descriptor.amount);
    }
  }

  void processSpaceWidener(const EffectDescriptor &descriptor) {
    if (channelCount < 2) {
      return;
    }

    const float left = frameScratch[0];
    const float right = frameScratch[1];
    const float mid = (left + right) * 0.5f;
    const float side = (left - right) * 0.5f;
    const float width = 1.0f + (descriptor.amount * lerp(0.1f, 2.4f, descriptor.parameterA));
    const float monoBlend = descriptor.parameterB * 0.2f;
    frameScratch[0] = (mid * (1.0f + monoBlend)) + (side * width);
    frameScratch[1] = (mid * (1.0f + monoBlend)) - (side * width);
  }

  void processLongBloom(EffectRuntime &runtime, const EffectDescriptor &descriptor) {
    const float length = descriptor.parameterA;
    const float damping = descriptor.parameterB;

    for (int channel = 0; channel < channelCount; ++channel) {
      auto &state = runtime.channels[channel];
      const float input = frameScratch[channel];
      const float injected = input + (state.dampingSample * 0.18f * descriptor.amount);
      const float wet = state.longBloom.process(injected, length, damping);
      state.dampingSample += (wet - state.dampingSample) * lerp(0.0008f, 0.006f, 1.0f - damping);
      frameScratch[channel] = input + (wet * descriptor.amount * 0.86f);
    }
  }

  void processConvergingBloom(EffectRuntime &runtime, const EffectDescriptor &descriptor) {
    if (channelCount < 2) {
      processLongBloom(runtime, descriptor);
      return;
    }

    const float left = frameScratch[0];
    const float right = frameScratch[1];
    const float spread = descriptor.parameterA;
    const float gravity = descriptor.parameterB;
    const float crossFeed = lerp(0.12f, 0.42f, spread);

    float wetLeft = runtime.bloomLeft.process(left + (right * crossFeed), lerp(0.62f, 1.0f, spread), lerp(0.18f, 0.74f, gravity));
    float wetRight = runtime.bloomRight.process(right + (left * crossFeed), lerp(0.62f, 1.0f, spread), lerp(0.18f, 0.74f, gravity));

    const float currentEnergy = std::max(std::abs(wetLeft), std::abs(wetRight));
    const float targetEnergy = clampFloat(currentEnergy * 3.5f, 0.0f, 1.0f);
    const float energySpeed = targetEnergy > runtime.bloomEnergy ? 0.024f : lerp(0.00012f, 0.0012f, gravity);
    runtime.bloomEnergy += (targetEnergy - runtime.bloomEnergy) * energySpeed;

    const float mid = (wetLeft + wetRight) * 0.5f;
    const float side = (wetLeft - wetRight) * 0.5f;
    const float opening = std::pow(clampFloat(runtime.bloomEnergy, 0.0f, 1.0f), 0.36f);
    const float sideGain = lerp(0.14f, 3.25f, opening * spread);
    const float centerPull = gravity * (1.0f - opening);
    wetLeft = mid + (side * sideGain);
    wetRight = mid - (side * sideGain);
    wetLeft = mix(wetLeft, mid, centerPull);
    wetRight = mix(wetRight, mid, centerPull);

    frameScratch[0] = left + (wetLeft * descriptor.amount * 0.9f);
    frameScratch[1] = right + (wetRight * descriptor.amount * 0.9f);
  }

  void writeFrame(int frame, AudioBufferList *outputAudioBufferList) {
    const UInt32 outputBufferCount = outputAudioBufferList->mNumberBuffers;
    if (outputBufferCount == 0) {
      return;
    }

    if (outputBufferCount == 1 && outputAudioBufferList->mBuffers[0].mNumberChannels > 1) {
      auto *output = static_cast<float *>(outputAudioBufferList->mBuffers[0].mData);
      if (output == nullptr) {
        return;
      }

      const UInt32 outputChannels = outputAudioBufferList->mBuffers[0].mNumberChannels;
      for (UInt32 channel = 0; channel < outputChannels; ++channel) {
        const int sourceChannel = std::min(static_cast<int>(channel), channelCount - 1);
        output[(frame * outputChannels) + channel] = frameScratch[sourceChannel];
      }
      return;
    }

    for (UInt32 outputChannel = 0; outputChannel < outputBufferCount; ++outputChannel) {
      auto *output = static_cast<float *>(outputAudioBufferList->mBuffers[outputChannel].mData);
      if (output == nullptr) {
        continue;
      }

      const int sourceChannel = std::min(static_cast<int>(outputChannel), channelCount - 1);
      output[frame] = frameScratch[sourceChannel];
    }
  }
};

LowLevelEffectEngine::LowLevelEffectEngine() : impl(std::make_unique<Impl>()) {}

LowLevelEffectEngine::~LowLevelEffectEngine() = default;

void LowLevelEffectEngine::prepare(double sampleRate, int channelCount, int maximumFrameCount) {
  impl->prepare(sampleRate, channelCount, maximumFrameCount);
}

void LowLevelEffectEngine::updateChain(const std::vector<EffectDescriptor> &chain) {
  impl->updateChain(chain);
}

void LowLevelEffectEngine::writeInput(const float * const *channels, int sourceChannelCount, int frameCount) {
  impl->writeInput(channels, sourceChannelCount, frameCount);
}

void LowLevelEffectEngine::render(int frameCount, AudioBufferList *outputAudioBufferList) {
  impl->render(frameCount, outputAudioBufferList);
}

void LowLevelEffectEngine::reset() {
  impl->reset();
}

}
