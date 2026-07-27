import BrightroomParametric
import CoreGraphics
import CoreImage
import CryptoKit
import Foundation
import ImageIO
import Testing

@testable import Farg

/// Compares Färg's production LUT renderer with a frame rendered by DaVinci Resolve.
///
/// The committed TIFF pair is an external oracle. The source TIFF is the exact
/// file Resolve consumed, while the expected TIFF is Resolve's output with only
/// the production LUT applied. Keeping the source file in the oracle prevents a
/// programmatically regenerated chart from silently drifting from Resolve's input.
@Suite(.serialized)
struct LUTResolveGoldenReferenceTests {

  private static let maximumSourceChannelDelta = 1.0 / 255.0
  private static let maximumGoldenChannelDelta = 3.0 / 255.0
  private static let maximumGoldenRMSDelta = 1.0 / 255.0

  /// Applies the bundled starter LUT to Resolve's exact source chart.
  @Test
  func bundledAppleLogLUTMatchesResolve21GoldenReference() throws {
    let fixture = try ResolveLUTReferenceFixture.load()
    try fixture.validateProvenance()

    let colorSpace =
      FargLUTOutputColorSpace.rec709.lutResultColorSpace
    let sourceCGImage = try fixture.loadSourceImage()
    let goldenCGImage = try fixture.loadGoldenImage()
    try Self.validateFixtureImage(sourceCGImage, named: fixture.sourceFileName)
    try Self.validateFixtureImage(goldenCGImage, named: fixture.goldenFileName)

    let sourceImage = CIImage(cgImage: sourceCGImage)
    let goldenImage = CIImage(cgImage: goldenCGImage)
    let programmaticChart = Rec709FullRangeGrid.makeImage(
      colorSpace: colorSpace
    )

    // Validate the chart contract independently before using the committed
    // source as the LUT input. This produces useful patch diagnostics if the
    // fixture generator and the XCTest mapping ever diverge.
    let sourcePixels = try RenderedRGBA8.make(
      sourceImage,
      context: FargCIContext.shared,
      colorSpace: colorSpace
    )
    let programmaticPixels = try RenderedRGBA8.make(
      programmaticChart,
      context: FargCIContext.shared,
      colorSpace: colorSpace
    )
    let sourceComparison = Rec709FullRangeGrid.comparePatchInteriors(
      sourcePixels,
      programmaticPixels
    )
    #expect(
      sourceComparison.maximumChannelDelta
        <= Self.maximumSourceChannelDelta,
      """
      Resolve's committed source TIFF no longer matches the programmatic chart.
      \(sourceComparison.diagnostic)
      """
    )

    let feature = try ColorCubeFeature(
      contentsOfCubeFile: fixture.productionLUTURL,
      id: FeatureID(rawValue: "resolve-golden.apple-log1-example"),
      name: "AppleLog1 Example",
      amount: 1
    )
    let document = EditingDocument(
      mainTree: MainTree(features: [.effect(feature)])
    )
    let renderedImage = try ParametricImageRenderer().makeImage(
      from: sourceImage,
      document: document
    )
    let actualPixels = try RenderedRGBA8.make(
      renderedImage,
      context: FargCIContext.shared,
      colorSpace: colorSpace
    )
    let goldenPixels = try RenderedRGBA8.make(
      goldenImage,
      context: FargCIContext.shared,
      colorSpace: colorSpace
    )
    let goldenComparison = Rec709FullRangeGrid.comparePatchInteriors(
      actualPixels,
      goldenPixels
    )

    #expect(
      goldenComparison.maximumChannelDelta
        <= Self.maximumGoldenChannelDelta,
      """
      Färg's LUT result differs from the DaVinci Resolve golden reference.
      \(goldenComparison.diagnostic)
      """
    )
    #expect(
      goldenComparison.rootMeanSquareChannelDelta
        <= Self.maximumGoldenRMSDelta,
      """
      Färg's LUT result has a systematic difference from DaVinci Resolve.
      \(goldenComparison.diagnostic)
      """
    )
  }

  private static func validateFixtureImage(
    _ image: CGImage,
    named fileName: String
  ) throws {
    guard
      image.width == Rec709FullRangeGrid.width,
      image.height == Rec709FullRangeGrid.height
    else {
      throw ResolveLUTReferenceError.invalidImageDimensions(
        fileName: fileName,
        expectedWidth: Rec709FullRangeGrid.width,
        expectedHeight: Rec709FullRangeGrid.height,
        actualWidth: image.width,
        actualHeight: image.height
      )
    }
    guard
      let colorSpace = image.colorSpace,
      colorSpace.model == .rgb
    else {
      throw ResolveLUTReferenceError.missingRGBColorProfile(fileName)
    }
  }
}

