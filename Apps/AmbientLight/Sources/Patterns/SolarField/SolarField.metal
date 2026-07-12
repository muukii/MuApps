#include <metal_stdlib>
using namespace metal;

/// Renders a warm circular light field over OLED black with a breathing EDR rim.
[[ stitchable ]] half4 solarField(
  float2 position,
  half4 currentColor,
  float2 size,
  float time,
  float horizontalOffset,
  float verticalOffset,
  float radius,
  float rimWidth,
  float bloomWidth,
  float headroom,
  half4 centerColor,
  half4 middleColor,
  half4 edgeColor,
  half4 rimColor
) {
  float2 safeSize = max(size, float2(1.0));

  // These anchors reproduce the supplied landscape composition while offsets remain interactive.
  float2 center = float2(
    0.5 + horizontalOffset,
    0.716 - verticalOffset
  );
  float radiusInPixels = max(radius * min(safeSize.x, safeSize.y), 1.0);
  float2 vectorFromCenter = position - center * safeSize;
  float2 normalizedPosition = vectorFromCenter / radiusInPixels;
  float radialDistance = length(normalizedPosition);
  float angle = atan2(vectorFromCenter.y, vectorFromCenter.x);

  // The color core wanders inside a silhouette that remains geometrically fixed.
  constexpr float twoPi = 6.28318530718;
  float2 coreOffset = float2(
    sin(time * twoPi / 61.0) * 0.020,
    sin(time * twoPi / 79.0 + 1.7) * 0.017
  );
  float2 colorPosition = normalizedPosition - coreOffset;
  float colorRadius = length(colorPosition);
  float colorAngle = atan2(colorPosition.y, colorPosition.x);

  // Counter-rotating broad cells move the color field like slow solar convection.
  float convectionA = sin(
    colorAngle * 3.0 + colorRadius * 10.5 - time * twoPi / 47.0
  );
  float convectionB = sin(
    colorAngle * 5.0 - colorRadius * 14.0
      + time * twoPi * 1.41421356237 / 71.0
  );
  float convection = clamp(convectionA * 0.62 + convectionB * 0.38, -1.0, 1.0);
  float convectionSupport = smoothstep(0.08, 0.22, colorRadius)
    * (1.0 - smoothstep(0.76, 0.96, radialDistance));
  float coreInfluence = 1.0 - smoothstep(0.70, 0.96, radialDistance);
  float colorDistance = mix(radialDistance, colorRadius, coreInfluence)
    + convection * convectionSupport * 0.032;
  float colorBreath = sin(time * twoPi / 37.0) * 0.010;

  // Broad transitions preserve saturated red at the center and reserve gold for the perimeter.
  float centerToMiddle = smoothstep(
    0.10 + colorBreath,
    0.68 + colorBreath,
    colorDistance
  );
  float middleToEdge = smoothstep(
    0.55 - colorBreath * 0.35,
    0.95,
    colorDistance
  );
  float3 interiorColor = mix(
    float3(centerColor.rgb),
    float3(middleColor.rgb),
    centerToMiddle
  );
  interiorColor = mix(interiorColor, float3(edgeColor.rgb), middleToEdge);
  interiorColor *= 1.0 + convection * convectionSupport * 0.10;

  // Convection changes SDR color and luminance; the rim alone owns EDR emission.
  float interiorMaximumComponent = max(
    max(interiorColor.r, interiorColor.g),
    interiorColor.b
  );
  if (interiorMaximumComponent > 1.0) {
    interiorColor *= 1.0 / interiorMaximumComponent;
  }

  float safeRimWidth = max(rimWidth, 0.001);
  float rimPosition = (radialDistance - 1.0) / safeRimWidth;
  float rimEnergy = exp(-rimPosition * rimPosition);

  // One localized flare orbits the circle while two slower waves make it wax and recede.
  float flareAngle = time * twoPi / 43.0 - 0.8;
  float flareAlignment = cos(angle - flareAngle);
  float flareAngular = smoothstep(0.94, 0.995, flareAlignment);
  flareAngular *= flareAngular;
  float flareLife = clamp(
    0.50
      + sin(time * twoPi / 31.0 + 1.1) * 0.32
      + sin(time * twoPi / 47.0 + 2.7) * 0.18,
    0.0,
    1.0
  );
  float flareStrength = mix(0.35, 1.0, smoothstep(0.15, 0.85, flareLife));
  float flareRadial = sqrt(rimEnergy);

  // The bloom is part of the emitted light, not the background, and reaches exact zero.
  float circleMask = 1.0 - smoothstep(1.0, 1.012, radialDistance);
  float outsideDistance = max(radialDistance - 1.0, 0.0);
  float exteriorBloom = 1.0 - smoothstep(
    0.0,
    max(bloomWidth, 0.006),
    outsideDistance
  );
  exteriorBloom *= smoothstep(0.994, 1.004, radialDistance);

  float3 result = interiorColor * circleMask;

  float3 bloomColor = mix(
    float3(edgeColor.rgb),
    float3(rimColor.rgb),
    0.35
  );
  float bloomGain = 0.50 + flareAngular * flareStrength * 0.28;
  result = max(result, bloomColor * exteriorBloom * bloomGain);

  // The ordinary rim remains below peak so the moving flare has visible HDR contrast.
  float pulsePhase = 0.5 + 0.5 * sin(time * twoPi / 23.0);
  float baseRimFraction = mix(0.62, 0.78, pow(pulsePhase, 1.35));
  float availableHeadroom = max(headroom, 1.0);
  float lightSupport = max(circleMask, exteriorBloom);
  float flareMask = flareAngular * flareStrength * flareRadial * lightSupport;
  float rimPeak = availableHeadroom * mix(baseRimFraction, 1.0, flareMask);

  float3 sourceRimColor = float3(rimColor.rgb);
  float rimMaximumComponent = max(
    max(sourceRimColor.r, sourceRimColor.g),
    max(sourceRimColor.b, 0.0001)
  );
  float rimEmissionScale = max(1.0, rimPeak / rimMaximumComponent);
  float3 emittedRimColor = sourceRimColor * rimEmissionScale;
  float localRimEnergy = mix(
    rimEnergy,
    flareRadial,
    flareAngular * flareStrength
  );
  float rimBlend = clamp(localRimEnergy * lightSupport, 0.0, 1.0);
  result = mix(result, emittedRimColor, rimBlend);

  // Preserve hue if a custom color combination would otherwise exceed the live limit.
  float maximumComponent = max(max(result.r, result.g), result.b);
  if (maximumComponent > availableHeadroom) {
    result *= availableHeadroom / maximumComponent;
  }

  return half4(half3(result), 1.0h);
}
