//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//

import CoreMedia
import Testing

@testable import FargMotionBlur

struct MotionBlurSettingsTests {

  @Test
  func initializerClampsStrengthToVideoToolboxRange() {
    #expect(MotionBlurSettings(strength: -10).strength == 1)
    #expect(MotionBlurSettings(strength: 200).strength == 100)
  }

  @Test
  func mutationClampsStrengthToVideoToolboxRange() {
    var settings = MotionBlurSettings(isEnabled: true, strength: 50)
    settings.strength = 0
    #expect(settings.strength == 1)

    settings.strength = 101
    #expect(settings.strength == 100)
  }

  @Test
  func disabledRecipeBypassesTemporalRendering() {
    #expect(MotionBlurSettings.disabled.isEnabled == false)
    #expect(MotionBlurSettings.disabled.strength == 50)
  }

  @Test
  func exactTrackCadenceWinsWhenItMatchesNominalRate() {
    let exactNTSC = CMTime(value: 1_001, timescale: 30_000)
    let resolved = MotionBlurVideoCompositionBuilder.resolveFrameDuration(
      minimumFrameDuration: exactNTSC,
      nominalFrameRate: 29.97
    )

    #expect(resolved == exactNTSC)
  }

  @Test
  func variableFrameRateMinimumDoesNotBecomeOutputCadence() {
    let resolved = MotionBlurVideoCompositionBuilder.resolveFrameDuration(
      minimumFrameDuration: CMTime(value: 1, timescale: 240),
      nominalFrameRate: 30
    )

    #expect(abs(resolved.seconds - (1 / 30.0)) < 0.000_001)
  }

  @Test
  func validHighRateMinimumRemainsAvailableWithoutNominalRate() {
    let resolved = MotionBlurVideoCompositionBuilder.resolveFrameDuration(
      minimumFrameDuration: CMTime(value: 1, timescale: 1_000),
      nominalFrameRate: 0
    )

    #expect(resolved == CMTime(value: 1, timescale: 1_000))
  }

  @Test
  func lowNominalFrameRateIsNotReplacedByThirtyFramesPerSecond() {
    let resolved = MotionBlurVideoCompositionBuilder.resolveFrameDuration(
      minimumFrameDuration: CMTime(value: 2, timescale: 1),
      nominalFrameRate: 0.5
    )

    #expect(resolved == CMTime(value: 2, timescale: 1))
  }

  @Test
  func invalidCadenceFallsBackToThirtyFramesPerSecond() {
    let resolved = MotionBlurVideoCompositionBuilder.resolveFrameDuration(
      minimumFrameDuration: .invalid,
      nominalFrameRate: 0
    )

    #expect(resolved == CMTime(value: 1, timescale: 30))
  }

  #if targetEnvironment(simulator)
    @Test
    func simulatorReportsOpticalFlowAsUnavailable() {
      #expect(MotionBlurAvailability.isSupported == false)
    }
  #endif
}
