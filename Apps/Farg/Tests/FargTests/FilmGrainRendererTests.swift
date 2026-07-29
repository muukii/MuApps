import BrightroomParametric
import CoreImage
import CoreMedia
import Foundation
import Testing

@testable import Farg

@Suite("Film grain feature")
struct FilmGrainFeatureTests {

  @Test
  func initializerClampsValuesToSupportedRange() {
    let feature = FilmGrainFeature(isEnabled: true, intensity: 500, size: -3)
    #expect(feature.intensity == 100)
    #expect(feature.size == 1)
  }

  @Test
  func mutationClampsValuesToSupportedRange() {
    var feature = FilmGrainFeature(isEnabled: true)
    feature.intensity = 0
    feature.size = 101
    #expect(feature.intensity == 1)
    #expect(feature.size == 100)
  }

  @Test
  func disabledFeatureKeepsDefaultParameters() {
    let feature = FilmGrainFeature(isEnabled: false)
    #expect(feature.isEnabled == false)
    #expect(feature.intensity == 50)
    #expect(feature.size == 50)
  }

  @Test
  func documentSourceDeliversUpdatedDocuments() {
    let first = EditingDocument(
      mainTree: MainTree(
        features: [
          .effect(
            FilmGrainFeature(
              id: FeatureID(rawValue: "first-grain"),
              isEnabled: true,
              intensity: 10,
              size: 20
            )
          )
        ]
      )
    )
    let second = EditingDocument(
      mainTree: MainTree(
        features: [
          .effect(
            FilmGrainFeature(
              id: FeatureID(rawValue: "second-grain"),
              isEnabled: true,
              intensity: 70,
              size: 90
            )
          )
        ]
      )
    )
    let source = ParametricDocumentSource(document: first)
    #expect(source.snapshot() == first)

    source.update(document: second)

    #expect(source.snapshot() == second)
  }
}

@Suite("Film grain renderer")
struct FilmGrainRendererTests {

  private static let extent = CGRect(x: 0, y: 0, width: 64, height: 64)

  @Test
  func grainPitchScalesWithRenderHeight() {
    let previewPitch = FilmGrainRenderer.grainPitch(renderHeight: 1080, size: 50)
    let exportPitch = FilmGrainRenderer.grainPitch(renderHeight: 2160, size: 50)
    #expect(abs(exportPitch - previewPitch * 2) < 0.0001)
  }

  @Test
  func grainPitchNeverDropsBelowOnePixel() {
    #expect(FilmGrainRenderer.grainPitch(renderHeight: 100, size: 1) == 1)
  }

  @Test
  func amplitudeScalesLinearly() {
    #expect(FilmGrainRenderer.amplitude(intensity: 100) == 0.25)
    #expect(FilmGrainRenderer.amplitude(intensity: 50) == 0.125)
  }

