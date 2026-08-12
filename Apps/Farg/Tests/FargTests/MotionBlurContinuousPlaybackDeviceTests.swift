import AVFoundation
import BrightroomParametric
import CoreImage
import CoreVideo
import FargMotionBlur
import Foundation
import QuartzCore
import Testing

@testable import Farg

#if !targetEnvironment(simulator)

  /// Physical-device coverage for the VideoToolbox-backed Preview pipeline.
  ///
  /// `FargTests` is hosted by the app, unlike the module's tool-hosted unit-test
  /// bundle, so these tests can execute `VTMotionBlurConfiguration` on iPhone.
  @Suite(.serialized)
  struct MotionBlurContinuousPlaybackDeviceTests {

    /// Renders enough consecutive converted frames to cross the former pool
    /// allocation thresholds without creating a new working set per frame.
    @Test
    func viewportMotionBlurCompletesAContinuousSequence() async throws {
      guard MotionBlurAvailability.isSupported else {
        return
      }

      let expectedFrameCount = 90
      let fixtureURL = try await MotionBlurSequenceFixture.make(
        frameCount: expectedFrameCount
      )
      defer {
        try? FileManager.default.removeItem(at: fixtureURL)
      }

      let prepared = try await MotionBlurVideoCompositionBuilder(
        ciContext: CIContext(),
        allowsRealtimeFrameDropping: false
      )
      .prepare(
        asset: AVURLAsset(url: fixtureURL),
        settings: MotionBlurSettings(isEnabled: true),
        renderTarget: .fitWithin(CGSize(width: 96, height: 64)),
        postProcessor: { image, _, _ in image }
      )
      let renderedFrameCount = try await prepared.renderedFrameCount()

      #expect(renderedFrameCount == expectedFrameCount)
    }

    /// Verifies that temporal and parametric editor changes do not replace the
    /// active item or seek away from the current Preview position.
    @Test
    @MainActor
    func previewEffectChangesPreservePlayerItemAndPlayhead() async throws {
      guard MotionBlurAvailability.isSupported else {
        return
      }

      let fixtureURL = try await MotionBlurSequenceFixture.make(
        frameCount: 90
      )
      defer {
        try? FileManager.default.removeItem(at: fixtureURL)
      }

      let model = VideoPreviewModel()
      let source = VideoSource(appOwnedURL: fixtureURL)
      let document = EditingDocument(
        mainTree: MainTree(features: [])
      )
      model.load(source)
      model.apply(
        recipe: FargVideoRenderRecipe(
          document: document,
          motionBlur: .disabled
        ),
        for: source,
        colorInfo: .sdrRec709
      )
      try await waitUntilPreviewIsReady(model)
      model.pause()

      guard let originalItem = model.player.currentItem else {
        Issue.record("Preview became ready without a player item.")
        return
      }
      let videoOutput = AVPlayerItemVideoOutput(
        pixelBufferAttributes: [
          kCVPixelBufferPixelFormatTypeKey as String:
            Int(kCVPixelFormatType_32BGRA)
        ]
      )
      originalItem.add(videoOutput)
      let expectedTime = CMTime(seconds: 1, preferredTimescale: 600)
      try await seek(model.player, to: expectedTime)
      let disabledComposition = originalItem.videoComposition

      model.apply(
        recipe: FargVideoRenderRecipe(
          document: document,
          motionBlur: MotionBlurSettings(isEnabled: false, strength: 80)
        ),
        for: source,
        colorInfo: .sdrRec709,
        change: .motionBlur
      )
      #expect(model.player.currentItem === originalItem)
      #expect(originalItem.videoComposition === disabledComposition)

      model.apply(
        recipe: FargVideoRenderRecipe(
          document: document,
          motionBlur: MotionBlurSettings(isEnabled: true, strength: 80)
        ),
        for: source,
        colorInfo: .sdrRec709,
        change: .motionBlur
      )
      #expect(model.player.currentItem === originalItem)
      #expect(model.renderState == .ready)
      guard let opticalFlowComposition = originalItem.videoComposition else {
        Issue.record("Enabled Preview has no video composition.")
        return
      }

      model.play()
      let timeAfterEnable = try await waitForPreviewProgress(
        model,
        output: videoOutput,
        after: expectedTime
      )
      model.apply(
        recipe: FargVideoRenderRecipe(
          document: document,
          motionBlur: MotionBlurSettings(isEnabled: true, strength: 95)
        ),
        for: source,
        colorInfo: .sdrRec709,
        change: .motionBlur
      )
      #expect(model.player.currentItem === originalItem)
      #expect(originalItem.videoComposition === opticalFlowComposition)
      let timeAfterStrength = try await waitForPreviewProgress(
        model,
        output: videoOutput,
        after: timeAfterEnable
      )

      model.apply(
        recipe: FargVideoRenderRecipe(
          document: document,
          motionBlur: .disabled
        ),
        for: source,
        colorInfo: .sdrRec709,
        change: .motionBlur
      )
      #expect(model.player.currentItem === originalItem)
      let timeAfterDisable = try await waitForPreviewProgress(
        model,
        output: videoOutput,
        after: timeAfterStrength
      )
      #expect(timeAfterDisable > timeAfterStrength)
      #expect(model.renderState == .ready)

      let currentFrameComposition = try #require(originalItem.videoComposition)
      let grainID = FeatureID(rawValue: "live-preview-grain")
      let enabledGrainDocument = EditingDocument(
        mainTree: MainTree(
          features: [
            .effect(
              FilmGrainFeature(
                id: grainID,
                isEnabled: true,
                intensity: 50,
                size: 50
              )
            )
          ]
        )
      )
      model.apply(
        recipe: FargVideoRenderRecipe(
          document: enabledGrainDocument,
          motionBlur: .disabled
        ),
        for: source,
        colorInfo: .sdrRec709,
        change: .parametricDocument
      )
      #expect(model.player.currentItem === originalItem)
      #expect(originalItem.videoComposition === currentFrameComposition)

      let adjustedGrainDocument = EditingDocument(
        mainTree: MainTree(
          features: [
            .effect(
              FilmGrainFeature(
                id: grainID,
                isEnabled: true,
                intensity: 90,
                size: 75
              )
            )
          ]
        )
      )
      model.apply(
        recipe: FargVideoRenderRecipe(
          document: adjustedGrainDocument,
          motionBlur: .disabled
        ),
        for: source,
        colorInfo: .sdrRec709,
        change: .parametricDocument
      )
      #expect(model.player.currentItem === originalItem)
      #expect(originalItem.videoComposition === currentFrameComposition)

      model.pause()
      model.clear()
    }

    @MainActor
    private func waitUntilPreviewIsReady(
      _ model: VideoPreviewModel
    ) async throws {
      for _ in 0..<200 {
        switch model.renderState {
        case .ready:
          return
        case .failed(let message):
          throw MotionBlurSequenceFixtureError.previewFailed(message)
        case .empty, .preparing:
          try await Task.sleep(for: .milliseconds(25))
        }
      }
      throw MotionBlurSequenceFixtureError.previewTimedOut
    }

    @MainActor
    private func seek(
      _ player: AVPlayer,
      to time: CMTime
    ) async throws {
      let finished = await withCheckedContinuation { continuation in
        player.seek(
          to: time,
          toleranceBefore: .zero,
          toleranceAfter: .zero
        ) { finished in
          continuation.resume(returning: finished)
        }
      }
      guard finished else {
        throw MotionBlurSequenceFixtureError.cannotSeekPreview
      }
    }

    @MainActor
    private func waitForPreviewProgress(
      _ model: VideoPreviewModel,
      output: AVPlayerItemVideoOutput,
      after startTime: CMTime
    ) async throws -> CMTime {
      var renderedFrameCount = 0
      for _ in 0..<200 {
        if case .failed(let message) = model.renderState {
          throw MotionBlurSequenceFixtureError.previewFailed(message)
        }

        let outputTime = output.itemTime(
          forHostTime: CACurrentMediaTime()
        )
        if output.hasNewPixelBuffer(forItemTime: outputTime),
          output.copyPixelBuffer(
            forItemTime: outputTime,
            itemTimeForDisplay: nil
          ) != nil
        {
          renderedFrameCount += 1
        }

        let currentTime = model.player.currentTime()
        if renderedFrameCount >= 2,
          currentTime.seconds >= startTime.seconds + 0.2
        {
          return currentTime
        }
        try await Task.sleep(for: .milliseconds(10))
      }
      throw MotionBlurSequenceFixtureError.previewProgressTimedOut
    }
  }

  private enum MotionBlurSequenceFixture {

    static let encodedSize = CGSize(width: 192, height: 128)
    static let frameDuration = CMTime(value: 1, timescale: 30)

    /// Writes a small moving-color sequence that still forces Preview
    /// downsampling before VideoToolbox.
    static func make(frameCount: Int) async throws -> URL {
      let outputURL = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("mov")
      let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mov)
      let input = AVAssetWriterInput(
        mediaType: .video,
        outputSettings: [
          AVVideoCodecKey: AVVideoCodecType.h264,
          AVVideoWidthKey: Int(encodedSize.width),
          AVVideoHeightKey: Int(encodedSize.height),
        ]
      )
      input.expectsMediaDataInRealTime = false
      let adaptor = AVAssetWriterInputPixelBufferAdaptor(
        assetWriterInput: input,
        sourcePixelBufferAttributes: [
          kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
          kCVPixelBufferWidthKey as String: Int(encodedSize.width),
          kCVPixelBufferHeightKey as String: Int(encodedSize.height),
          kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: String],
        ]
      )

      guard writer.canAdd(input) else {
        throw MotionBlurSequenceFixtureError.cannotAddWriterInput
      }
      writer.add(input)
      guard writer.startWriting() else {
        throw writer.error ?? MotionBlurSequenceFixtureError.cannotStartWriting
      }
      writer.startSession(atSourceTime: .zero)

      let ciContext = CIContext()
      let extent = CGRect(origin: .zero, size: encodedSize)
      for frameIndex in 0..<frameCount {
        while input.isReadyForMoreMediaData == false {
          try await Task.sleep(for: .milliseconds(1))
        }
        let pixelBuffer = try makePixelBuffer()
        let phase = CGFloat(frameIndex % 30) / 29
        let image = CIImage(
          color: CIColor(
            red: phase,
            green: 1 - phase,
            blue: 0.25
          )
        )
        .cropped(to: extent)
        ciContext.render(image, to: pixelBuffer, bounds: extent, colorSpace: nil)
        let presentationTime = CMTimeMultiply(
          frameDuration,
          multiplier: Int32(frameIndex)
        )
        guard adaptor.append(pixelBuffer, withPresentationTime: presentationTime) else {
          throw writer.error ?? MotionBlurSequenceFixtureError.cannotAppendFrame
        }
      }

      input.markAsFinished()
      await writer.finishWriting()
      guard writer.status == .completed else {
        throw writer.error ?? MotionBlurSequenceFixtureError.cannotFinishWriting
      }
      return outputURL
    }

    private static func makePixelBuffer() throws -> CVPixelBuffer {
      var pixelBuffer: CVPixelBuffer?
      let status = CVPixelBufferCreate(
        kCFAllocatorDefault,
        Int(encodedSize.width),
        Int(encodedSize.height),
        kCVPixelFormatType_32BGRA,
        [
          kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: String]
        ] as CFDictionary,
        &pixelBuffer
      )
      guard status == kCVReturnSuccess, let pixelBuffer else {
        throw MotionBlurSequenceFixtureError.cannotCreatePixelBuffer(status)
      }
      return pixelBuffer
    }
  }

  extension PreparedMotionBlurVideo {

    /// Reads the full composition through one custom-compositor instance.
    fileprivate func renderedFrameCount() async throws -> Int {
      let videoTracks = try await asset.loadTracks(withMediaType: .video)
      let output = AVAssetReaderVideoCompositionOutput(
        videoTracks: videoTracks,
        videoSettings: [
          kCVPixelBufferPixelFormatTypeKey as String:
            Int(kCVPixelFormatType_32BGRA)
        ]
      )
      output.videoComposition = videoComposition
      output.alwaysCopiesSampleData = false

      let reader = try AVAssetReader(asset: asset)
      guard reader.canAdd(output) else {
        throw MotionBlurSequenceFixtureError.cannotAddReaderOutput
      }
      reader.add(output)
      guard reader.startReading() else {
        throw reader.error ?? MotionBlurSequenceFixtureError.cannotStartReading
      }

      var frameCount = 0
      while output.copyNextSampleBuffer() != nil {
        frameCount += 1
      }
      guard reader.status == .completed else {
        throw reader.error ?? MotionBlurSequenceFixtureError.cannotFinishReading
      }
      return frameCount
    }
  }

  private enum MotionBlurSequenceFixtureError: Error {
    case cannotAddWriterInput
    case cannotStartWriting
    case cannotAppendFrame
    case cannotFinishWriting
    case cannotCreatePixelBuffer(CVReturn)
    case cannotAddReaderOutput
    case cannotStartReading
    case cannotFinishReading
    case cannotSeekPreview
    case previewFailed(String)
    case previewProgressTimedOut
    case previewTimedOut
  }

#endif
