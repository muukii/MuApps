//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//

import Foundation
import Observation

/// A user-authorized Files directory used as the starting location for video import.
///
/// The bookmark is the access authority. Volume metadata is advisory and exists
/// only to describe or diagnose removable storage without identifying USB hardware.
struct DefaultVideoFolder: Codable, Equatable, Sendable {

  /// The directory name shown in Settings.
  var displayName: String
  /// The containing volume's user-visible name, when the provider exposes it.
  var volumeName: String?
  /// The containing volume's persistent UUID, when its file system provides one.
  var volumeUUIDString: String?
  /// The security-scoped bookmark resolved before presenting the Files picker.
  var bookmarkData: Data
}

/// Keeps one balanced security-scope claim alive for a Files presentation.
///
/// The presenting view owns this value from immediately before opening the file
/// importer until the importer dismisses. Releasing it balances the URL access.
nonisolated final class DefaultVideoFolderAccess: @unchecked Sendable {

  let url: URL

  init?(url: URL) {
    guard url.startAccessingSecurityScopedResource() else { return nil }
    self.url = url
  }

  deinit {
    url.stopAccessingSecurityScopedResource()
  }
}

/// Persists and resolves the single folder that Files should open for videos.
@MainActor
@Observable
final class DefaultVideoFolderStore {

  /// Failures that must be surfaced while changing the saved folder.
  enum StoreError: LocalizedError {
    /// The picker URL did not grant the security scope needed for persistence.
    case accessDenied(String)

    var errorDescription: String? {
      switch self {
      case .accessDenied(let folderName):
        return "Färg couldn't access the video folder “\(folderName)”."
      }
    }
  }

  /// The current default, or `nil` when Files should use its normal location.
  private(set) var folder: DefaultVideoFolder?

  @ObservationIgnored private let indexURL: URL
  @ObservationIgnored private let fileManager: FileManager

  init(
    indexURL: URL? = nil,
    fileManager: FileManager = .default
  ) {
    self.fileManager = fileManager
    self.indexURL = indexURL ?? Self.defaultIndexURL(fileManager: fileManager)
    load()
  }

  /// Replaces the current default with a folder explicitly selected in Files.
  func setFolder(from pickedURL: URL) throws {
    guard let access = DefaultVideoFolderAccess(url: pickedURL) else {
      throw StoreError.accessDenied(pickedURL.lastPathComponent)
    }

    let bookmarkData = try access.url.bookmarkData(
      options: .minimalBookmark,
      includingResourceValuesForKeys: nil,
      relativeTo: nil
    )
    let resourceValues = try? access.url.resourceValues(
      forKeys: [
        .localizedNameKey,
        .volumeLocalizedNameKey,
        .volumeUUIDStringKey,
      ]
    )
    let localizedFolderName =
      resourceValues?.localizedName ?? pickedURL.lastPathComponent
    let newFolder = DefaultVideoFolder(
      displayName: localizedFolderName,
      volumeName: resourceValues?.volumeLocalizedName,
      volumeUUIDString: resourceValues?.volumeUUIDString,
      bookmarkData: bookmarkData
    )

    try persist(newFolder)
    folder = newFolder
  }

  /// Clears the preferred starting location without modifying the external folder.
  func clearFolder() throws {
    if fileManager.fileExists(atPath: indexURL.path) {
      try fileManager.removeItem(at: indexURL)
    }
    folder = nil
  }

  /// Resolves the current bookmark for the lifetime of one Files presentation.
  ///
  /// Failure intentionally returns `nil`: video import remains available and
  /// falls back to the system's normal Files location when storage is absent.
  func makeAccess() -> DefaultVideoFolderAccess? {
    guard let folder else { return nil }

    do {
      var isStale = false
      let url = try URL(
        resolvingBookmarkData: folder.bookmarkData,
        bookmarkDataIsStale: &isStale
      )
      guard let access = DefaultVideoFolderAccess(url: url) else { return nil }

      if isStale {
        renewBookmark(using: access.url)
      }
      return access
    } catch {
      return nil
    }
  }

  private func renewBookmark(using url: URL) {
    guard
      var renewedFolder = folder,
      let bookmarkData = try? url.bookmarkData(
        options: .minimalBookmark,
        includingResourceValuesForKeys: nil,
        relativeTo: nil
      )
    else {
      return
    }

    renewedFolder.bookmarkData = bookmarkData
    do {
      try persist(renewedFolder)
      folder = renewedFolder
    } catch {
      assertionFailure("Failed to renew the default video-folder bookmark: \(error)")
    }
  }

  private func load() {
    guard
      let data = try? Data(contentsOf: indexURL),
      let decoded = try? JSONDecoder().decode(DefaultVideoFolder.self, from: data)
    else {
      return
    }
    folder = decoded
  }

  private func persist(_ folder: DefaultVideoFolder) throws {
    try fileManager.createDirectory(
      at: indexURL.deletingLastPathComponent(),
      withIntermediateDirectories: true
    )
    let data = try JSONEncoder().encode(folder)
    try data.write(to: indexURL, options: .atomic)
  }

  private nonisolated static func defaultIndexURL(
    fileManager: FileManager
  ) -> URL {
    fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
      .appendingPathComponent("default-video-folder.json")
  }
}