/// Files and provenance metadata belonging to one Resolve-rendered oracle.
private struct ResolveLUTReferenceFixture {

  static let sourceFileName = "rec709-full-range-source.tiff"
  static let goldenFileName = "rec709-full-range-resolve-21.tiff"
  static let manifestFileName =
    "rec709-full-range-resolve-21.manifest.json"
  static let productionLUTFileName = "AppleLog1 Example.cube"

  let bundle: Bundle
  let sourceURL: URL
  let goldenURL: URL
  let manifestURL: URL
  let productionLUTURL: URL
  let manifest: ResolveLUTReferenceManifest

  var sourceFileName: String { Self.sourceFileName }
  var goldenFileName: String { Self.goldenFileName }

  static func load() throws -> Self {
    let bundle = Bundle(for: ResolveLUTReferenceBundleToken.self)
    let sourceURL = try requiredFixtureURL(
      fileName: sourceFileName,
      in: bundle
    )
    let goldenURL = try requiredFixtureURL(
      fileName: goldenFileName,
      in: bundle
    )
    let manifestURL = try requiredFixtureURL(
      fileName: manifestFileName,
      in: bundle
    )
    guard
      let productionLUTURL = Bundle.main.url(
        forResource: "AppleLog1 Example",
        withExtension: "cube"
      )
    else {
      throw ResolveLUTReferenceError.missingProductionLUT(
        productionLUTFileName
      )
    }

    let manifestData = try Data(contentsOf: manifestURL)
    let manifest = try JSONDecoder().decode(
      ResolveLUTReferenceManifest.self,
      from: manifestData
    )
    return Self(
      bundle: bundle,
      sourceURL: sourceURL,
      goldenURL: goldenURL,
      manifestURL: manifestURL,
      productionLUTURL: productionLUTURL,
      manifest: manifest
    )
  }

  func validateProvenance() throws {
    guard manifest.schemaVersion == 1 else {
      throw ResolveLUTReferenceError.unsupportedManifestVersion(
        manifest.schemaVersion
      )
    }

    try validate(
      sourceURL,
      against: manifest.files.source,
      role: "Resolve source"
    )
    try validate(
      goldenURL,
      against: manifest.files.output,
      role: "Resolve output"
    )
    try validate(
      productionLUTURL,
      against: manifest.files.lut,
      role: "production LUT"
    )
  }

  func loadSourceImage() throws -> CGImage {
    try Self.loadImage(at: sourceURL)
  }

  func loadGoldenImage() throws -> CGImage {
    try Self.loadImage(at: goldenURL)
  }

  private func validate(
    _ url: URL,
    against record: ResolveLUTReferenceManifest.FileRecord,
    role: String
  ) throws {
    let data = try Data(contentsOf: url)
    let actualSHA256 = SHA256.hash(data: data)
      .map { String(format: "%02x", $0) }
      .joined()
    guard actualSHA256 == record.sha256.lowercased() else {
      throw ResolveLUTReferenceError.fileDigestMismatch(
        role: role,
        fileName: url.lastPathComponent,
        expected: record.sha256,
        actual: actualSHA256
      )
    }
    guard data.count == record.byteCount else {
      throw ResolveLUTReferenceError.fileSizeMismatch(
        role: role,
        fileName: url.lastPathComponent,
        expected: record.byteCount,
        actual: data.count
      )
    }
  }

