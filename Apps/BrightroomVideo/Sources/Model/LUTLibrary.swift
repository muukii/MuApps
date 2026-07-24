//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//

import BrightroomParametric
import Foundation
import UniformTypeIdentifiers

/// The user's LUT collection: imports `.cube` / image LUTs from Files, persists a
/// JSON index, seeds bundled starters, and materializes `ColorCubeFeature`s.
@MainActor
@Observable
final class LUTLibrary {

  enum LibraryError: LocalizedError {
    case unsupportedType(String)
    case missingBundledResource(String)

    var errorDescription: String? {
      switch self {
      case .unsupportedType(let ext):
        return "Unsupported LUT type: .\(ext). Import a .cube, .png, or .jpg file."
      case .missingBundledResource(let name):
        return "Bundled LUT '\(name)' is missing."
      }
    }
  }

  /// The LUTs available to the editor, imported first then bundled starters.
  private(set) var luts: [LUT] = []

  /// Materialized features keyed by LUT id (cubeData is multi-MB, so cache it).
  private var featureCache: [String: ColorCubeFeature] = [:]

  private let fileManager = FileManager.default

  init() {
    load()
    seedBundledIfNeeded()
  }

  // MARK: - Import

  /// The content types accepted by the Files importer.
  static var importableContentTypes: [UTType] {
    var types: [UTType] = [.png, .jpeg]
    if let cube = UTType(filenameExtension: "cube", conformingTo: .data) {
      types.insert(cube, at: 0)
    }
    return types
  }

  /// Imports a LUT from a (security-scoped) Files URL, copying it into storage.
  @discardableResult
  func importLUT(from pickedURL: URL) throws -> LUT {
    let didScope = pickedURL.startAccessingSecurityScopedResource()
    defer {
      if didScope { pickedURL.stopAccessingSecurityScopedResource() }
    }

    let ext = pickedURL.pathExtension.lowercased()
    let format: LUT.Format
    switch ext {
    case "cube": format = .cube
    case "png", "jpg", "jpeg": format = .image
    default: throw LibraryError.unsupportedType(ext)
    }

    try createStorageDirectoryIfNeeded()
    let storedName = "\(UUID().uuidString).\(ext)"
    let destination = storageDirectory.appendingPathComponent(storedName)
    try fileManager.copyItem(at: pickedURL, to: destination)

    let id = UUID().uuidString
    // Build once to validate the file and learn its real name / dimension.
    let feature = try makeFeature(
      format: format,
      url: destination,
      id: id,
      fallbackName: pickedURL.deletingPathExtension().lastPathComponent,
      amount: 1
    )

    let lut = LUT(
      id: id,
      name: feature.name,
      format: format,
      dimension: feature.dimension,
      source: .imported(fileName: storedName)
    )
    featureCache[id] = feature
    luts.insert(lut, at: 0)
    save()
    return lut
  }

  // MARK: - Delete

  func delete(_ lut: LUT) {
    featureCache[lut.id] = nil
    if case .imported(let fileName) = lut.source {
      let url = storageDirectory.appendingPathComponent(fileName)
      try? fileManager.removeItem(at: url)
    }
    luts.removeAll { $0.id == lut.id }
    save()
  }

  // MARK: - Feature materialization

  /// Resolves a LUT into a `ColorCubeFeature`, applying `amount` and a stable
  /// `FeatureID` so equal selections compare equal and the CI filter caches.
  func feature(for lut: LUT, amount: Double = 1) throws -> ColorCubeFeature {
    let base: ColorCubeFeature
    if let cached = featureCache[lut.id] {
      base = cached
    } else {
      base = try makeFeature(
        format: lut.format,
        url: try resolveURL(lut),
        id: lut.id,
        fallbackName: lut.name,
        amount: 1
      )
      featureCache[lut.id] = base
    }

    return ColorCubeFeature(
      id: FeatureID(rawValue: lut.id),
      name: base.name,
      identifier: lut.id,
      amount: amount,
      dimension: base.dimension,
      cubeData: base.cubeData
    )
  }

  private func makeFeature(
    format: LUT.Format,
    url: URL,
    id: String,
    fallbackName: String,
    amount: Double
  ) throws -> ColorCubeFeature {
    switch format {
    case .cube:
      return try ColorCubeFeature(
        contentsOfCubeFile: url,
        id: FeatureID(rawValue: id),
        amount: amount
      )
    case .image:
      return try ColorCubeFeature(
        cubeImageAt: url,
        id: FeatureID(rawValue: id),
        name: fallbackName,
        amount: amount
      )
    }
  }

  private func resolveURL(_ lut: LUT) throws -> URL {
    switch lut.source {
    case .imported(let fileName):
      return storageDirectory.appendingPathComponent(fileName)
    case .bundled(let resource, let ext):
      guard let url = Bundle.main.url(forResource: resource, withExtension: ext) else {
        throw LibraryError.missingBundledResource(resource)
      }
      return url
    }
  }

  // MARK: - Bundled starters

  private func seedBundledIfNeeded() {
    let starters: [(resource: String, ext: String, name: String)] = [
      ("LUT_64_1", "jpg", "Warm 01"),
      ("LUT_64_Gloss", "png", "Gloss"),
      ("LUT_64_Dark_HighContrast_v3", "png", "Dark Contrast"),
    ]

    var didChange = false
    for starter in starters {
      let id = "bundled.\(starter.resource)"
      guard luts.contains(where: { $0.id == id }) == false else { continue }
      guard Bundle.main.url(forResource: starter.resource, withExtension: starter.ext) != nil else {
        continue
      }
      luts.append(
        LUT(
          id: id,
          name: starter.name,
          format: .image,
          dimension: 64,
          source: .bundled(resource: starter.resource, ext: starter.ext)
        )
      )
      didChange = true
    }
    if didChange {
      save()
    }
  }

  // MARK: - Persistence

  private var storageDirectory: URL {
    applicationSupport.appendingPathComponent("LUTs", isDirectory: true)
  }

  private var indexURL: URL {
    applicationSupport.appendingPathComponent("luts.json")
  }

  private var applicationSupport: URL {
    fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
  }

  private func createStorageDirectoryIfNeeded() throws {
    try fileManager.createDirectory(at: storageDirectory, withIntermediateDirectories: true)
  }

  private func load() {
    guard let data = try? Data(contentsOf: indexURL),
          let decoded = try? JSONDecoder().decode([LUT].self, from: data)
    else {
      return
    }
    luts = decoded
  }

  private func save() {
    do {
      try fileManager.createDirectory(at: applicationSupport, withIntermediateDirectories: true)
      let data = try JSONEncoder().encode(luts)
      try data.write(to: indexURL, options: .atomic)
    } catch {
      assertionFailure("Failed to persist LUT index: \(error)")
    }
  }
}