  @Test
  func noiseFieldOffsetIsDeterministicPerFrameTime() {
    let time = CMTime(value: 1, timescale: 30)
    #expect(
      FilmGrainRenderer.noiseFieldOffset(for: time)
        == FilmGrainRenderer.noiseFieldOffset(for: time)
    )
  }

  @Test
  func noiseFieldOffsetChangesBetweenFrames() {
    let first = FilmGrainRenderer.noiseFieldOffset(
      for: CMTime(value: 0, timescale: 30)
    )
    let second = FilmGrainRenderer.noiseFieldOffset(
      for: CMTime(value: 1, timescale: 30)
    )
    #expect(first != second)
  }

  @Test
  func invalidTimeFallsBackToStableOffset() {
    #expect(FilmGrainRenderer.noiseFieldOffset(for: .invalid) == .zero)
  }

  @Test
  func sameFrameTimeRendersIdenticalGrain() throws {
    let first = try renderBytes(
      grainImage(time: CMTime(value: 1, timescale: 30))
    )
    let second = try renderBytes(
      grainImage(time: CMTime(value: 1, timescale: 30))
    )
    #expect(first == second)
  }

  @Test
  func differentFrameTimesRenderDifferentGrain() throws {
    let first = try renderBytes(
      grainImage(time: CMTime(value: 1, timescale: 30))
    )
    let second = try renderBytes(
      grainImage(time: CMTime(value: 2, timescale: 30))
    )
    #expect(first != second)
  }

  @Test
  func parametricFeatureUsesTheEvaluationPresentationTime() throws {
    let document = EditingDocument(
      mainTree: MainTree(
        features: [
          .effect(
            FilmGrainFeature(
              id: FeatureID(rawValue: "time-driven-grain"),
              isEnabled: true,
              intensity: 100,
              size: 50
            )
          )
        ]
      )
    )
    let renderer = ParametricVideoRenderer()
    let first = try renderBytes(
      renderer.makeFrameImage(
        from: baseImage(),
        document: document,
        presentationTime: CMTime(value: 1, timescale: 30)
      )
    )
    let second = try renderBytes(
      renderer.makeFrameImage(
        from: baseImage(),
        document: document,
        presentationTime: CMTime(value: 2, timescale: 30)
      )
    )

    #expect(first != second)
  }

  @Test
  func grainVisiblyChangesTheBaseImage() throws {
    let base = try renderBytes(baseImage())
    let grained = try renderBytes(
      grainImage(time: CMTime(value: 1, timescale: 30))
    )
    #expect(base != grained)
  }

  @Test
  func grainCarriesSubtleChannelDecorrelation() throws {
    let bytes = try renderBytes(
      grainImage(time: CMTime(value: 1, timescale: 30))
    )
    // Pure luma grain would offset R, G, and B identically at every pixel.
    var hasChannelDivergence = false
    var pixel = 0
    while pixel < bytes.count {
      let red = bytes[pixel]
      let green = bytes[pixel + 1]
      let blue = bytes[pixel + 2]
      if red != green || green != blue {
        hasChannelDivergence = true
        break
      }
      pixel += 4
    }
    #expect(hasChannelDivergence)
  }

  @Test
  func pureBlackStaysClean() throws {
    let black = CIImage(color: CIColor(red: 0, green: 0, blue: 0, alpha: 1))
      .cropped(to: Self.extent)
    let grained = try FilmGrainRenderer.apply(
      to: black,
      renderExtent: Self.extent,
      presentationTime: CMTime(value: 1, timescale: 30),
      intensity: 100,
      size: 50
    )
    let baseBytes = try renderBytes(black)
    let grainedBytes = try renderBytes(grained)
    #expect(maximumChannelDelta(baseBytes, grainedBytes) <= 1)
  }

  @Test
  func pureWhiteStaysClean() throws {
    let white = CIImage(color: CIColor(red: 1, green: 1, blue: 1, alpha: 1))
      .cropped(to: Self.extent)
    let grained = try FilmGrainRenderer.apply(
      to: white,
      renderExtent: Self.extent,
      presentationTime: CMTime(value: 1, timescale: 30),
      intensity: 100,
      size: 50
    )
    let baseBytes = try renderBytes(white)
    let grainedBytes = try renderBytes(grained)
    #expect(maximumChannelDelta(baseBytes, grainedBytes) <= 1)
  }

  @Test
  func outputCoversTheRequestedExtent() throws {
    let output = try grainImage(time: CMTime(value: 1, timescale: 30))
    #expect(output.extent == Self.extent)
  }

  // MARK: - Rendering Helpers

  private func baseImage() -> CIImage {
    CIImage(color: CIColor(red: 0.18, green: 0.18, blue: 0.18, alpha: 1))
      .cropped(to: Self.extent)
  }

  private func grainImage(time: CMTime) throws -> CIImage {
    try FilmGrainRenderer.apply(
      to: baseImage(),
      renderExtent: Self.extent,
      presentationTime: time,
      intensity: 100,
      size: 50
    )
  }

  private func maximumChannelDelta(_ first: [UInt8], _ second: [UInt8]) -> Int {
    var maximumDelta = 0
    for index in first.indices {
      let delta = abs(Int(first[index]) - Int(second[index]))
      if delta > maximumDelta {
        maximumDelta = delta
      }
    }
    return maximumDelta
  }

  private func renderBytes(_ image: CIImage) throws -> [UInt8] {
    let width = Int(Self.extent.width)
    let height = Int(Self.extent.height)
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    let colorSpace = try #require(CGColorSpace(name: CGColorSpace.sRGB))
    bytes.withUnsafeMutableBytes { buffer in
      FargCIContext.shared.render(
        image,
        toBitmap: buffer.baseAddress!,
        rowBytes: width * 4,
        bounds: Self.extent,
        format: .RGBA8,
        colorSpace: colorSpace
      )
    }
    return bytes
  }
}