  private static func requiredFixtureURL(
    fileName: String,
    in bundle: Bundle
  ) throws -> URL {
    let fileURL = URL(filePath: fileName)
    let resourceName = fileURL.deletingPathExtension().lastPathComponent
    let fileExtension = fileURL.pathExtension
    let subdirectories = [
      "Fixtures/ResolveLUTReference",
      "ResolveLUTReference",
    ]

    for subdirectory in subdirectories {
      if let url = bundle.url(
        forResource: resourceName,
        withExtension: fileExtension,
        subdirectory: subdirectory
      ) {
        return url
      }
    }
    if let url = bundle.url(
      forResource: resourceName,
      withExtension: fileExtension
    ) {
      return url
    }

    throw ResolveLUTReferenceError.missingFixture(
      fileName: fileName,
      bundlePath: bundle.bundlePath
    )
  }

  private static func loadImage(at url: URL) throws -> CGImage {
    guard
      let source = CGImageSourceCreateWithURL(url as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(
        source,
        0,
        [
          kCGImageSourceShouldCache: true,
          kCGImageSourceShouldCacheImmediately: true,
        ] as CFDictionary
      )
    else {
      throw ResolveLUTReferenceError.cannotDecodeImage(
        url.lastPathComponent
      )
    }
    return image
  }
}

/// The subset of Resolve's machine-readable provenance used by XCTest.
///
/// Extra keys remain available for human review without coupling the test to
/// every Resolve project setting recorded by the fixture generator.
private struct ResolveLUTReferenceManifest: Decodable {

  struct Files: Decodable {
    let source: FileRecord
    let lut: FileRecord
    let output: FileRecord
  }

  struct FileRecord: Decodable {
    let path: String
    let sha256: String
    let byteCount: Int
  }

  let schemaVersion: Int
  let files: Files
}

/// The Rec.709 full-range source pattern shared by XCTest and Resolve.
private enum Rec709FullRangeGrid {

  static let width = 432
  static let height = 432
  static let patchSize = 16
  static let sampleSize = 8
  static let levelNodeIndices = [0, 8, 16, 24, 32, 40, 48, 56, 64]

  private static let levelsPerChannel = levelNodeIndices.count
  private static let bluePanelColumns = 3

  struct Patch {
    let redIndex: Int
    let greenIndex: Int
    let blueIndex: Int
    let topLeftSampleRect: CGRect

    var inputColorDescription: String {
      let red = Rec709FullRangeGrid.quantizedLevel(redIndex)
      let green = Rec709FullRangeGrid.quantizedLevel(greenIndex)
      let blue = Rec709FullRangeGrid.quantizedLevel(blueIndex)
      return "(r: \(red), g: \(green), b: \(blue))"
    }
  }

  static let patches: [Patch] = {
    var patches: [Patch] = []
    patches.reserveCapacity(
      levelsPerChannel * levelsPerChannel * levelsPerChannel
    )
    let inset = (patchSize - sampleSize) / 2

    for blueIndex in 0..<levelsPerChannel {
      let panelX = blueIndex % bluePanelColumns
      let panelY = blueIndex / bluePanelColumns
      for greenIndex in 0..<levelsPerChannel {
        for redIndex in 0..<levelsPerChannel {
          let patchX = panelX * levelsPerChannel + redIndex
          let patchY = panelY * levelsPerChannel + greenIndex
          patches.append(
            Patch(
              redIndex: redIndex,
              greenIndex: greenIndex,
              blueIndex: blueIndex,
              topLeftSampleRect: CGRect(
                x: patchX * patchSize + inset,
                y: patchY * patchSize + inset,
                width: sampleSize,
                height: sampleSize
              )
            )
          )
        }
      }
    }
    return patches
  }()

  static func makeImage(colorSpace: CGColorSpace) -> CIImage {
    var components = [Float](
      repeating: 0,
      count: width * height * 4
    )

    for storageY in 0..<height {
      // Core Image bitmap rows start at minY. Convert that bottom-up storage
      // coordinate to the fixture's top-left chart contract.
      let topLeftY = height - storageY - 1
      for x in 0..<width {
        let patchX = x / patchSize
        let patchY = topLeftY / patchSize
        let panelX = patchX / levelsPerChannel
        let panelY = patchY / levelsPerChannel
        let redIndex = patchX % levelsPerChannel
        let greenIndex = patchY % levelsPerChannel
        let blueIndex = panelY * bluePanelColumns + panelX
        let offset = (storageY * width + x) * 4
        components[offset] = Float(quantizedLevel(redIndex))
        components[offset + 1] = Float(quantizedLevel(greenIndex))
        components[offset + 2] = Float(quantizedLevel(blueIndex))
        components[offset + 3] = 1
      }
    }

    let data = components.withUnsafeBufferPointer { Data(buffer: $0) }
    return CIImage(
      bitmapData: data,
      bytesPerRow: width * 4 * MemoryLayout<Float>.size,
      size: CGSize(width: width, height: height),
      format: .RGBAf,
      colorSpace: colorSpace
    )
  }

