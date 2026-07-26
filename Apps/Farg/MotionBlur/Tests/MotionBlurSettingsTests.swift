//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//

import CoreImage
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
  func liveStrengthSourceClampsAndUpdatesWithoutChangingIdentity() {
    let source = MotionBlurStrengthSource(strength: -10)

    #expect(source.snapshot() == 1)

    source.update(strength: 200)

    #expect(source.snapshot() == 100)
  }

  @Test
  func liveStrengthSourceCanInvalidateAndUnregisterProcessorSessions() {
    let source = MotionBlurStrengthSource(strength: 50)
    let recorder = ProcessorResetRecorder()
    let registrationID = UUID()
    source.registerProcessorSessionResetHandler(id: registrationID) {
      recorder.record()
    }

    source.requestProcessorSessionReset()
    #expect(recorder.count == 1)

    source.unregisterProcessorSessionResetHandler(id: registrationID)
    source.requestProcessorSessionReset()
    #expect(recorder.count == 1)
  }

  @Test
  func currentFrameInstructionRequestsOnlyTheCurrentTrack() {
    let currentTrackID: CMPersistentTrackID = 102
    let geometry = MotionBlurFrameGeometry(
      sourceEncodedSize: CGSize(width: 64, height: 48),
      sourceDisplaySize: CGSize(width: 64, height: 48),
      processorInputSize: CGSize(width: 64, height: 48),
      compositionRenderSize: CGSize(width: 64, height: 48),
      sourceToProcessorTransform: .identity,
      processorToRenderTransform: .identity,
      usesSourceBuffersDirectly: true
    )
    let instruction = MotionBlurCompositionInstruction(
      timeRange: CMTimeRange(
        start: .zero,
        duration: CMTime(value: 1, timescale: 1)
      ),
      previousTrackID: 101,
      currentTrackID: currentTrackID,
      nextTrackID: 103,
      renderingMode: .currentFrame,
      quality: .normal,
      allowsRealtimeFrameDropping: true,
      frameDuration: CMTime(value: 1, timescale: 30),
      geometry: geometry,
      ciContext: CIContext(),
      postProcessor: { image, _ in image }
    )
    let requiredTrackIDs =
      instruction.requiredSourceTrackIDs?
      .compactMap { ($0 as? NSNumber)?.int32Value }

    #expect(instruction.previousTrackID == nil)
    #expect(instruction.nextTrackID == nil)
    #expect(requiredTrackIDs == [currentTrackID])
  }

  @Test
  func currentFramePreservesSourceTimingWhileOpticalFlowUsesFixedCadence() {
    let currentTrackID: CMPersistentTrackID = 102

    #expect(
      MotionBlurVideoCompositionBuilder.sourceTrackIDForFrameTiming(
        mode: .currentFrame,
        currentTrackID: currentTrackID
      ) == currentTrackID
    )
    #expect(
      MotionBlurVideoCompositionBuilder.sourceTrackIDForFrameTiming(
        mode: .opticalFlow(
          strength: MotionBlurStrengthSource(strength: 50)
        ),
        currentTrackID: currentTrackID
      ) == kCMPersistentTrackID_Invalid
    )
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

private final class ProcessorResetRecorder: @unchecked Sendable {

  private let lock = NSLock()
  private var storedCount = 0

  var count: Int {
    lock.lock()
    defer {
      lock.unlock()
    }
    return storedCount
  }

  func record() {
    lock.lock()
    storedCount += 1
    lock.unlock()
  }
}
