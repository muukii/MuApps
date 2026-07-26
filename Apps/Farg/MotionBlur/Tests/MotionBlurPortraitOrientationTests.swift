//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//

import AVFoundation
import CoreImage
import CoreVideo
import Testing

@testable import FargMotionBlur

struct MotionBlurPortraitTransformTests {

  private let encodedSize = CGSize(width: 1_920, height: 1_080)

  @Test
  func landscapeIdentityTransformRemainsUnchanged() throws {
    let geometry = try MotionBlurVideoCompositionBuilder.resolveGeometry(
      naturalSize: encodedSize,
      preferredTransform: .identity
    )

    #expect(geometry.renderSize == encodedSize)
    #expect(geometry.coreImageTransform == .identity)
  }

  @Test
  func clockwisePortraitTrackTransformIsConvertedToCoreImageCoordinates() throws {
    let avFoundationTransform = CGAffineTransform(
      a: 0,
      b: 1,
      c: -1,
      d: 0,
      tx: encodedSize.height,
      ty: 0
    )

    let geometry = try MotionBlurVideoCompositionBuilder.resolveGeometry(
      naturalSize: encodedSize,
      preferredTransform: avFoundationTransform
    )

    #expect(geometry.renderSize == CGSize(width: 1_080, height: 1_920))
    #expect(
      geometry.coreImageTransform
        == CGAffineTransform(
          a: 0,
          b: -1,
          c: 1,
          d: 0,
          tx: 0,
          ty: encodedSize.width
        )
    )
  }

  @Test
  func counterclockwisePortraitTrackTransformIsConvertedToCoreImageCoordinates() throws {
    let avFoundationTransform = CGAffineTransform(
      a: 0,
      b: -1,
      c: 1,
      d: 0,
      tx: 0,
      ty: encodedSize.width
    )

    let geometry = try MotionBlurVideoCompositionBuilder.resolveGeometry(
      naturalSize: encodedSize,
      preferredTransform: avFoundationTransform
    )

    #expect(geometry.renderSize == CGSize(width: 1_080, height: 1_920))
    #expect(
      geometry.coreImageTransform
        == CGAffineTransform(
          a: 0,
          b: 1,
          c: -1,
          d: 0,
          tx: encodedSize.height,
          ty: 0
        )
    )
  }

  @Test
  func metadataPortraitPreviewUsesUniformViewportScale() throws {
    let sourceSize = CGSize(width: 3_840, height: 2_160)
    let portraitTransform = CGAffineTransform(
      a: 0,
      b: 1,
      c: -1,
      d: 0,
      tx: sourceSize.height,
      ty: 0
    )

    let geometry = try MotionBlurVideoCompositionBuilder.resolveFrameGeometry(
      naturalSize: sourceSize,
      preferredTransform: portraitTransform,
      renderTarget: .fitWithin(CGSize(width: 468, height: 834))
    )

    #expect(geometry.sourceEncodedSize == sourceSize)
    #expect(geometry.sourceDisplaySize == CGSize(width: 2_160, height: 3_840))
    #expect(geometry.processorInputSize == CGSize(width: 832, height: 468))
    #expect(geometry.compositionRenderSize == CGSize(width: 468, height: 832))
    #expect(geometry.usesSourceBuffersDirectly == false)
  }

  @Test
  func physicallyStoredPortraitCanBeDownsampledBeforeTheHardwareLimit() throws {
    let sourceSize = CGSize(width: 2_160, height: 3_840)

    let geometry = try MotionBlurVideoCompositionBuilder.resolveFrameGeometry(
      naturalSize: sourceSize,
      preferredTransform: .identity,
      renderTarget: .fitWithin(CGSize(width: 468, height: 834))
    )

    #expect(geometry.sourceDisplaySize == sourceSize)
    #expect(geometry.processorInputSize == CGSize(width: 468, height: 832))
    #expect(geometry.compositionRenderSize == CGSize(width: 468, height: 832))
    #expect(geometry.usesSourceBuffersDirectly == false)
  }

  @Test
  func sourceResolutionPhysicalPortraitIsCanonicalizedOnlyForProcessor() throws {
    let sourceSize = CGSize(width: 2_160, height: 3_840)

    let geometry = try MotionBlurVideoCompositionBuilder.resolveFrameGeometry(
      naturalSize: sourceSize,
      preferredTransform: .identity,
      renderTarget: .source
    )

    #expect(geometry.sourceDisplaySize == sourceSize)
    #expect(geometry.processorInputSize == CGSize(width: 3_840, height: 2_160))
    #expect(geometry.compositionRenderSize == sourceSize)
    #expect(geometry.usesSourceBuffersDirectly == false)
    #expect(
      geometry.sourceToProcessorTransform.concatenating(
        geometry.processorToRenderTransform
      ) == .identity
    )
  }

  @Test
  func sourceResolutionLandscapeKeepsDecodedBuffersDirect() throws {
    let sourceSize = CGSize(width: 3_840, height: 2_160)

    let geometry = try MotionBlurVideoCompositionBuilder.resolveFrameGeometry(
      naturalSize: sourceSize,
      preferredTransform: .identity,
      renderTarget: .source
    )

    #expect(geometry.processorInputSize == sourceSize)
    #expect(geometry.compositionRenderSize == sourceSize)
    #expect(geometry.sourceToProcessorTransform == .identity)
    #expect(geometry.processorToRenderTransform == .identity)
    #expect(geometry.usesSourceBuffersDirectly)
  }

  @Test
  func subTwoPixelRenderTargetIsRejectedInsteadOfUpscaled() {
    #expect(throws: MotionBlurError.invalidFrameSize(CGSize(width: 1, height: 480))) {
      try MotionBlurVideoCompositionBuilder.resolveFrameGeometry(
        naturalSize: CGSize(width: 1_920, height: 1_080),
        preferredTransform: .identity,
        renderTarget: .fitWithin(CGSize(width: 1, height: 480))
      )
    }
  }
}

