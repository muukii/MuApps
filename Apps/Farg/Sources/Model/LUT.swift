//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//

import Foundation

/// A LUT copied from a file or folder the user selected in Files.
///
/// This is lightweight metadata. The heavy `cubeData` is materialized on demand
/// by `LUTLibrary` into a `BrightroomParametric.ColorCubeFeature` and cached.
struct LUT: Identifiable, Hashable, Codable, Sendable {

  /// The on-disk encoding of a LUT.
  enum Format: String, Hashable, Codable, Sendable {
    /// An Adobe / DaVinci Resolve `.cube` text 3D LUT.
    case cube
    /// A square image LUT (Hald/CLUT PNG or JPEG).
    case image

    /// Resolves a supported filename extension into its LUT encoding.
    nonisolated init?(fileExtension: String) {
      switch fileExtension.lowercased() {
      case "cube":
        self = .cube
      case "png", "jpg", "jpeg":
        self = .image
      default:
        return nil
      }
    }
  }

  /// The linked folder entry that produced an app-owned LUT copy.
  ///
  /// `storedFileName` remains the rendering source; this metadata only records
  /// where a future folder synchronization should look for updates.
  struct LinkedFolderOrigin: Hashable, Codable, Sendable {
    /// The persistent linked-folder identity.
    var folderID: String
    /// The recursive path below the linked directory.
    var relativePath: String
    /// File metadata captured when this copy was last synchronized.
    var fingerprint: LUTFileFingerprint
  }

  /// A stable identity used as both the persisted id and the `FeatureID` seed.
  var id: String
  /// The user-facing display name.
  var name: String
  /// The LUT encoding.
  var format: Format
  /// The cube dimension (display only; image LUTs re-infer at materialization).
  var dimension: Int
  /// The app-owned file inside the LUT Application Support directory.
  var storedFileName: String
  /// The external folder origin, or `nil` for an independently imported LUT.
  var linkedFolderOrigin: LinkedFolderOrigin? = nil

  var isLinkedFolderItem: Bool {
    linkedFolderOrigin != nil
  }

  var canDeleteManually: Bool {
    linkedFolderOrigin == nil
  }
}