  static func comparePatchInteriors(
    _ lhs: RenderedRGBA8,
    _ rhs: RenderedRGBA8
  ) -> PatchComparison {
    guard
      lhs.width == width,
      lhs.height == height,
      rhs.width == width,
      rhs.height == height
    else {
      return PatchComparison.invalidGeometry(
        lhs: lhs,
        rhs: rhs,
        expectedWidth: width,
        expectedHeight: height
      )
    }

    var maximumChannelDelta = 0.0
    var squaredDeltaTotal = 0.0
    var channelCount = 0
    var worstDiagnostic = "No patches were compared."

    for patch in patches {
      let lhsColor = lhs.averageRGB(inTopLeft: patch.topLeftSampleRect)
      let rhsColor = rhs.averageRGB(inTopLeft: patch.topLeftSampleRect)
      let deltas = [
        abs(lhsColor.red - rhsColor.red),
        abs(lhsColor.green - rhsColor.green),
        abs(lhsColor.blue - rhsColor.blue),
      ]
      for delta in deltas {
        squaredDeltaTotal += delta * delta
        channelCount += 1
      }
      if let patchMaximum = deltas.max(),
        patchMaximum > maximumChannelDelta
      {
        maximumChannelDelta = patchMaximum
        worstDiagnostic = """
          input: \(patch.inputColorDescription)
          sample rect: \(patch.topLeftSampleRect)
          lhs: \(lhsColor)
          rhs: \(rhsColor)
          maximum channel delta: \(patchMaximum)
          """
      }
    }

    return PatchComparison(
      maximumChannelDelta: maximumChannelDelta,
      rootMeanSquareChannelDelta:
        channelCount > 0
        ? sqrt(squaredDeltaTotal / Double(channelCount))
        : .infinity,
      diagnostic: worstDiagnostic
    )
  }

  private static func quantizedLevel(_ index: Int) -> Double {
    let cubeNodeIndex = levelNodeIndices[index]
    let normalized = Double(cubeNodeIndex) / 64
    let uint16Value = (normalized * Double(UInt16.max)).rounded()
    return uint16Value / Double(UInt16.max)
  }
}

/// An RGBA8 materialization in Core Image's bottom-up bitmap row order.
private struct RenderedRGBA8 {

  let width: Int
  let height: Int
  let bytes: [UInt8]

  static func make(
    _ image: CIImage,
    context: CIContext,
    colorSpace: CGColorSpace
  ) throws -> Self {
    let extent = image.extent
    guard
      extent.origin == .zero,
      extent.width.isFinite,
      extent.height.isFinite,
      extent.width == extent.width.rounded(),
      extent.height == extent.height.rounded(),
      extent.width > 0,
      extent.height > 0
    else {
      throw ResolveLUTReferenceError.invalidRenderExtent(extent)
    }

    let width = Int(extent.width)
    let height = Int(extent.height)
    let rowBytes = width * 4
    var bytes = [UInt8](
      repeating: 0,
      count: rowBytes * height
    )
    bytes.withUnsafeMutableBytes { storage in
      guard let baseAddress = storage.baseAddress else { return }
      context.render(
        image,
        toBitmap: baseAddress,
        rowBytes: rowBytes,
        bounds: extent,
        format: .RGBA8,
        colorSpace: colorSpace
      )
    }
    return Self(width: width, height: height, bytes: bytes)
  }

