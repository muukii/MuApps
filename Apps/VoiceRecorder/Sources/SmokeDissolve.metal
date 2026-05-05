#include <SwiftUI/SwiftUI_Metal.h>
using namespace metal;

float hash21(float2 value) {
  float2 p = fract(value * float2(123.34, 456.21));
  p += dot(p, p + 45.32);
  return fract(p.x * p.y);
}

float valueNoise(float2 value) {
  float2 cell = floor(value);
  float2 local = fract(value);
  local = local * local * (3.0 - 2.0 * local);

  float a = hash21(cell);
  float b = hash21(cell + float2(1.0, 0.0));
  float c = hash21(cell + float2(0.0, 1.0));
  float d = hash21(cell + float2(1.0, 1.0));

  return mix(mix(a, b, local.x), mix(c, d, local.x), local.y);
}

float layeredNoise(float2 value) {
  float base = valueNoise(value);
  float detail = valueNoise(value * 2.11 + float2(17.13, 11.71));
  return base * 0.68 + detail * 0.32;
}

[[ stitchable ]]
half4 smokeDissolve(float2 position, SwiftUI::Layer layer, float progress, float time, float2 size) {
  float amount = clamp(progress, 0.0, 1.0);
  float smoke = smoothstep(0.0, 1.0, amount);
  float2 safeSize = max(size, float2(1.0, 1.0));
  float2 uv = position / safeSize;

  float broadNoise = layeredNoise(uv * float2(4.2, 7.0) + float2(time * 0.16, -time * 0.22));
  float fineNoise = layeredNoise(uv * float2(18.0, 15.0) + float2(-time * 0.28, time * 0.18));

  float lift = smoke * smoke * (12.0 + broadNoise * 26.0);
  float sway = (broadNoise - 0.5) * smoke * 18.0;

  float2 samplePosition = position + float2(-sway, lift);
  half4 color = layer.sample(samplePosition);

  float topBias = (1.0 - uv.y) * smoke * 0.16;
  float dissolveField = broadNoise * 0.68 + fineNoise * 0.32 + topBias;
  float threshold = amount * 1.05 - 0.07;
  float bodyMask = smoothstep(threshold - 0.16, threshold + 0.16, dissolveField);

  float particleField = smoothstep(0.78 - amount * 0.24, 1.0, fineNoise);
  float particleMask = particleField * smoke * (1.0 - amount);
  float alpha = max(bodyMask * (1.0 - smoke * 0.34), particleMask * 0.9);

  color.a *= half(clamp(alpha, 0.0, 1.0));

  float ash = smoothstep(0.28, 1.0, smoke) * (1.0 - bodyMask) * 0.26;
  color.rgb = mix(color.rgb, half3(0.74, 0.76, 0.72), half(ash));

  return color;
}
