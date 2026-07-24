//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//

import Foundation

/// A LUT the user owns, either imported from Files or bundled as a starter.
///
/// This is lightweight metadata. The heavy `cubeData` is materialized on demand
/// by `LUTLibrary` into a `BrightroomParametric.ColorCubeFeature` and cached.
struct LUT: Identifiable, Hashable, Codable {

  /// The on-disk encoding of a LUT.
  enum Format: String, Hashable, Codable {
    /// An Adobe / DaVinci Resolve `.cube` text 3D LUT.
    case cube
    /// A square image LUT (Hald/CLUT PNG or JPEG).
    case image
  }

  /// Where the LUT file lives.
  enum Source: Hashable, Codable {
    /// A file copied into the app's Application Support storage.
    case imported(fileName: String)
    /// A resource shipped inside the app bundle.
    case bundled(resource: String, ext: String)
  }

  /// A stable identity used as both the persisted id and the `FeatureID` seed.
  var id: String
  /// The user-facing display name.
  var name: String
  /// The LUT encoding.
  var format: Format
  /// The cube dimension (display only; image LUTs re-infer at materialization).
  var dimension: Int
  /// The file location.
  var source: Source

  var isBundled: Bool {
    if case .bundled = source { return true }
    return false
  }
}
