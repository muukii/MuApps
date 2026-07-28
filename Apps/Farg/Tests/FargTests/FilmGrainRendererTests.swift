import CoreImage
import CoreMedia
import Foundation
import Testing

@testable import Farg

@Suite("Grain settings")
struct GrainSettingsTests {

  @Test
  func initializerClampsValuesToSupportedRange() {
    let settings = GrainSettings(isEnabled: true, intensity: 500, size: -3)
    #expect(settings.intensity == 100)
    #expect(settings.size == 1)
  }

  @Test
  func mutationClampsValuesToSupportedRange() {
    var settings = GrainSettings(isEnabled: true)
    settings.intensity = 0
    settings.size = 101
    #expect(settings.intensity == 1)
    #expect(settings.size == 100)
  }

  @Test
  func disabledKeepsDefaultParameters() {
    #expect(GrainSettings.disabled.isEnabled == false)
    #expect(GrainSettings.disabled.intensity == 50)
    #expect(GrainSettings.disabled.size == 50)
  }

  @Test
  func parameterSourceDeliversUpdatedValues() {
    let source = GrainParameterSource(
      settings: GrainSettings(isEnabled: true, intensity: 10, size: 20)
    )
    #expect(source.snapshot() == .init(intensity: 10, size: 20))

    source.update(settings: GrainSettings(isEnabled: true, intensity: 70, size: 90))
    #expect(source.snapshot() == .init(intensity: 70, size: 90))
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
      compositionTime: CMTime(value: 1, timescale: 30),
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
      compositionTime: CMTime(value: 1, timescale: 30),
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
      compositionTime: time,
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
