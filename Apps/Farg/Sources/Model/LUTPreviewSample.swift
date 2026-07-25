//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//

import CoreGraphics
import CoreTransferable
import Foundation
import ImageIO
import Observation
import UniformTypeIdentifiers

/// A labeled still image used to compare every LUT under the same input.
///
/// Labels are intentionally user-authored so a sample can carry the source
/// color-space meaning that pixels alone cannot express, such as “Sony S-Log3”.
struct LUTPreviewSample: Identifiable, Codable, Hashable, Sendable {

  /// The storage backing a preview source.
  enum Source: Codable, Hashable, Sendable {
    /// The app-generated color and tone test pattern.
    case builtIn
    /// A normalized JPEG in the app's Application Support directory.
    case imported(fileName: String)
  }

  /// The stable sample identity used by selection and render caches.
  var id: String
  /// The input profile or camera name shown beside every LUT result.
  var label: String
  /// The pixels used as the common LUT input.
  var source: Source

  var canEdit: Bool {
    if case .imported = source { return true }
    return false
  }

  static let colorTest = LUTPreviewSample(
    id: "built-in.color-test",
    label: "Color Test",
    source: .builtIn
  )
}

/// A decoded, orientation-normalized source shared by visible LUT previews.
struct LUTPreviewSourceImage: @unchecked Sendable {

  /// The longest pixel edge retained for cell and Settings preview rendering.
  nonisolated static let maximumPixelSize = 300

  /// Changes whenever a different still should invalidate rendered thumbnails.
  var id: String
  /// The source pixels before LUT evaluation, bounded by `maximumPixelSize`.
  var image: CGImage

  /// Creates a preview input and catches oversized producers in debug builds.
  nonisolated init(id: String, image: CGImage) {
    assert(
      max(image.width, image.height) <= Self.maximumPixelSize,
      "LUT preview sources must be pixel-bounded before cell rendering."
    )
    self.id = id
    self.image = image
  }
}

/// An app-owned image copied from the temporary Photos picker representation.
struct PickedLUTPreviewImage: Transferable {

  let url: URL

  static var transferRepresentation: some TransferRepresentation {
    FileRepresentation(contentType: .image) { image in
      SentTransferredFile(image.url)
    } importing: { received in
      let directory = FileManager.default.urls(
        for: .cachesDirectory,
        in: .userDomainMask
      )[0]
      .appendingPathComponent("PickedLUTPreviewImages", isDirectory: true)
      try FileManager.default.createDirectory(
        at: directory,
        withIntermediateDirectories: true
      )
      let destination = directory.appendingPathComponent(
        "\(UUID().uuidString)-\(received.file.lastPathComponent)"
      )
      try FileManager.default.copyItem(at: received.file, to: destination)
      return PickedLUTPreviewImage(url: destination)
    }
  }
}

/// Persists the user's labeled LUT comparison sources independently of LUTs.
@MainActor
@Observable
final class LUTPreviewSampleLibrary {

  enum SampleError: LocalizedError {
    case emptyLabel
    case invalidImage
    case missingImage(String)

    var errorDescription: String? {
      switch self {
      case .emptyLabel:
        return "Enter a label that identifies the sample or Log profile."
      case .invalidImage:
        return "The selected item could not be decoded as an image."
      case .missingImage(let label):
        return "The preview image for “\(label)” is missing."
      }
    }
  }

  /// Built-in and user-added samples available to every LUT preview.
  private(set) var samples: [LUTPreviewSample] = [.colorTest]

  /// The sample applied to Settings previews.
  private(set) var selectedSampleID = LUTPreviewSample.colorTest.id

  /// Invalidates source loading after a selection or metadata change.
  private(set) var revision: UInt = 0

  private let fileManager = FileManager.default

  init() {
    load()
  }

  var selectedSample: LUTPreviewSample {
    samples.first { $0.id == selectedSampleID } ?? .colorTest
  }

  /// Makes one labeled sample the common input for all Settings previews.
  func select(id: LUTPreviewSample.ID) throws {
    guard samples.contains(where: { $0.id == id }) else { return }
    let payload = PersistedSamples(
      samples: importedSamples,
      selectedSampleID: id
    )
    try persist(payload)
    selectedSampleID = id
    revision &+= 1
  }