  func averageRGB(inTopLeft rect: CGRect) -> NormalizedRGB {
    let minX = Int(rect.minX)
    let maxX = Int(rect.maxX)
    let minTopLeftY = Int(rect.minY)
    let maxTopLeftY = Int(rect.maxY)
    var redTotal: UInt64 = 0
    var greenTotal: UInt64 = 0
    var blueTotal: UInt64 = 0

    for topLeftY in minTopLeftY..<maxTopLeftY {
      let storageY = height - topLeftY - 1
      for x in minX..<maxX {
        let offset = (storageY * width + x) * 4
        redTotal += UInt64(bytes[offset])
        greenTotal += UInt64(bytes[offset + 1])
        blueTotal += UInt64(bytes[offset + 2])
      }
    }

    let pixelCount = Double((maxX - minX) * (maxTopLeftY - minTopLeftY))
    return NormalizedRGB(
      red: Double(redTotal) / pixelCount / 255,
      green: Double(greenTotal) / pixelCount / 255,
      blue: Double(blueTotal) / pixelCount / 255
    )
  }
}

/// One opaque patch color normalized to zero through one.
private struct NormalizedRGB: CustomStringConvertible {

  let red: Double
  let green: Double
  let blue: Double

  var description: String {
    "(r: \(red), g: \(green), b: \(blue))"
  }
}

/// Aggregate differences across all 729 chart patches.
private struct PatchComparison {

  let maximumChannelDelta: Double
  let rootMeanSquareChannelDelta: Double
  let diagnostic: String

  static func invalidGeometry(
    lhs: RenderedRGBA8,
    rhs: RenderedRGBA8,
    expectedWidth: Int,
    expectedHeight: Int
  ) -> Self {
    Self(
      maximumChannelDelta: .infinity,
      rootMeanSquareChannelDelta: .infinity,
      diagnostic:
        "Expected \(expectedWidth)×\(expectedHeight); "
        + "received lhs \(lhs.width)×\(lhs.height), "
        + "rhs \(rhs.width)×\(rhs.height)."
    )
  }
}

/// Errors that make the external reference unusable rather than skippable.
private enum ResolveLUTReferenceError: Error, LocalizedError {

  case missingFixture(fileName: String, bundlePath: String)
  case missingProductionLUT(String)
  case unsupportedManifestVersion(Int)
  case cannotDecodeImage(String)
  case invalidImageDimensions(
    fileName: String,
    expectedWidth: Int,
    expectedHeight: Int,
    actualWidth: Int,
    actualHeight: Int
  )
  case missingRGBColorProfile(String)
  case invalidRenderExtent(CGRect)
  case fileDigestMismatch(
    role: String,
    fileName: String,
    expected: String,
    actual: String
  )
  case fileSizeMismatch(
    role: String,
    fileName: String,
    expected: Int,
    actual: Int
  )

  var errorDescription: String? {
    switch self {
    case .missingFixture(let fileName, let bundlePath):
      return
        "Missing required DaVinci Resolve golden fixture '\(fileName)' in "
        + "'\(bundlePath)'. Generate and commit the fixture under "
        + "Tests/FargTests/Fixtures/ResolveLUTReference, then ensure it is "
        + "included in FargTests resources. This conformance test does not skip "
        + "when its external oracle is absent."

    case .missingProductionLUT(let fileName):
      return "The hosted Färg app is missing its production LUT '\(fileName)'."

    case .unsupportedManifestVersion(let version):
      return "Unsupported Resolve reference manifest schema version \(version)."

    case .cannotDecodeImage(let fileName):
      return "ImageIO could not decode Resolve fixture '\(fileName)'."

    case .invalidImageDimensions(
      let fileName,
      let expectedWidth,
      let expectedHeight,
      let actualWidth,
      let actualHeight
    ):
      return
        "Resolve fixture '\(fileName)' is \(actualWidth)×\(actualHeight); "
        + "expected \(expectedWidth)×\(expectedHeight)."

    case .missingRGBColorProfile(let fileName):
      return
        "Resolve fixture '\(fileName)' does not contain an RGB color profile."

    case .invalidRenderExtent(let extent):
      return "The LUT reference render extent is invalid: \(extent)."

    case .fileDigestMismatch(
      let role,
      let fileName,
      let expected,
      let actual
    ):
      return
        "\(role) '\(fileName)' does not match the recorded SHA-256. "
        + "Expected \(expected), received \(actual)."

    case .fileSizeMismatch(
      let role,
      let fileName,
      let expected,
      let actual
    ):
      return
        "\(role) '\(fileName)' does not match the recorded byte count. "
        + "Expected \(expected), received \(actual)."
    }
  }
}

private final class ResolveLUTReferenceBundleToken {}
