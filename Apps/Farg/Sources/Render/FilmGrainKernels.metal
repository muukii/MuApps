//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//

// Core Image kernel for Färg's film-grain overlay.
//
// This file is build-compiled into the app target's `default.metallib` and
// loaded with `CIColorKernel(functionName:fromMetalLibraryData:)`. The
// `[[ stitchable ]]` attribute removes the historical `-fcikernel` build-flag
// requirement, matching BrightroomParametric's kernel packaging.

#include <CoreImage/CoreImage.h>
using namespace metal;

/// Dave Hoskins-style trigless hash; stable across GPU families so preview,
/// export, and Simulator produce identical grain for identical coordinates.
static float filmGrainHash(float2 position) {
  float3 folded = fract(float3(position.xyx) * 0.1031);
  folded += dot(folded, folded.yzx + 33.33);
  return fract((folded.x + folded.y) * folded.z);
}

/// Band-limited value noise with quintic interpolation, centered on zero.
///
/// Unlike per-pixel white noise, lattice interpolation produces round,
/// connected clumps whose diameter follows the sampling pitch — the spatial
/// structure that reads as photographic grain rather than digital noise.
static float filmGrainValueNoise(float2 position) {
  float2 cell = floor(position);
  float2 fractional = fract(position);
  float2 weight =
    fractional * fractional * fractional
    * (fractional * (fractional * 6.0 - 15.0) + 10.0);
  float bottomLeft = filmGrainHash(cell);
  float bottomRight = filmGrainHash(cell + float2(1.0, 0.0));
  float topLeft = filmGrainHash(cell + float2(0.0, 1.0));
  float topRight = filmGrainHash(cell + float2(1.0, 1.0));
  return mix(
    mix(bottomLeft, bottomRight, weight.x),
    mix(topLeft, topRight, weight.x),
    weight.y
  ) - 0.5;
}

/// Two noise octaves; the fine octave is rotated so no lattice axis survives
/// into the final texture, and their sum approaches a gaussian amplitude
/// distribution like developed silver-halide density.
static float filmGrainNoise(float2 position) {
  const float2x2 rotation = float2x2(0.8253, 0.5646, -0.5646, 0.8253);
  float coarse = filmGrainValueNoise(position);
  float fine = filmGrainValueNoise(rotation * (position * 2.137) + 517.3);
  return coarse * 0.72 + fine * 0.28;
}

extern "C" { namespace coreimage {

  /// Composites time-seeded film grain over one gamma-encoded frame.
  ///
  /// - source: the graded frame, already encoded with the sRGB tone curve.
  /// - pitch: grain clump diameter in output pixels.
  /// - amplitude: peak grain amplitude in the gamma-encoded domain.
  /// - chromaAmount: 0 = pure luma grain, 1 = fully independent RGB grain.
  /// - seed: per-frame lattice offset selecting the frame's noise region.
  [[ stitchable ]] float4 filmGrain(
    sample_t source,
    float pitch,
    float amplitude,
    float chromaAmount,
    float2 seed,
    destination dest
  ) {
    float2 position = (dest.coord() + seed) / pitch;

    float lumaNoise = filmGrainNoise(position);
    float3 channelNoise = float3(
      filmGrainNoise(position + float2(147.31, 289.97)),
      filmGrainNoise(position + float2(613.37, 119.43)),
      filmGrainNoise(position + float2(431.17, 523.91))
    );
    float3 grain = mix(float3(lumaNoise), channelNoise, chromaAmount);

    // Negative-film response: density fluctuation peaks just below middle
    // gray and rolls off through the toe and shoulder, so pure black and
    // pure white stay clean. The constant normalizes the curve's peak to 1.
    float luma = clamp(
      dot(source.rgb, float3(0.2126, 0.7152, 0.0722)),
      0.0,
      1.0
    );
    float response = pow(luma, 0.6) * pow(1.0 - luma, 1.1) * 3.02;

    float3 rgb = source.rgb + grain * (amplitude * response);
    return float4(rgb, source.a);
  }

}}