  /// Normalizes and saves a Photos image, then selects it for comparison.
  @discardableResult
  func addSample(
    from pickedURL: URL,
    label: String
  ) async throws -> LUTPreviewSample {
    let normalizedLabel = try Self.normalized(label: label)
    let encodedImage = try await Task.detached(priority: .userInitiated) {
      try Self.makeNormalizedJPEG(from: pickedURL)
    }.value

    try fileManager.createDirectory(
      at: imageDirectory,
      withIntermediateDirectories: true
    )
    let fileName = "\(UUID().uuidString).jpg"
    let destination = imageDirectory.appendingPathComponent(fileName)
    try encodedImage.write(to: destination, options: .atomic)

    let sample = LUTPreviewSample(
      id: UUID().uuidString,
      label: normalizedLabel,
      source: .imported(fileName: fileName)
    )
    let updatedSamples = importedSamples + [sample]
    do {
      try persist(
        PersistedSamples(
          samples: updatedSamples,
          selectedSampleID: sample.id
        )
      )
    } catch {
      try? fileManager.removeItem(at: destination)
      throw error
    }

    samples = [.colorTest] + updatedSamples
    selectedSampleID = sample.id
    revision &+= 1
    return sample
  }

  /// Updates the semantic input label without rewriting its image.
  func rename(_ sample: LUTPreviewSample, label: String) throws {
    guard sample.canEdit else { return }
    let normalizedLabel = try Self.normalized(label: label)
    var updatedSamples = importedSamples
    guard let index = updatedSamples.firstIndex(where: { $0.id == sample.id }) else {
      return
    }
    updatedSamples[index].label = normalizedLabel
    try persist(
      PersistedSamples(
        samples: updatedSamples,
        selectedSampleID: selectedSampleID
      )
    )
    samples = [.colorTest] + updatedSamples
    revision &+= 1
  }

  /// Deletes one user-added sample and falls back to the color test if selected.
  func delete(_ sample: LUTPreviewSample) throws {
    guard sample.canEdit else { return }
    let updatedSamples = importedSamples.filter { $0.id != sample.id }
    let updatedSelection =
      selectedSampleID == sample.id
        ? LUTPreviewSample.colorTest.id
        : selectedSampleID
    try persist(
      PersistedSamples(
        samples: updatedSamples,
        selectedSampleID: updatedSelection
      )
    )
    samples = [.colorTest] + updatedSamples
    selectedSampleID = updatedSelection
    if case .imported(let fileName) = sample.source {
      try? fileManager.removeItem(
        at: imageDirectory.appendingPathComponent(fileName)
      )
    }
    revision &+= 1
  }

  /// Decodes the selected sample away from SwiftUI body evaluation.
  func loadSelectedImage() async throws -> LUTPreviewSourceImage {
    let sample = selectedSample
    let sourceID = "\(sample.id).\(revision)"
    let url: URL?
    switch sample.source {
    case .builtIn:
      url = nil
    case .imported(let fileName):
      url = imageDirectory.appendingPathComponent(fileName)
    }

    let image = try await Task.detached(priority: .userInitiated) {
      if let url {
        do {
          return try Self.makeThumbnail(from: url)
        } catch {
          throw SampleError.missingImage(sample.label)
        }
      }
      return try Self.makeColorTestImage()
    }.value

    return LUTPreviewSourceImage(
      id: sourceID,
      image: image
    )
  }

  /// Supplies deterministic pixels to Xcode previews without touching storage.
  nonisolated static func makePreviewSource() -> LUTPreviewSourceImage? {
    guard let image = try? makeColorTestImage() else { return nil }
    return LUTPreviewSourceImage(id: "preview.color-test", image: image)
  }

  // MARK: - Persistence

  /// The atomic metadata payload; image bytes are stored as separate files.
  private struct PersistedSamples: Codable {
    var samples: [LUTPreviewSample]
    var selectedSampleID: LUTPreviewSample.ID
  }

  private var importedSamples: [LUTPreviewSample] {
    samples.filter(\.canEdit)
  }

  private var applicationSupport: URL {
    fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
  }

  private var imageDirectory: URL {
    applicationSupport.appendingPathComponent(
      "LUTPreviewSamples",
      isDirectory: true
    )
  }

  private var indexURL: URL {
    applicationSupport.appendingPathComponent("lut-preview-samples.json")
  }

