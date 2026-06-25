import Foundation
import UIKit

@MainActor
final class LUTCatalog: ObservableObject {

  @Published private(set) var bundled: [LUT] = []
  @Published private(set) var userLUTs: [LUT] = []

  var all: [LUT] { bundled + userLUTs }

  init() {
    bundled = BuiltinLUTs.all()
    loadUserLUTsSync()
  }

  // MARK: - User imported

  private var userDir: URL {
    let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
    return docs.appendingPathComponent("UserLUTs", isDirectory: true)
  }

  private func loadUserLUTsSync() {
    let dir = userDir
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    guard let entries = try? FileManager.default.contentsOfDirectory(
      at: dir,
      includingPropertiesForKeys: nil,
      options: [.skipsHiddenFiles]
    ) else { return }

    var result: [LUT] = []
    for url in entries.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
      if let lut = try? loadUserLUT(at: url) {
        result.append(lut)
      }
    }
    userLUTs = result
  }

  private func loadUserLUT(at url: URL) throws -> LUT {
    let name = url.deletingPathExtension().lastPathComponent
    let id = "user:\(url.lastPathComponent)"
    switch url.pathExtension.lowercased() {
    case "cube":
      let text = try String(contentsOf: url, encoding: .utf8)
      return try CubeLUTParser.parse(text: text, name: name, id: id, source: .userFile(url))
    case "png", "jpg", "jpeg", "heic":
      let data = try Data(contentsOf: url)
      return try HALDLUTParser.parse(data: data, name: name, id: id, source: .userFile(url))
    default:
      throw LUTLoadError.unsupportedFormat
    }
  }

  // MARK: - Import

  func importFile(at sourceURL: URL) throws -> LUT {
    let dir = userDir
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let dest = dir.appendingPathComponent(sourceURL.lastPathComponent)

    let needsAccess = sourceURL.startAccessingSecurityScopedResource()
    defer { if needsAccess { sourceURL.stopAccessingSecurityScopedResource() } }

    if FileManager.default.fileExists(atPath: dest.path) {
      try FileManager.default.removeItem(at: dest)
    }
    try FileManager.default.copyItem(at: sourceURL, to: dest)
    let lut = try loadUserLUT(at: dest)
    if !userLUTs.contains(where: { $0.id == lut.id }) {
      userLUTs.append(lut)
    }
    return lut
  }
}
