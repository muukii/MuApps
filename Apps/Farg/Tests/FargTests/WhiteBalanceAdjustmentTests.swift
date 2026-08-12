import BrightroomParametric
import CoreGraphics
import CoreImage
import Testing

@testable import Farg

@Suite("White Balance adjustment")
struct WhiteBalanceAdjustmentTests {

  @Test
  func initializerAndMutationClampBothAxesToSupportedRanges() {
    var adjustment = WhiteBalanceAdjustment(
      temperature: 10_000,
      tint: -500
    )
    #expect(adjustment.temperature == 3_000)
    #expect(adjustment.tint == -100)

    adjustment.temperature = -10_000
    adjustment.tint = 500
    #expect(adjustment.temperature == -3_000)
    #expect(adjustment.tint == 100)
  }

  @Test
  func neutralStateDisablesItsCoupledParametricFeature() {
    let neutral = WhiteBalanceAdjustment.neutral
    #expect(neutral.isNeutral)
    #expect(neutral.feature.isEnabled == false)

    let adjusted = WhiteBalanceAdjustment(
      temperature: 650,
      tint: -12
    )
    #expect(adjusted.isNeutral == false)
    #expect(adjusted.feature.isEnabled)
    #expect(adjusted.feature.value == 650)
    #expect(adjusted.feature.tint == -12)
  }

  @Test
  func previewRequestIdentityIncludesBothWhiteBalanceAxes() {
    let neutral = LUTPreviewRequestID(
      sourceID: "source",
      itemID: .lut("look"),
      libraryRevision: 1,
      exposureEV: 0,
      whiteBalanceTemperature: 0,
      whiteBalanceTint: 0
    )
    let warmer = LUTPreviewRequestID(
      sourceID: "source",
      itemID: .lut("look"),
      libraryRevision: 1,
      exposureEV: 0,
      whiteBalanceTemperature: 50,
      whiteBalanceTint: 0
    )
    let moreMagenta = LUTPreviewRequestID(
      sourceID: "source",
      itemID: .lut("look"),
      libraryRevision: 1,
      exposureEV: 0,
      whiteBalanceTemperature: 0,
      whiteBalanceTint: 1
    )

    #expect(neutral != warmer)
    #expect(neutral != moreMagenta)
    #expect(warmer != moreMagenta)
  }

  @Test
  func adjustedOriginalPreviewUsesTheParametricRenderer() async throws {
    let image = try #require(Self.makeSourceImage())
    let source = LUTPreviewSourceImage(id: "white-balance-source", image: image)
    let renderer = LUTPreviewRenderer()

    let neutral = try await renderer.render(
      source: source,
      recipe: nil,
      whiteBalance: .neutral,
      libraryRevision: 0
    )
    #expect(neutral === image)

    let adjusted = try await renderer.render(
      source: source,
      recipe: nil,
      whiteBalance: WhiteBalanceAdjustment(temperature: 800, tint: 20),
      libraryRevision: 0
    )
    #expect(adjusted !== image)
  }

  @Test
  func positiveTintMovesTheRenderedImageTowardMagenta() async throws {
    let image = try #require(Self.makeSourceImage())
    let source = LUTPreviewSourceImage(id: "tint-axis-source", image: image)

    let rendered = try await LUTPreviewRenderer().render(
      source: source,
      recipe: nil,
      whiteBalance: WhiteBalanceAdjustment(tint: 100),
      libraryRevision: 0
    )
    let pixel = Self.rgba(in: rendered)

    #expect(pixel.red > pixel.green)
    #expect(pixel.blue > pixel.green)
  }

  @Test
  func brightroomCodecRoundTripPreservesBothAxes() throws {
    let adjustment = WhiteBalanceAdjustment(temperature: 725, tint: -14)
    let document = EditingDocument(
      mainTree: MainTree(features: [.effect(adjustment.feature)])
    )

    let codec = ParametricDocumentCodec()
    let decoded = try codec.decode(codec.encode(document))

    let firstFeature = try #require(decoded.mainTree.features.first)
    guard case .effect(let effect) = firstFeature else {
      Issue.record("Expected a White Balance image effect.")
      return
    }
    let whiteBalance = try #require(effect as? TemperatureFeature)
    #expect(whiteBalance.value == 725)
    #expect(whiteBalance.tint == -14)
  }

  @Test
  func brightroomCodecDecodesLegacyTemperatureWithNeutralTint() throws {
    var legacyCodec = ParametricDocumentCodec()
    legacyCodec.register(LegacyTemperatureFeature.self)
    let legacyDocument = EditingDocument(
      mainTree: MainTree(
        features: [
          .effect(
            LegacyTemperatureFeature(
              id: FeatureID(rawValue: "legacy-white-balance"),
              value: 425
            )
          )
        ]
      )
    )
    let data = try legacyCodec.encode(legacyDocument)

    let decoded = try ParametricDocumentCodec().decode(data)

    let firstFeature = try #require(decoded.mainTree.features.first)
    guard case .effect(let effect) = firstFeature else {
      Issue.record("Expected a migrated Temperature image effect.")
      return
    }
    let whiteBalance = try #require(effect as? TemperatureFeature)
    #expect(whiteBalance.id == FeatureID(rawValue: "legacy-white-balance"))
    #expect(whiteBalance.value == 425)
    #expect(whiteBalance.tint == 0)
  }

  private static func makeSourceImage() -> CGImage? {
    let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    guard
      let context = CGContext(
        data: nil,
        width: 8,
        height: 8,
        bitsPerComponent: 8,
        bytesPerRow: 8 * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      )
    else {
      return nil
    }
    context.setFillColor(
      CGColor(
        colorSpace: colorSpace,
        components: [0.25, 0.35, 0.45, 1]
      )!
    )
    context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
    return context.makeImage()
  }

  /// Renders the uniform fixture into a deterministic sRGB RGBA sample.
  private static func rgba(
    in image: CGImage
  ) -> (red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8) {
    var bytes = [UInt8](repeating: 0, count: 4)
    bytes.withUnsafeMutableBytes { buffer in
      CIContext().render(
        CIImage(cgImage: image),
        toBitmap: buffer.baseAddress!,
        rowBytes: 4,
        bounds: CGRect(x: 4, y: 4, width: 1, height: 1),
        format: .RGBA8,
        colorSpace: CGColorSpace(name: CGColorSpace.sRGB)
      )
    }
    return (bytes[0], bytes[1], bytes[2], bytes[3])
  }

  /// The schema-v1 Temperature payload written before Brightroom added Tint.
  private struct LegacyTemperatureFeature: ImageEffectFeatureType, PersistableFeature {

    static let featureTypeKey = TemperatureFeature.featureTypeKey

    var id: FeatureID = .init()
    var isEnabled = true
    var value: Double

    func apply(
      to image: CIImage,
      context: FeatureEvaluationContext
    ) throws -> CIImage {
      image
    }
  }
}
