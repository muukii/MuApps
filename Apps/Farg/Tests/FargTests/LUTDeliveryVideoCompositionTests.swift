import AVFoundation
import BrightroomParametric
import CoreMedia
import CoreVideo
import FargMotionBlur
import Foundation
import Testing

@testable import Farg

/// Exercises the final LUT delivery transform through Färg's real video
/// composition path without depending on device-only Optical Flow.
@Suite("LUT delivery video composition", .serialized)
struct LUTDeliveryVideoCompositionTests {

  @Test
  func previewAndExportApplyOneCoreMediaDeliveryTransform() async throws {
    let fixtureURL = try await NeutralRec709VideoFixture.make()
    defer {
      try? FileManager.default.removeItem(at: fixtureURL)
    }

    let asset = AVURLAsset(url: fixtureURL)
    let recipe = FargVideoRenderRecipe(
      document: ConstantRec709ColorCubeFixture.document,
      motionBlur: .disabled,
      lutOutputColorSpace: .rec709
    )
    let pipeline = FargVideoRenderPipeline()
    let previewSource = try await pipeline.prepareTemporalPreviewSource(
      asset: asset
    )
    let previewTarget = try #require(
      FargPreviewRenderTarget(
        maximumPixelSize: NeutralRec709VideoFixture.encodedSize
      )
    )
    let preview = try pipeline.makeTemporalPreview(
      source: previewSource,
      recipe: recipe,
      colorInfo: .sdrRec709,
      target: previewTarget,
      strengthSource: MotionBlurStrengthSource(strength: 0)
    )
    let export = try await pipeline.prepare(
      asset: asset,
      recipe: recipe,
      colorInfo: .sdrRec709,
      purpose: .export
    )
    let masteringReference = try makeMasteringReference(
      source: previewSource,
      recipe: recipe
    )

    let previewLuma = try await EncoderFacingLuma.read(from: preview)
    let exportLuma = try await EncoderFacingLuma.read(from: export)
    let masteringLuma = try await EncoderFacingLuma.read(
      from: masteringReference
    )
    let expectedDeliveryLuma = Self.expectedDeliveryLuma(
      fromMasteringLuma: masteringLuma
    )

    #expect(preview.outputColorInfo == .sdrRec709)
    #expect(export.outputColorInfo == .sdrRec709)
    #expect(abs(previewLuma - exportLuma) <= 1)

    // Derive the one-pass expectation from the same LUT graph materialized in
    // its Gamma-2.4 mastering space. This keeps cube interpolation and source
    // decoding outside the delivery assertion.
    #expect(
      abs(previewLuma - expectedDeliveryLuma) <= 2,
      """
      The video composition did not apply exactly one Core Media delivery transform.
      mastering Y': \(masteringLuma)
      expected delivery Y': \(expectedDeliveryLuma)
      preview Y': \(previewLuma)
      export Y': \(exportLuma)
      """
    )
  }

  /// Builds the same current-frame graph with its Rec.709 mastering destination
  /// so the delivery assertion has an independent, pre-compensation baseline.
  private func makeMasteringReference(
    source: PreparedMotionBlurSource,
    recipe: FargVideoRenderRecipe
  ) throws -> PreparedFargVideoRender {
    let renderer = ParametricVideoRenderer()
    let composition = try MotionBlurVideoCompositionBuilder(
      ciContext: FargCIContext.shared
    )
    .makeVideoComposition(
      source: source,
      mode: .currentFrame,
      renderTarget: .source,
      outputColorSpace:
        FargLUTOutputColorSpace.rec709.lutResultColorSpace
    ) { image, renderExtent in
      try renderer.makeFrameImage(
        from: image,
        document: recipe.document,
        renderExtent: renderExtent
      )
    }
    VideoColorInfo.sdrRec709.apply(to: composition)
    return PreparedFargVideoRender(
      asset: source.asset,
      videoComposition: composition,
      outputColorInfo: .sdrRec709
    )
  }

  /// Converts an encoder-facing video-range neutral value through the pure
  /// Gamma-2.4 to Core Media Gamma-1.961 delivery relationship.
  private static func expectedDeliveryLuma(
    fromMasteringLuma masteringLuma: Double
  ) -> Double {
    let normalizedMastering = (masteringLuma - 16) / 219
    let normalizedDelivery = pow(
      normalizedMastering,
      2.4 / 1.961
    )
    return 16 + normalizedDelivery * 219
  }
}

/// A short tagged Rec.709 movie whose neutral midtone makes zero, one, and two
/// delivery transforms distinguishable at the encoder-facing pixel buffer.
private enum NeutralRec709VideoFixture {

