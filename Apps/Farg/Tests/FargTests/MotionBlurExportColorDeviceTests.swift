import AVFoundation
import BrightroomParametric
import CoreGraphics
import CoreMedia
import CoreVideo
import FargMotionBlur
import Foundation
import Testing

@testable import Farg

#if !targetEnvironment(simulator)

  /// Physical-device coverage for color parity between Färg's export paths.
  ///
  /// Every fixture frame is identical, so Optical Flow has no authored motion
  /// to blur. Any visible difference therefore belongs to the rendering or
  /// encoding path rather than to the intended Motion Blur effect.
  @Suite(.serialized)
  struct MotionBlurExportColorDeviceTests {

    private static let maximumChannelDelta = 3.0 / 255.0
    private static let comparisonEpsilon = 1e-12

    /// Verifies LUT output color and static-frame parity before and after encode.
    @Test
    func lutRec709OutputMatchesAcrossMotionBlurModes() async throws {
      guard MotionBlurAvailability.isSupported else {
        return
      }

      let fixtureURL = try await WideGamutStaticColorPatchFixture.make()
      let disabledOutputURL = Self.temporaryMovieURL()
      let enabledOutputURL = Self.temporaryMovieURL()
      defer {
        try? FileManager.default.removeItem(at: fixtureURL)
        try? FileManager.default.removeItem(at: disabledOutputURL)
        try? FileManager.default.removeItem(at: enabledOutputURL)
      }

      let asset = AVURLAsset(url: fixtureURL)
      let colorInfo = await VideoColorInfo.resolve(from: asset)
      #expect(colorInfo.colorPrimaries == AVVideoColorPrimaries_ITU_R_2020)
      #expect(colorInfo.transferFunction == AVVideoTransferFunction_ITU_R_709_2)
      #expect(colorInfo.yCbCrMatrix == AVVideoYCbCrMatrix_ITU_R_2020)
      #expect(colorInfo.isHDR == false)

      let document = NonlinearColorCubeFixture.makeDocument()
      let disabledRecipe = FargVideoRenderRecipe(
        document: document,
        motionBlur: .disabled,
        lutOutputColorSpace: .rec709
      )
      let enabledRecipe = FargVideoRenderRecipe(
        document: document,
        motionBlur: MotionBlurSettings(
          isEnabled: true,
          strength: 80
        ),
        lutOutputColorSpace: .rec709
      )
      let pipeline = FargVideoRenderPipeline()
      let disabledPreparation = try await pipeline.prepare(
        asset: asset,
        recipe: disabledRecipe,
        colorInfo: colorInfo,
        purpose: .export
      )
      let enabledPreparation = try await pipeline.prepare(
        asset: asset,
        recipe: enabledRecipe,
        colorInfo: colorInfo,
        purpose: .export
      )
      #expect(
        disabledPreparation.videoComposition.customVideoCompositorClass
          == MotionBlurVideoCompositor.self
      )
      #expect(
        enabledPreparation.videoComposition.customVideoCompositorClass
          == MotionBlurVideoCompositor.self
      )
      #expect(disabledPreparation.videoComposition.instructions.count == 1)
      #expect(
        disabledPreparation.videoComposition.instructions.first?
          .requiredSourceTrackIDs?.count == 1
      )
      #expect(
        disabledPreparation.videoComposition.sourceTrackIDForFrameTiming
          != kCMPersistentTrackID_Invalid
      )
      #expect(disabledPreparation.outputColorInfo == .sdrRec709)
      #expect(enabledPreparation.outputColorInfo == .sdrRec709)

      let disabledReaderSignature = try await CompositionColorSignature.read(
        from: disabledPreparation,
        frameIndex: WideGamutStaticColorPatchFixture.middleFrameIndex
      )
      let enabledReaderSignature = try await CompositionColorSignature.read(
        from: enabledPreparation,
        frameIndex: WideGamutStaticColorPatchFixture.middleFrameIndex
      )

      #expect(disabledReaderSignature.colorTags == .rec709)
      #expect(enabledReaderSignature.colorTags == .rec709)
      #expect(
        disabledReaderSignature.patchColors.count
          == enabledReaderSignature.patchColors.count
      )
      for patchIndex in disabledReaderSignature.patchColors.indices {
        let disabledColor = disabledReaderSignature.patchColors[patchIndex]
        let enabledColor = enabledReaderSignature.patchColors[patchIndex]
        let delta = disabledColor.maximumChannelDelta(from: enabledColor)
        #expect(
          delta <= Self.maximumChannelDelta + Self.comparisonEpsilon,
          """
          Composition reader color changed in Optical Flow mode.
          patch: \(patchIndex)
          current frame: \(disabledColor)
          optical flow: \(enabledColor)
          maximum channel delta: \(delta)
          """
        )
      }

      let exporter = ParametricVideoExporter()
      try await exporter.export(
        asset: asset,
        recipe: disabledRecipe,
        colorInfo: colorInfo,
        to: disabledOutputURL,
        onProgress: { _ in }
      )
      try await exporter.export(
        asset: asset,
        recipe: enabledRecipe,
        colorInfo: colorInfo,
        to: enabledOutputURL,
        onProgress: { _ in }
      )

      let disabledSignature = try await ExportedColorSignature.read(
        from: disabledOutputURL,
        frameIndex: WideGamutStaticColorPatchFixture.middleFrameIndex
      )
      let enabledSignature = try await ExportedColorSignature.read(
        from: enabledOutputURL,
        frameIndex: WideGamutStaticColorPatchFixture.middleFrameIndex
      )

      #expect(disabledSignature.colorTags == .rec709)
      #expect(enabledSignature.colorTags == .rec709)
      #expect(disabledSignature.colorTags == enabledSignature.colorTags)
      #expect(
        disabledSignature.patchColors.count
          == enabledSignature.patchColors.count
      )

      for patchIndex in disabledSignature.patchColors.indices {
        let disabledColor = disabledSignature.patchColors[patchIndex]
        let enabledColor = enabledSignature.patchColors[patchIndex]
        let delta = disabledColor.maximumChannelDelta(from: enabledColor)
        #expect(
          delta <= Self.maximumChannelDelta + Self.comparisonEpsilon,
          """
          Export color changed when Motion Blur was enabled.
          patch: \(patchIndex)
          disabled: \(disabledColor)
          enabled: \(enabledColor)
          maximum channel delta: \(delta)
          """
        )
      }
    }

    private static func temporaryMovieURL() -> URL {
      FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("mov")
    }
  }

  /// A tagged BT.2020 movie containing four static vertical color patches.
  ///
  /// Repeating the exact pixels across the full sequence gives the middle
  /// sample both temporal neighbors without introducing expected Motion Blur.
  /// Its non-Rec.709 tags ensure output assertions cannot pass by inheriting
  /// the source metadata unchanged.
  private enum WideGamutStaticColorPatchFixture {

    static let encodedSize = CGSize(width: 192, height: 128)
    static let frameDuration = CMTime(value: 1, timescale: 30)
    static let frameCount = 12
    static let middleFrameIndex = frameCount / 2

    private static let colors = [
      BGRAColor(red: 48, green: 96, blue: 160),
      BGRAColor(red: 188, green: 64, blue: 36),
      BGRAColor(red: 32, green: 172, blue: 96),
      BGRAColor(red: 192, green: 192, blue: 192),
    ]

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
          AVVideoColorPropertiesKey: [
            AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_2020,
            AVVideoTransferFunctionKey:
              AVVideoTransferFunction_ITU_R_709_2,
            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_2020,
          ],
          AVVideoCompressionPropertiesKey: [
            AVVideoAverageBitRateKey: 1_000_000
          ],
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
        throw ExportColorFixtureError.cannotAddWriterInput
      }
      writer.add(input)
      guard writer.startWriting() else {
        throw writer.error ?? ExportColorFixtureError.cannotStartWriting
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
          throw writer.error ?? ExportColorFixtureError.cannotAppendFrame
        }
      }

      input.markAsFinished()
      await writer.finishWriting()
      guard writer.status == .completed else {
        throw writer.error ?? ExportColorFixtureError.cannotFinishWriting
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
        throw ExportColorFixtureError.cannotCreatePixelBuffer(status)
      }

      applyWideGamutAttachments(to: pixelBuffer)
      try writeColorPatches(to: pixelBuffer)
      return pixelBuffer
    }

    private static func applyWideGamutAttachments(
      to pixelBuffer: CVPixelBuffer
    ) {
      CVBufferSetAttachment(
        pixelBuffer,
        kCVImageBufferColorPrimariesKey,
        kCVImageBufferColorPrimaries_ITU_R_2020,
        .shouldPropagate
      )
      CVBufferSetAttachment(
        pixelBuffer,
        kCVImageBufferTransferFunctionKey,
        kCVImageBufferTransferFunction_ITU_R_709_2,
        .shouldPropagate
      )
      CVBufferSetAttachment(
        pixelBuffer,
        kCVImageBufferYCbCrMatrixKey,
        kCVImageBufferYCbCrMatrix_ITU_R_2020,
        .shouldPropagate
      )
      if let colorSpace = CGColorSpace(name: CGColorSpace.itur_2020) {
        CVBufferSetAttachment(
          pixelBuffer,
          kCVImageBufferCGColorSpaceKey,
          colorSpace,
          .shouldPropagate
        )
      }
    }

    private static func writeColorPatches(
      to pixelBuffer: CVPixelBuffer
    ) throws {
      CVPixelBufferLockBaseAddress(pixelBuffer, [])
      defer {
        CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
      }
      guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
        throw ExportColorFixtureError.missingPixelBufferStorage
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
          let patchIndex = min(x * colors.count / width, colors.count - 1)
          let color = colors[patchIndex]
          let offset = x * 4
          row[offset] = color.blue
          row[offset + 1] = color.green
          row[offset + 2] = color.red
          row[offset + 3] = 255
        }
      }
    }
  }

  /// A deterministic nonlinear LUT that amplifies input-space differences.
  private enum NonlinearColorCubeFixture {

    static let dimension = 8

    static func makeDocument() -> EditingDocument {
      EditingDocument(
        mainTree: MainTree(
          features: [
            .effect(
              ColorCubeFeature(
                id: FeatureID(rawValue: "export-color-parity"),
                name: "Export Color Parity",
                identifier: "export-color-parity-8",
                dimension: dimension,
                cubeData: makeCubeData()
              )
            )
          ]
        )
      )
    }

    private static func makeCubeData() -> Data {
      var values: [Float] = []
      values.reserveCapacity(
        dimension * dimension * dimension * 4
      )

      for blueIndex in 0..<dimension {
        let blue = normalized(blueIndex)
        for greenIndex in 0..<dimension {
          let green = normalized(greenIndex)
          for redIndex in 0..<dimension {
            let red = normalized(redIndex)
            values.append(power(red, 0.80))
            values.append(
              min(
                power(green, 1.10) * 0.95 + blue * 0.05,
                1
              )
            )
            values.append(power(blue, 1.25))
            values.append(1)
          }
        }
      }

      return values.withUnsafeBufferPointer { buffer in
        Data(buffer: buffer)
      }
    }

    private static func normalized(_ index: Int) -> Float {
      Float(index) / Float(dimension - 1)
    }

    private static func power(
      _ value: Float,
      _ exponent: Double
    ) -> Float {
      Float(pow(Double(value), exponent))
    }
  }

  /// Y'CbCr patch averages and attachments at the export reader boundary.
  ///
  /// This is the last production composition stage before the sample is handed
  /// to `AVAssetWriter`. Reading the same `420v` format as the exporter keeps
  /// both its color attachments and its encoder-facing plane values observable.
  private struct CompositionColorSignature {
    let patchColors: [NormalizedYCbCr]
    let colorTags: VideoColorTags

    static func read(
      from prepared: PreparedFargVideoRender,
      frameIndex: Int
    ) async throws -> Self {
      let videoTracks = try await prepared.asset.loadTracks(
        withMediaType: .video
      )
      guard videoTracks.isEmpty == false else {
        throw ExportColorFixtureError.missingVideoTrack
      }

      let reader = try AVAssetReader(asset: prepared.asset)
      let output = AVAssetReaderVideoCompositionOutput(
        videoTracks: videoTracks,
        videoSettings: [
          kCVPixelBufferPixelFormatTypeKey as String:
            Int(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
          AVVideoColorPropertiesKey:
            prepared.outputColorInfo.avVideoColorProperties,
        ]
      )
      output.alwaysCopiesSampleData = false
      output.videoComposition = prepared.videoComposition
      guard reader.canAdd(output) else {
        throw ExportColorFixtureError.cannotAddReaderOutput
      }
      reader.add(output)
      guard reader.startReading() else {
        throw reader.error ?? ExportColorFixtureError.cannotStartReading
      }
      defer {
        if reader.status == .reading {
          reader.cancelReading()
        }
      }

      var currentFrameIndex = 0
      while let sampleBuffer = output.copyNextSampleBuffer() {
        if currentFrameIndex == frameIndex {
          guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            throw ExportColorFixtureError.missingDecodedPixelBuffer
          }
          return Self(
            patchColors: try pixelBuffer.averageVerticalYCbCrPatchColors(
              patchCount: 4,
              sampleSize: 12
            ),
            colorTags: VideoColorTags(pixelBuffer: pixelBuffer)
          )
        }
        currentFrameIndex += 1
      }

      throw reader.error
        ?? ExportColorFixtureError.missingDecodedFrame(frameIndex)
    }
  }

  /// RGB averages and encoded color metadata for one exported frame.
  private struct ExportedColorSignature {
    let patchColors: [NormalizedRGB]
    let colorTags: VideoColorTags

    static func read(
      from url: URL,
      frameIndex: Int
    ) async throws -> Self {
      let asset = AVURLAsset(url: url)
      let videoTracks = try await asset.loadTracks(withMediaType: .video)
      guard let videoTrack = videoTracks.first else {
        throw ExportColorFixtureError.missingVideoTrack
      }
      let formatDescriptions = try await videoTrack.load(.formatDescriptions)
      guard let formatDescription = formatDescriptions.first else {
        throw ExportColorFixtureError.missingVideoFormatDescription
      }

      let reader = try AVAssetReader(asset: asset)
      let output = AVAssetReaderTrackOutput(
        track: videoTrack,
        outputSettings: [
          kCVPixelBufferPixelFormatTypeKey as String:
            Int(kCVPixelFormatType_32BGRA)
        ]
      )
      output.alwaysCopiesSampleData = false
      guard reader.canAdd(output) else {
        throw ExportColorFixtureError.cannotAddReaderOutput
      }
      reader.add(output)
      guard reader.startReading() else {
        throw reader.error ?? ExportColorFixtureError.cannotStartReading
      }
      defer {
        if reader.status == .reading {
          reader.cancelReading()
        }
      }

      var currentFrameIndex = 0
      while let sampleBuffer = output.copyNextSampleBuffer() {
        if currentFrameIndex == frameIndex {
          guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else {
            throw ExportColorFixtureError.missingDecodedPixelBuffer
          }
          return Self(
            patchColors: try pixelBuffer.averageVerticalPatchColors(
              patchCount: 4,
              sampleSize: 12
            ),
            colorTags: VideoColorTags(
              formatDescription: formatDescription
            )
          )
        }
        currentFrameIndex += 1
      }

      throw reader.error
        ?? ExportColorFixtureError.missingDecodedFrame(frameIndex)
    }
  }

  /// Primaries, transfer function, and matrix at a video pipeline boundary.
  private struct VideoColorTags: Equatable {
    let colorPrimaries: String?
    let transferFunction: String?
    let yCbCrMatrix: String?

    static let rec709 = Self(
      colorPrimaries: AVVideoColorPrimaries_ITU_R_709_2,
      transferFunction: AVVideoTransferFunction_ITU_R_709_2,
      yCbCrMatrix: AVVideoYCbCrMatrix_ITU_R_709_2
    )

    init(
      colorPrimaries: String?,
      transferFunction: String?,
      yCbCrMatrix: String?
    ) {
      self.colorPrimaries = colorPrimaries
      self.transferFunction = transferFunction
      self.yCbCrMatrix = yCbCrMatrix
    }

    init(formatDescription: CMFormatDescription) {
      self.init(
        colorPrimaries: Self.stringExtension(
          kCMFormatDescriptionExtension_ColorPrimaries,
          from: formatDescription
        ),
        transferFunction: Self.stringExtension(
          kCMFormatDescriptionExtension_TransferFunction,
          from: formatDescription
        ),
        yCbCrMatrix: Self.stringExtension(
          kCMFormatDescriptionExtension_YCbCrMatrix,
          from: formatDescription
        )
      )
    }

    init(pixelBuffer: CVPixelBuffer) {
      self.init(
        colorPrimaries: Self.stringAttachment(
          kCVImageBufferColorPrimariesKey,
          from: pixelBuffer
        ),
        transferFunction: Self.stringAttachment(
          kCVImageBufferTransferFunctionKey,
          from: pixelBuffer
        ),
        yCbCrMatrix: Self.stringAttachment(
          kCVImageBufferYCbCrMatrixKey,
          from: pixelBuffer
        )
      )
    }

    private static func stringExtension(
      _ key: CFString,
      from formatDescription: CMFormatDescription
    ) -> String? {
      CMFormatDescriptionGetExtension(
        formatDescription,
        extensionKey: key
      ) as? String
    }

    private static func stringAttachment(
      _ key: CFString,
      from pixelBuffer: CVPixelBuffer
    ) -> String? {
      var mode = CVAttachmentMode.shouldPropagate
      return CVBufferCopyAttachment(
        pixelBuffer,
        key,
        &mode
      ) as? String
    }
  }

  /// One patch's channel averages normalized to the closed range zero...one.
  private struct NormalizedRGB: CustomStringConvertible {
    let red: Double
    let green: Double
    let blue: Double

    var description: String {
      "(r: \(red), g: \(green), b: \(blue))"
    }

    func maximumChannelDelta(from other: Self) -> Double {
      max(
        abs(red - other.red),
        max(
          abs(green - other.green),
          abs(blue - other.blue)
        )
      )
    }
  }

  /// One patch's encoder-facing video-range channels normalized to zero...one.
  private struct NormalizedYCbCr: CustomStringConvertible {
    let luma: Double
    let blueDifference: Double
    let redDifference: Double

    var description: String {
      "(y: \(luma), cb: \(blueDifference), cr: \(redDifference))"
    }

    func maximumChannelDelta(from other: Self) -> Double {
      max(
        abs(luma - other.luma),
        max(
          abs(blueDifference - other.blueDifference),
          abs(redDifference - other.redDifference)
        )
      )
    }
  }

  /// Four-channel byte color in Core Video's 32BGRA memory order.
  private struct BGRAColor {
    let red: UInt8
    let green: UInt8
    let blue: UInt8
  }

  /// Errors produced while creating, exporting, or sampling the color fixture.
  private enum ExportColorFixtureError: Error {
    case cannotAddWriterInput
    case cannotStartWriting
    case cannotAppendFrame
    case cannotFinishWriting
    case cannotCreatePixelBuffer(CVReturn)
    case missingPixelBufferStorage
    case missingVideoTrack
    case missingVideoFormatDescription
    case cannotAddReaderOutput
    case cannotStartReading
    case missingDecodedPixelBuffer
    case missingDecodedFrame(Int)
    case unexpectedDecodedPixelFormat(OSType)
    case invalidPatchSampleGeometry
  }

  extension CVPixelBuffer {

    /// Returns average Y'CbCr values from centered samples inside vertical bands.
    fileprivate func averageVerticalYCbCrPatchColors(
      patchCount: Int,
      sampleSize: Int
    ) throws -> [NormalizedYCbCr] {
      guard
        CVPixelBufferGetPixelFormatType(self)
          == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange
      else {
        throw ExportColorFixtureError.unexpectedDecodedPixelFormat(
          CVPixelBufferGetPixelFormatType(self)
        )
      }

      let width = CVPixelBufferGetWidth(self)
      let height = CVPixelBufferGetHeight(self)
      guard patchCount > 0 else {
        throw ExportColorFixtureError.invalidPatchSampleGeometry
      }
      let patchWidth = width / patchCount
      guard
        sampleSize > 0,
        sampleSize.isMultiple(of: 2),
        patchWidth >= sampleSize,
        height >= sampleSize
      else {
        throw ExportColorFixtureError.invalidPatchSampleGeometry
      }

      CVPixelBufferLockBaseAddress(self, .readOnly)
      defer {
        CVPixelBufferUnlockBaseAddress(self, .readOnly)
      }
      guard
        let lumaBaseAddress = CVPixelBufferGetBaseAddressOfPlane(self, 0),
        let chromaBaseAddress = CVPixelBufferGetBaseAddressOfPlane(self, 1)
      else {
        throw ExportColorFixtureError.missingPixelBufferStorage
      }

      let lumaBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(self, 0)
      let chromaBytesPerRow = CVPixelBufferGetBytesPerRowOfPlane(self, 1)
      let sampleY = (height - sampleSize) / 2
      let lumaSampleCount = Double(sampleSize * sampleSize)
      let chromaSampleCount = Double(sampleSize * sampleSize / 4)

      return try (0..<patchCount).map { patchIndex in
        let patchOriginX = patchIndex * patchWidth
        let sampleX = patchOriginX + (patchWidth - sampleSize) / 2
        guard sampleX.isMultiple(of: 2), sampleY.isMultiple(of: 2) else {
          throw ExportColorFixtureError.invalidPatchSampleGeometry
        }

        var lumaTotal: UInt64 = 0
        for y in sampleY..<(sampleY + sampleSize) {
          let row =
            lumaBaseAddress
            .advanced(by: y * lumaBytesPerRow)
            .assumingMemoryBound(to: UInt8.self)
          for x in sampleX..<(sampleX + sampleSize) {
            lumaTotal += UInt64(row[x])
          }
        }

        var blueDifferenceTotal: UInt64 = 0
        var redDifferenceTotal: UInt64 = 0
        let chromaSampleX = sampleX / 2
        let chromaSampleY = sampleY / 2
        let chromaSampleSize = sampleSize / 2
        for y in chromaSampleY..<(chromaSampleY + chromaSampleSize) {
          let row =
            chromaBaseAddress
            .advanced(by: y * chromaBytesPerRow)
            .assumingMemoryBound(to: UInt8.self)
          for x in chromaSampleX..<(chromaSampleX + chromaSampleSize) {
            blueDifferenceTotal += UInt64(row[x * 2])
            redDifferenceTotal += UInt64(row[x * 2 + 1])
          }
        }

        return NormalizedYCbCr(
          luma: Double(lumaTotal) / lumaSampleCount / 255,
          blueDifference:
            Double(blueDifferenceTotal) / chromaSampleCount / 255,
          redDifference:
            Double(redDifferenceTotal) / chromaSampleCount / 255
        )
      }
    }

    /// Returns average RGB values from centered samples inside vertical bands.
    fileprivate func averageVerticalPatchColors(
      patchCount: Int,
      sampleSize: Int
    ) throws -> [NormalizedRGB] {
      guard CVPixelBufferGetPixelFormatType(self) == kCVPixelFormatType_32BGRA else {
        throw ExportColorFixtureError.unexpectedDecodedPixelFormat(
          CVPixelBufferGetPixelFormatType(self)
        )
      }

      let width = CVPixelBufferGetWidth(self)
      let height = CVPixelBufferGetHeight(self)
      guard patchCount > 0 else {
        throw ExportColorFixtureError.invalidPatchSampleGeometry
      }
      let patchWidth = width / patchCount
      guard
        sampleSize > 0,
        patchWidth >= sampleSize,
        height >= sampleSize
      else {
        throw ExportColorFixtureError.invalidPatchSampleGeometry
      }

      CVPixelBufferLockBaseAddress(self, .readOnly)
      defer {
        CVPixelBufferUnlockBaseAddress(self, .readOnly)
      }
      guard let baseAddress = CVPixelBufferGetBaseAddress(self) else {
        throw ExportColorFixtureError.missingPixelBufferStorage
      }

      let bytesPerRow = CVPixelBufferGetBytesPerRow(self)
      let sampleY = (height - sampleSize) / 2
      let samplePixelCount = Double(sampleSize * sampleSize)
      return (0..<patchCount).map { patchIndex in
        let patchOriginX = patchIndex * patchWidth
        let sampleX =
          patchOriginX + (patchWidth - sampleSize) / 2
        var redTotal: UInt64 = 0
        var greenTotal: UInt64 = 0
        var blueTotal: UInt64 = 0

        for y in sampleY..<(sampleY + sampleSize) {
          let row =
            baseAddress
            .advanced(by: y * bytesPerRow)
            .assumingMemoryBound(to: UInt8.self)
          for x in sampleX..<(sampleX + sampleSize) {
            let offset = x * 4
            blueTotal += UInt64(row[offset])
            greenTotal += UInt64(row[offset + 1])
            redTotal += UInt64(row[offset + 2])
          }
        }

        return NormalizedRGB(
          red: Double(redTotal) / samplePixelCount / 255,
          green: Double(greenTotal) / samplePixelCount / 255,
          blue: Double(blueTotal) / samplePixelCount / 255
        )
      }
    }
  }

#endif