  private func load() {
    guard
      let data = try? Data(contentsOf: indexURL),
      let payload = try? JSONDecoder().decode(PersistedSamples.self, from: data)
    else {
      return
    }
    samples = [.colorTest] + payload.samples.filter(\.canEdit)
    selectedSampleID =
      samples.contains(where: { $0.id == payload.selectedSampleID })
        ? payload.selectedSampleID
        : LUTPreviewSample.colorTest.id
  }

  private func persist(_ payload: PersistedSamples) throws {
    try fileManager.createDirectory(
      at: applicationSupport,
      withIntermediateDirectories: true
    )
    let data = try JSONEncoder().encode(payload)
    try data.write(to: indexURL, options: .atomic)
  }

  // MARK: - Image preparation

  private nonisolated static func normalized(label: String) throws -> String {
    let normalized = label.trimmingCharacters(in: .whitespacesAndNewlines)
    guard normalized.isEmpty == false else {
      throw SampleError.emptyLabel
    }
    return normalized
  }

  /// Downsamples large Photos assets and bakes their EXIF orientation.
  private nonisolated static func makeNormalizedJPEG(from url: URL) throws -> Data {
    let image = try makeThumbnail(from: url)

    let data = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(
        data,
        UTType.jpeg.identifier as CFString,
        1,
        nil
      )
    else {
      throw SampleError.invalidImage
    }
    CGImageDestinationAddImage(
      destination,
      image,
      [
        kCGImageDestinationLossyCompressionQuality: 0.92,
      ] as CFDictionary
    )
    guard CGImageDestinationFinalize(destination) else {
      throw SampleError.invalidImage
    }
    return data as Data
  }

  /// Decodes only the bounded preview representation instead of the full image.
  private nonisolated static func makeThumbnail(from url: URL) throws -> CGImage {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
      throw SampleError.invalidImage
    }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize:
        LUTPreviewSourceImage.maximumPixelSize,
    ]
    guard
      let image = CGImageSourceCreateThumbnailAtIndex(
        source,
        0,
        options as CFDictionary
      )
    else {
      throw SampleError.invalidImage
    }
    return image
  }

  /// Produces an always-available neutral input before custom Log samples exist.
  private nonisolated static func makeColorTestImage() throws -> CGImage {
    let designSize = CGSize(width: 960, height: 600)
    let width = LUTPreviewSourceImage.maximumPixelSize
    let height = Int(
      (CGFloat(width) * designSize.height / designSize.width).rounded()
    )
    let colorSpace =
      CGColorSpace(name: CGColorSpace.displayP3)
      ?? CGColorSpaceCreateDeviceRGB()
    guard
      let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      )
    else {
      throw SampleError.invalidImage
    }
    context.scaleBy(
      x: CGFloat(width) / designSize.width,
      y: CGFloat(height) / designSize.height
    )

    context.setFillColor(
      CGColor(
        colorSpace: colorSpace,
        components: [0.18, 0.18, 0.18, 1]
      )!
    )
    context.fill(CGRect(origin: .zero, size: designSize))

    let gradientColors = [
      CGColor(colorSpace: colorSpace, components: [0.03, 0.03, 0.03, 1])!,
      CGColor(colorSpace: colorSpace, components: [0.92, 0.92, 0.92, 1])!,
    ] as CFArray
    if let gradient = CGGradient(
      colorsSpace: colorSpace,
      colors: gradientColors,
      locations: [0, 1]
    ) {
      context.drawLinearGradient(
        gradient,
        start: CGPoint(x: 80, y: 420),
        end: CGPoint(x: 880, y: 420),
        options: []
      )
    }

    let patches: [[CGFloat]] = [
      [0.72, 0.15, 0.12, 1],
      [0.89, 0.47, 0.12, 1],
      [0.91, 0.78, 0.13, 1],
      [0.24, 0.64, 0.22, 1],
      [0.13, 0.52, 0.76, 1],
      [0.23, 0.22, 0.69, 1],
      [0.55, 0.20, 0.68, 1],
      [0.78, 0.28, 0.52, 1],
    ]
    let patchWidth: CGFloat = 100
    for (index, components) in patches.enumerated() {
      context.setFillColor(
        CGColor(colorSpace: colorSpace, components: components)!
      )
      context.fill(
        CGRect(
          x: 80 + CGFloat(index) * patchWidth,
          y: 110,
          width: patchWidth,
          height: 180
        ).insetBy(dx: 6, dy: 6)
      )
    }

    guard let image = context.makeImage() else {
      throw SampleError.invalidImage
    }
    return image
  }
}
