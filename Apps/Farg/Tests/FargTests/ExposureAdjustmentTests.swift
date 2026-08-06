import BrightroomParametric
import CoreGraphics
import Testing

@testable import Farg

@Suite("Exposure adjustment")
struct ExposureAdjustmentTests {

  @Test
  func initializerAndMutationClampToSupportedRange() {
    var adjustment = ExposureAdjustment(ev: 10)
    #expect(adjustment.ev == 2)

    adjustment.ev = -10
    #expect(adjustment.ev == -2)
  }

  @Test
  func neutralStateDisablesItsParametricFeature() {
    let neutral = ExposureAdjustment.neutral
    #expect(neutral.isNeutral)
    #expect(neutral.feature.isEnabled == false)

    let adjusted = ExposureAdjustment(ev: 0.5)
    #expect(adjusted.isNeutral == false)
    #expect(adjusted.feature.isEnabled)
    #expect(adjusted.feature.value == 0.5)
  }

  @Test
  func previewRequestIdentityIncludesExposure() {
    let neutral = LUTPreviewRequestID(
      sourceID: "source",
      itemID: .lut("look"),
      libraryRevision: 1,
      exposureEV: 0
    )
    let adjusted = LUTPreviewRequestID(
      sourceID: "source",
      itemID: .lut("look"),
      libraryRevision: 1,
      exposureEV: 0.1
    )

    #expect(neutral != adjusted)
  }

  @Test
  func adjustedOriginalPreviewUsesTheParametricRenderer() async throws {
    let image = try #require(Self.makeSourceImage())
    let source = LUTPreviewSourceImage(id: "exposure-source", image: image)
    let renderer = LUTPreviewRenderer()

    let neutral = try await renderer.render(
      source: source,
      recipe: nil,
      exposure: .neutral,
      libraryRevision: 0
    )
    #expect(neutral === image)

    let adjusted = try await renderer.render(
      source: source,
      recipe: nil,
      exposure: ExposureAdjustment(ev: 1),
      libraryRevision: 0
    )
    #expect(adjusted !== image)
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
}

@Suite("Exposure document order", .serialized)
@MainActor
struct ExposureDocumentOrderTests {

  @Test
  func editStatePlacesExposureBeforeLUTAndGrain() throws {
    let library = LUTLibrary()
    let lut = try #require(library.luts.first)
    let state = EditState()
    state.exposure = ExposureAdjustment(ev: 0.7)
    state.grain.isEnabled = true

    let features = try state.makeDocument(
      using: library,
      selectedLUTID: lut.id
    ).mainTree.features
    #expect(features.count == 3)

    guard case .effect(let firstEffect) = features[0] else {
      Issue.record("Expected Exposure as the first image effect.")
      return
    }
    let exposure = try #require(firstEffect as? ExposureFeature)
    #expect(exposure.value == 0.7)

    guard case .effect(let secondEffect) = features[1] else {
      Issue.record("Expected LUT as the second image effect.")
      return
    }
    #expect(secondEffect is ColorCubeFeature)

    guard case .effect(let thirdEffect) = features[2] else {
      Issue.record("Expected Grain as the third image effect.")
      return
    }
    #expect(thirdEffect is FilmGrainFeature)
  }
}