  static let encodedSize = CGSize(width: 64, height: 64)
  private static let frameDuration = CMTime(value: 1, timescale: 30)
  private static let frameCount = 4

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
        AVVideoColorPropertiesKey: VideoColorInfo.sdrRec709.avVideoColorProperties,
      ]
    )
    input.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
      assetWriterInput: input,
      sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String:
          Int(kCVPixelFormatType_32BGRA),
        kCVPixelBufferWidthKey as String: Int(encodedSize.width),
        kCVPixelBufferHeightKey as String: Int(encodedSize.height),
        kCVPixelBufferIOSurfacePropertiesKey as String:
          [:] as [String: String],
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

    for frameIndex in 0..<frameCount {
      while input.isReadyForMoreMediaData == false {
        try await Task.sleep(for: .milliseconds(1))
      }
      let pixelBuffer = try makePixelBuffer()
      let presentationTime = CMTimeMultiply(
        frameDuration,
        multiplier: Int32(frameIndex)
      )
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

  private static func makePixelBuffer() throws -> CVPixelBuffer {
    var pixelBuffer: CVPixelBuffer?
    let status = CVPixelBufferCreate(
      kCFAllocatorDefault,
      Int(encodedSize.width),
      Int(encodedSize.height),
      kCVPixelFormatType_32BGRA,
      [
        kCVPixelBufferIOSurfacePropertiesKey as String:
          [:] as [String: String]
      ] as CFDictionary,
      &pixelBuffer
    )
    guard status == kCVReturnSuccess, let pixelBuffer else {
      throw FixtureError.cannotCreatePixelBuffer(status)
    }

    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    defer {
      CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
    }
    guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
      throw FixtureError.missingPixelBufferStorage
    }
    let height = CVPixelBufferGetHeight(pixelBuffer)
    let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
    memset(baseAddress, 128, bytesPerRow * height)
    for y in 0..<height {
      let row =
        baseAddress
        .advanced(by: y * bytesPerRow)
        .assumingMemoryBound(to: UInt8.self)
      for alphaOffset in stride(from: 3, to: bytesPerRow, by: 4) {
        row[alphaOffset] = 255
      }
    }
    return pixelBuffer
  }
}

/// A two-node cube that authors an exact Rec.709 midtone independently of its
/// input, isolating the final delivery materialization from source conversion.
private enum ConstantRec709ColorCubeFixture {

  static let document = EditingDocument(
    mainTree: MainTree(
      features: [
        .effect(
          ColorCubeFeature(
            id: FeatureID(rawValue: "delivery-integration.constant-midtone"),
            name: "Constant Midtone",
            identifier: "delivery-integration.constant-midtone-2",
            dimension: 2,
            cubeData: makeCubeData()
          )
        )
      ]
    )
  )

  private static func makeCubeData() -> Data {
    var values = [Float](repeating: 0.5, count: 2 * 2 * 2 * 4)
    for alphaIndex in stride(from: 3, to: values.count, by: 4) {
      values[alphaIndex] = 1
    }
    return values.withUnsafeBufferPointer(Data.init)
  }
}

/// Samples luma before AVAssetWriter encoding.
private enum EncoderFacingLuma {

  static func read(
    from prepared: PreparedFargVideoRender
  ) async throws -> Double {
    let tracks = try await prepared.asset.loadTracks(withMediaType: .video)
    guard tracks.isEmpty == false else {
      throw FixtureError.missingVideoTrack
    }
    let reader = try AVAssetReader(asset: prepared.asset)
    let output = AVAssetReaderVideoCompositionOutput(
      videoTracks: tracks,
      videoSettings: [
        kCVPixelBufferPixelFormatTypeKey as String:
          Int(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
        AVVideoColorPropertiesKey:
          prepared.outputColorInfo.avVideoColorProperties,
      ]
    )
    output.videoComposition = prepared.videoComposition
    guard reader.canAdd(output) else {
      throw FixtureError.cannotAddReaderOutput
    }
    reader.add(output)
    guard reader.startReading() else {
      throw reader.error ?? FixtureError.cannotStartReading
    }
    defer {
      if reader.status == .reading {
        reader.cancelReading()
      }
    }

    guard
      let sampleBuffer = output.copyNextSampleBuffer(),
      let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
    else {
      throw reader.error ?? FixtureError.missingDecodedPixelBuffer
    }
    return Double(try pixelBuffer.centerLuma())
  }
}

private enum FixtureError: Error {
  case cannotAddWriterInput
  case cannotStartWriting
  case cannotAppendFrame
  case cannotFinishWriting
  case cannotCreatePixelBuffer(CVReturn)
  case missingPixelBufferStorage
  case missingVideoTrack
  case cannotAddReaderOutput
  case cannotStartReading
  case missingDecodedPixelBuffer
  case unexpectedPixelFormat(OSType)
}

extension CVPixelBuffer {

  fileprivate func centerLuma() throws -> UInt8 {
    guard
      CVPixelBufferGetPixelFormatType(self)
        == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
    else {
      throw FixtureError.unexpectedPixelFormat(
        CVPixelBufferGetPixelFormatType(self)
      )
    }
    let width = CVPixelBufferGetWidth(self)
    let height = CVPixelBufferGetHeight(self)
    CVPixelBufferLockBaseAddress(self, .readOnly)
    defer {
      CVPixelBufferUnlockBaseAddress(self, .readOnly)
    }
    guard let baseAddress = CVPixelBufferGetBaseAddressOfPlane(self, 0) else {
      throw FixtureError.missingPixelBufferStorage
    }
    let bytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(self, 0)
    let row =
      baseAddress
      .advanced(by: height / 2 * bytesPerRow)
      .assumingMemoryBound(to: UInt8.self)
    return row[width / 2]
  }
}
