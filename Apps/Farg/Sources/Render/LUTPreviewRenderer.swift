//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//

import BrightroomParametric
import CoreGraphics
import CoreImage
import Foundation

/// The file-backed, lightweight input needed to render one LUT thumbnail.
struct LUTPreviewRecipe: Sendable {

  var lutID: String
  var name: String
  var format: LUT.Format
  var fileURL: URL
}

/// Holds a decoded LUT as an object suitable for actor-owned `NSCache` storage.
private final class LUTPreviewFeatureCacheEntry {

  let feature: ColorCubeFeature

  nonisolated init(feature: ColorCubeFeature) {
    self.feature = feature
  }
}

/// Coordinates concurrent still-preview rendering and its thumbnail cache.
///
/// The actor serializes cache and in-flight request bookkeeping only. LUT
/// decoding and image rendering run independently on the concurrent executor.
actor LUTPreviewRenderer {

  static let shared = LUTPreviewRenderer()

  enum RenderError: LocalizedError {
    case failedToCreateImage

    var errorDescription: String? {
      "Färg could not render this LUT preview."
    }
  }

  private let imageCache = NSCache<NSString, CGImage>()
  private let featureCache = NSCache<NSString, LUTPreviewFeatureCacheEntry>()
  private var renderingTasks: [String: Task<CGImage, any Error>] = [:]
  private var featureLoadingTasks: [String: Task<ColorCubeFeature, any Error>] = [:]

  init() {
    imageCache.countLimit = 160
    imageCache.totalCostLimit = 96 * 1_024 * 1_024
    featureCache.countLimit = 32
    featureCache.totalCostLimit = 64 * 1_024 * 1_024
  }

  /// Returns a cached or newly rendered exposure-plus-LUT result.
  func render(
    source: LUTPreviewSourceImage,
    recipe: LUTPreviewRecipe?,
    exposure: ExposureAdjustment = .neutral,
    libraryRevision: UInt
  ) async throws -> CGImage {
    guard recipe != nil || exposure.isNeutral == false else {
      return source.image
    }
    let itemKey = recipe.map { "lut:\($0.lutID)" } ?? "original"
    let key =
      "\(source.id)|\(itemKey)|\(libraryRevision)|\(exposure.ev.bitPattern)"
    if let cached = imageCache.object(forKey: key as NSString) {
      return cached
    }
    if let renderingTask = renderingTasks[key] {
      return try await renderingTask.value
    }

    let renderingTask = Task { @concurrent [self] in
      let lutFeature: ColorCubeFeature?
      if let recipe {
        lutFeature = try await feature(
          for: recipe,
          libraryRevision: libraryRevision
        )
      } else {
        lutFeature = nil
      }
      return try Self.makeImage(
        source: source,
        feature: lutFeature,
        exposure: exposure
      )
    }
    renderingTasks[key] = renderingTask

    do {
      let image = try await renderingTask.value
      imageCache.setObject(
        image,
        forKey: key as NSString,
        cost: image.bytesPerRow * image.height
      )
      renderingTasks.removeValue(forKey: key)
      return image
    } catch {
      renderingTasks.removeValue(forKey: key)
      throw error
    }
  }

  /// Returns one decoded LUT, coalescing cache misses across source images.
  private func feature(
    for recipe: LUTPreviewRecipe,
    libraryRevision: UInt
  ) async throws -> ColorCubeFeature {
    let key = "\(recipe.lutID)|\(libraryRevision)"
    if let cached = featureCache.object(forKey: key as NSString) {
      return cached.feature
    }
    if let loadingTask = featureLoadingTasks[key] {
      return try await loadingTask.value
    }

    let loadingTask = Task { @concurrent in
      try Self.makeFeature(recipe: recipe)
    }
    featureLoadingTasks[key] = loadingTask

    do {
      let feature = try await loadingTask.value
      featureCache.setObject(
        LUTPreviewFeatureCacheEntry(feature: feature),
        forKey: key as NSString,
        cost: feature.cubeData.count
      )
      featureLoadingTasks.removeValue(forKey: key)
      return feature
    } catch {
      featureLoadingTasks.removeValue(forKey: key)
      throw error
    }
  }

  /// Decodes one file-backed LUT without retaining temporary parser objects.
  private nonisolated static func makeFeature(
    recipe: LUTPreviewRecipe
  ) throws -> ColorCubeFeature {
    try autoreleasepool {
      switch recipe.format {
      case .cube:
        return try ColorCubeFeature(
          contentsOfCubeFile: recipe.fileURL,
          id: FeatureID(rawValue: recipe.lutID),
          name: recipe.name,
          amount: 1
        )
      case .image:
        return try ColorCubeFeature(
          cubeImageAt: recipe.fileURL,
          id: FeatureID(rawValue: recipe.lutID),
          name: recipe.name,
          amount: 1
        )
      }
    }
  }

  /// Materializes one result from already-decoded LUT data.
  private nonisolated static func makeImage(
    source: LUTPreviewSourceImage,
    feature: ColorCubeFeature?,
    exposure: ExposureAdjustment
  ) throws -> CGImage {
    try autoreleasepool {
      var features: [MainFeature] = [
        .effect(exposure.feature)
      ]
      if let feature {
        features.append(.effect(feature))
      }
      let document = EditingDocument(
        mainTree: MainTree(features: features)
      )
      let sourceImage = CIImage(cgImage: source.image)
      let output = try ParametricImageRenderer().makeImage(
        from: sourceImage,
        document: document
      )
      guard
        let rendered = FargCIContext.shared.createCGImage(
          output,
          from: output.extent,
          format: .RGBA8,
          colorSpace:
            feature == nil
            ? source.image.colorSpace
              ?? CGColorSpace(name: CGColorSpace.sRGB)!
            : FargLUTOutputColorSpace.rec709.coreMediaDeliveryColorSpace,
          deferred: false
        )
      else {
        throw RenderError.failedToCreateImage
      }
      return rendered
    }
  }
}
