import CoreGraphics
import Foundation
import SwiftUI
import Testing

@testable import Tinycurve

@Suite("Journal scene appearance host")
@MainActor
struct JournalSceneAppearanceHostTests {

  @Test(
    "Resolves the hosted color scheme",
    arguments: [
      TestCase(
        preference: .system,
        inheritedColorScheme: .light,
        expectedColorScheme: .light
      ),
      TestCase(
        preference: .system,
        inheritedColorScheme: .dark,
        expectedColorScheme: .dark
      ),
      TestCase(
        preference: .light,
        inheritedColorScheme: .dark,
        expectedColorScheme: .light
      ),
      TestCase(
        preference: .dark,
        inheritedColorScheme: .light,
        expectedColorScheme: .dark
      ),
    ]
  )
  func resolvesAppearance(testCase: TestCase) throws {
    let suiteName = "JournalSceneAppearanceHostTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }

    defaults.set(
      testCase.preference.rawValue,
      forKey: JournalDefaults.appearancePreferenceID
    )

    let renderer = ImageRenderer(
      content: JournalSceneAppearanceHost(defaults: defaults) {
        AppearanceProbe()
      }
      .environment(\.colorScheme, testCase.inheritedColorScheme)
    )
    renderer.scale = 1
    renderer.isOpaque = true

    let image = try #require(renderer.cgImage)
    let luminance = try ProbeLuminance(image: image).value

    switch testCase.expectedColorScheme {
    case .light:
      #expect(luminance < 16)
    case .dark:
      #expect(luminance > 239)
    @unknown default:
      Issue.record("Unexpected color scheme")
    }
  }

  struct TestCase: Sendable, CustomTestStringConvertible {
    let preference: JournalAppearancePreference
    let inheritedColorScheme: ColorScheme
    let expectedColorScheme: ColorScheme

    var testDescription: String {
      "\(preference.rawValue), inherited: \(inheritedColorScheme)"
    }
  }
}

// MARK: - Probe

/// Renders the effective SwiftUI color scheme as an observable black/white value.
private struct AppearanceProbe: View {

  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    Rectangle()
      .fill(environmentMarker)
      .frame(width: 8, height: 8)
  }

  private var environmentMarker: Color {
    switch colorScheme {
    case .light: .black
    case .dark: .white
    @unknown default: .red
    }
  }
}

/// Luminance sampled from the center of a rendered appearance probe.
private struct ProbeLuminance {
  let value: UInt8

  init(image: CGImage) throws {
    let width = image.width
    let height = image.height
    let bytesPerPixel = 4
    let bytesPerRow = width * bytesPerPixel
    var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)

    let context = try #require(
      CGContext(
        data: &pixels,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: bytesPerRow,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      )
    )
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

    let pixelOffset = ((height / 2) * width + width / 2) * bytesPerPixel
    let red = UInt16(pixels[pixelOffset])
    let green = UInt16(pixels[pixelOffset + 1])
    let blue = UInt16(pixels[pixelOffset + 2])
    value = UInt8((red + green + blue) / 3)
  }
}