#if !targetEnvironment(simulator)

  struct MotionBlurPortraitOrientationTests {

    /// Verifies that Färg preserves the visual orientation already defined by
    /// an asset's portrait preferred transform.
    ///
    /// The asymmetric four-color frame makes vertical inversion observable
    /// without relying on a person's face or text in a checked-in fixture.
    @Test
    func portraitMotionBlurMatchesTheSourceTrackOrientation() async throws {
      guard MotionBlurAvailability.isSupported else {
        // The concrete device, rather than the deployment target, determines
        // whether VideoToolbox exposes VTMotionBlurConfiguration.
        return
      }

      let fixtureURL = try await PortraitVideoFixture.make()
      defer {
        try? FileManager.default.removeItem(at: fixtureURL)
      }

      let sourceAsset = AVURLAsset(url: fixtureURL)
      let sourceImage = try await sourceAsset.orientationReferenceImage()
      let prepared = try await MotionBlurVideoCompositionBuilder(
        ciContext: CIContext()
      )
      .prepare(
        asset: sourceAsset,
        settings: MotionBlurSettings(isEnabled: true),
        renderTarget: .source,
        postProcessor: { image, _ in image }
      )
      let renderedImage = try await prepared.orientationRenderedImage()
      let sourceSignature = try sourceImage.cornerSignature
      let renderedSignature = try renderedImage.cornerSignature

      #expect(renderedImage.width == sourceImage.width)
      #expect(renderedImage.height == sourceImage.height)
      #expect(
        renderedSignature == sourceSignature,
        """
        Portrait orientation changed while applying motion blur.
        source: \(sourceSignature)
        rendered: \(renderedSignature)
        """
      )
    }

    /// Exercises the IOSurface source pool used by viewport-sized Preview.
    ///
    /// The source remains metadata-rotated landscape pixels, while every
    /// temporal input is resized before VideoToolbox and returned as an upright
    /// portrait frame.
    @Test
    func portraitViewportMotionBlurUsesWorkingBuffersWithoutChangingOrientation() async throws {
      guard MotionBlurAvailability.isSupported else {
        return
      }

      let fixtureURL = try await PortraitVideoFixture.make()
      defer {
        try? FileManager.default.removeItem(at: fixtureURL)
      }

      let sourceAsset = AVURLAsset(url: fixtureURL)
      let sourceImage = try await sourceAsset.orientationReferenceImage()
      let prepared = try await MotionBlurVideoCompositionBuilder(
        ciContext: CIContext()
      )
      .prepare(
        asset: sourceAsset,
        settings: MotionBlurSettings(isEnabled: true),
        renderTarget: .fitWithin(CGSize(width: 32, height: 48)),
        postProcessor: { image, _ in image }
      )
      let renderedImage = try await prepared.orientationRenderedImage()

      #expect(renderedImage.width == 32)
      #expect(renderedImage.height == 48)
      #expect(try renderedImage.cornerSignature == sourceImage.cornerSignature)
    }
  }

  private enum PortraitVideoFixture {

    static let encodedSize = CGSize(width: 96, height: 64)
    static let frameDuration = CMTime(value: 1, timescale: 30)

    /// Writes a landscape-encoded frame carrying the same +90-degree preferred
    /// transform used by portrait iPhone movies.
    static func make() async throws -> URL {
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
      input.transform = CGAffineTransform(
        a: 0,
        b: 1,
        c: -1,
        d: 0,
        tx: encodedSize.height,
        ty: 0
      )

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
        throw FixtureError.cannotAddWriterInput
      }
      writer.add(input)
      guard writer.startWriting() else {
        throw writer.error ?? FixtureError.cannotStartWriting
      }
      writer.startSession(atSourceTime: .zero)

      for frameIndex in 0..<4 {
        while !input.isReadyForMoreMediaData {
          try await Task.sleep(for: .milliseconds(1))
        }
        let pixelBuffer = try makeAsymmetricPixelBuffer()
        let presentationTime = CMTimeMultiply(frameDuration, multiplier: Int32(frameIndex))
        guard adaptor.append(pixelBuffer, withPresentationTime: presentationTime) else {
          throw writer.error ?? FixtureError.cannotAppendFrame
        }
      }

      input.markAsFinished()
      await writer.finishWriting()
      guard writer.status == .completed else {
        throw writer.error ?? FixtureError.cannotFinishWriting
      }
      return outputURL
    }

    private static func makeAsymmetricPixelBuffer() throws -> CVPixelBuffer {
      var optionalPixelBuffer: CVPixelBuffer?
      let status = CVPixelBufferCreate(
        kCFAllocatorDefault,
        Int(encodedSize.width),
        Int(encodedSize.height),
        kCVPixelFormatType_32BGRA,
        [
          kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: String]
        ] as CFDictionary,
        &optionalPixelBuffer
      )
      guard status == kCVReturnSuccess, let pixelBuffer = optionalPixelBuffer else {
        throw FixtureError.cannotCreatePixelBuffer(status)
      }

      CVPixelBufferLockBaseAddress(pixelBuffer, [])
      defer {
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
      }
      guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
        throw FixtureError.missingPixelBufferStorage
      }

      let width = CVPixelBufferGetWidth(pixelBuffer)
      let height = CVPixelBufferGetHeight(pixelBuffer)
      let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
      for y in 0..<height {
        let row =
          baseAddress
          .advanced(by: y * bytesPerRow)
          .assumingMemoryBound(to: UInt8.self)
        for x in 0..<width {
          let color: BGRAColor
          switch (x < width / 2, y < height / 2) {
          case (true, true):
            color = .red
          case (false, true):
            color = .green
          case (true, false):
            color = .blue
          case (false, false):
            color = .yellow
          }
          let offset = x * 4
          row[offset] = color.blue
          row[offset + 1] = color.green
          row[offset + 2] = color.red
          row[offset + 3] = 255
        }
      }
      return pixelBuffer
    }
  }

  private struct BGRAColor {
    static let red = Self(blue: 0, green: 0, red: 255)
    static let green = Self(blue: 0, green: 255, red: 0)
    static let blue = Self(blue: 255, green: 0, red: 0)
    static let yellow = Self(blue: 0, green: 255, red: 255)

    let blue: UInt8
    let green: UInt8
    let red: UInt8
  }

  private enum FixtureError: Error {
    case cannotAddWriterInput
    case cannotStartWriting
    case cannotAppendFrame
    case cannotFinishWriting
    case cannotCreatePixelBuffer(CVReturn)
    case missingPixelBufferStorage
    case cannotCreateBitmapContext
  }

  extension AVAsset {

    fileprivate func orientationReferenceImage() async throws -> CGImage {
      nonisolated(unsafe) let generator = AVAssetImageGenerator(asset: self)
      generator.appliesPreferredTrackTransform = true
      generator.requestedTimeToleranceBefore = .zero
      generator.requestedTimeToleranceAfter = .zero
      return try await generator.image(
        at: PortraitVideoFixture.frameDuration
      ).image
    }
  }

  extension PreparedMotionBlurVideo {

    fileprivate func orientationRenderedImage() async throws -> CGImage {
      nonisolated(unsafe) let generator = AVAssetImageGenerator(asset: asset)
      generator.videoComposition = videoComposition
      generator.requestedTimeToleranceBefore = .zero
      generator.requestedTimeToleranceAfter = .zero
      return try await generator.image(
        at: PortraitVideoFixture.frameDuration
      ).image
    }
  }

  extension CGImage {

    fileprivate var cornerSignature: [DominantColor] {
      get throws {
        let bytesPerPixel = 4
        let bytesPerRow = width * bytesPerPixel
        var bytes = [UInt8](repeating: 0, count: height * bytesPerRow)
        return try bytes.withUnsafeMutableBytes { storage in
          guard
            let context = CGContext(
              data: storage.baseAddress,
              width: width,
              height: height,
              bitsPerComponent: 8,
              bytesPerRow: bytesPerRow,
              space: CGColorSpace(name: CGColorSpace.sRGB)!,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
          else {
            throw FixtureError.cannotCreateBitmapContext
          }
          context.draw(self, in: CGRect(x: 0, y: 0, width: width, height: height))

          let normalizedSamplePoints = [
            CGPoint(x: 0.25, y: 0.25),
            CGPoint(x: 0.75, y: 0.25),
            CGPoint(x: 0.25, y: 0.75),
            CGPoint(x: 0.75, y: 0.75),
          ]
          return normalizedSamplePoints.map { point in
            let x = min(Int(CGFloat(width) * point.x), width - 1)
            let y = min(Int(CGFloat(height) * point.y), height - 1)
            let offset = y * bytesPerRow + x * bytesPerPixel
            return DominantColor(
              red: storage[offset],
              green: storage[offset + 1],
              blue: storage[offset + 2]
            )
          }
        }
      }
    }
  }

  private enum DominantColor: String {
    case red
    case green
    case blue
    case yellow

    init(red: UInt8, green: UInt8, blue: UInt8) {
      if red > 160, green > 160 {
        self = .yellow
      } else if red >= green, red >= blue {
        self = .red
      } else if green >= blue {
        self = .green
      } else {
        self = .blue
      }
    }
  }

#endif
