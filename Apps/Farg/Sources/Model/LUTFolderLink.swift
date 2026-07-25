//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//

import Foundation

/// A user-authorized Files directory that can supply LUTs across app launches.
///
/// The bookmark grants access to the external directory. LUT bytes are still
/// copied into Application Support before they become part of the library.
struct LUTFolderLink: Identifiable, Hashable, Codable, Sendable {

  /// Stable identity used by synchronized LUT origins.
  var id: String
  /// The directory name shown in the library.
  var displayName: String
  /// A bookmark for resolving the security-scoped directory URL.
  var bookmarkData: Data
  /// The most recent successful directory scan.
  var lastScannedAt: Date?
}

/// A linked folder organized exactly like the supported LUT paths below it.
///
/// This is derived presentation state rather than persisted data. The root
/// represents the linked directory itself; nested directories are represented
/// by `folders`, and LUTs directly inside a directory live in `luts`.
struct LUTFolderCollection: Identifiable, Hashable, Sendable {

  /// The persistent linked-folder identity.
  var id: String
  /// The root directory name selected in Files.
  var name: String
  /// The most recent successful automatic synchronization.
  var lastSyncedAt: Date?
  /// LUTs stored directly in the linked root directory.
  var luts: [LUT]
  /// Nested directories that contain supported LUTs.
  var folders: [LUTFolderNode]

  /// Reconstructs a linked directory hierarchy from persisted relative paths.
  static func make(folder: LUTFolderLink, luts: [LUT]) -> Self {
    let entries = luts.compactMap { lut -> LUTFolderTreeEntry? in
      guard
        let origin = lut.linkedFolderOrigin,
        origin.folderID == folder.id
      else {
        return nil
      }
      let components = origin.relativePath
        .split(separator: "/", omittingEmptySubsequences: true)
        .map(String.init)
      guard components.isEmpty == false else { return nil }
      return LUTFolderTreeEntry(components: components, lut: lut)
    }
    let root = LUTFolderNode.makeRoot(folderID: folder.id, entries: entries)
    return Self(
      id: folder.id,
      name: folder.displayName,
      lastSyncedAt: folder.lastScannedAt,
      luts: root.luts,
      folders: root.folders
    )
  }
}

/// One nested directory in a linked LUT folder.
struct LUTFolderNode: Identifiable, Hashable, Sendable {

  /// Stable identity composed from the link id and relative directory path.
  var id: String
  /// The directory's final path component.
  var name: String
  /// The directory path below the linked root.
  var relativePath: String
  /// LUTs stored directly in this directory.
  var luts: [LUT]
  /// Child directories that contain supported LUTs.
  var folders: [Self]

  fileprivate static func makeRoot(
    folderID: String,
    entries: [LUTFolderTreeEntry]
  ) -> Self {
    make(
      folderID: folderID,
      name: "",
      relativePath: "",
      entries: entries
    )
  }

  private static func make(
    folderID: String,
    name: String,
    relativePath: String,
    entries: [LUTFolderTreeEntry]
  ) -> Self {
    let directLUTs = entries
      .filter { $0.components.count == 1 }
      .sorted {
        $0.components[0].localizedStandardCompare($1.components[0])
          == .orderedAscending
      }
      .map(\.lut)
    let nestedEntries = entries.filter { $0.components.count > 1 }
    let groupedEntries = Dictionary(
      grouping: nestedEntries,
      by: { $0.components[0] }
    )
    let folders = groupedEntries.keys
      .sorted {
        $0.localizedStandardCompare($1) == .orderedAscending
      }
      .map { childName in
        let childPath = relativePath.isEmpty
          ? childName
          : "\(relativePath)/\(childName)"
        let childEntries = groupedEntries[childName, default: []].map {
          LUTFolderTreeEntry(
            components: Array($0.components.dropFirst()),
            lut: $0.lut
          )
        }
        return make(
          folderID: folderID,
          name: childName,
          relativePath: childPath,
          entries: childEntries
        )
      }

    return Self(
      id: "\(folderID):\(relativePath)",
      name: name,
      relativePath: relativePath,
      luts: directLUTs,
      folders: folders
    )
  }
}

/// One LUT plus its remaining path components during tree construction.
private struct LUTFolderTreeEntry {
  var components: [String]
  var lut: LUT
}

/// Lightweight metadata used to decide whether a linked LUT changed.
///
/// Size and modification time avoid reading every LUT during routine scans.
/// The file is parsed again before a detected change is applied.
struct LUTFileFingerprint: Hashable, Codable, Sendable {

  /// The file size reported by its File Provider.
  var byteCount: Int64
  /// The provider-reported content modification date.
  var modificationDate: Date?
}

/// A supported LUT discovered below a linked directory.
struct LUTFolderFile: Hashable, Sendable {

  /// The recursive path below the linked directory.
  var relativePath: String
  /// The LUT encoding inferred from the extension.
  var format: LUT.Format
  /// The metadata used for change detection.
  var fingerprint: LUTFileFingerprint
}

/// A change between a linked directory and the app-owned LUT copies.
struct LUTFolderSyncChange: Identifiable, Hashable, Sendable {

  /// How applying the change mutates the local LUT library.
  enum Kind: String, Hashable, Sendable {
    case added
    case updated
    case removed
  }

  /// The linked directory that owns the path.
  var folderID: String
  /// The recursive path below the linked directory.
  var relativePath: String
  /// The mutation presented to the user.
  var kind: Kind
  /// The scanned file metadata for additions and updates.
  var fingerprint: LUTFileFingerprint?
  /// The stable local LUT id for updates and removals.
  var existingLUTID: String?

  var id: String {
    "\(folderID):\(relativePath)"
  }
}

/// The current changes needed to synchronize one linked directory.
struct LUTFolderSyncPlan: Identifiable, Hashable, Sendable {

  /// The linked-directory identity.
  var folderID: String
  /// The linked directory name used for diagnostics and synchronization.
  var folderName: String
  /// Ordered additions, updates, and removals.
  var changes: [LUTFolderSyncChange]

  var id: String {
    folderID
  }

  var isEmpty: Bool {
    changes.isEmpty
  }

  /// Computes the changes needed to make the linked copies match a scan.
  static func make(
    folder: LUTFolderLink,
    scannedFiles: [LUTFolderFile],
    currentLUTs: [LUT]
  ) -> Self {
    var currentByPath: [String: LUT] = [:]
    for lut in currentLUTs {
      guard lut.linkedFolderOrigin?.folderID == folder.id,
            let relativePath = lut.linkedFolderOrigin?.relativePath
      else {
        continue
      }
      currentByPath[relativePath] = lut
    }

    var changes: [LUTFolderSyncChange] = []
    var scannedPaths: Set<String> = []

    for file in scannedFiles {
      scannedPaths.insert(file.relativePath)
      if let current = currentByPath[file.relativePath],
         let origin = current.linkedFolderOrigin {
        guard origin.fingerprint != file.fingerprint else { continue }
        changes.append(
          LUTFolderSyncChange(
            folderID: folder.id,
            relativePath: file.relativePath,
            kind: .updated,
            fingerprint: file.fingerprint,
            existingLUTID: current.id
          )
        )
      } else {
        changes.append(
          LUTFolderSyncChange(
            folderID: folder.id,
            relativePath: file.relativePath,
            kind: .added,
            fingerprint: file.fingerprint,
            existingLUTID: nil
          )
        )
      }
    }

    for (relativePath, lut) in currentByPath
    where scannedPaths.contains(relativePath) == false {
      changes.append(
        LUTFolderSyncChange(
          folderID: folder.id,
          relativePath: relativePath,
          kind: .removed,
          fingerprint: nil,
          existingLUTID: lut.id
        )
      )
    }

    let kindOrder: [LUTFolderSyncChange.Kind: Int] = [
      .added: 0,
      .updated: 1,
      .removed: 2,
    ]
    changes.sort {
      let lhsOrder = kindOrder[$0.kind, default: 0]
      let rhsOrder = kindOrder[$1.kind, default: 0]
      if lhsOrder != rhsOrder {
        return lhsOrder < rhsOrder
      }
      return $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
    }

    return Self(
      folderID: folder.id,
      folderName: folder.displayName,
      changes: changes
    )
  }
}

/// Observable progress for one linked-folder synchronization.
///
/// Large File Provider folders can spend meaningful time copying and
/// validating LUTs. Keeping the current phase and completed count visible
/// prevents a legitimate first import from looking stalled.
struct LUTFolderSyncProgress: Equatable, Sendable {

  /// The current unit of work for the linked directory.
  enum Phase: Equatable, Sendable {
    case scanning
    case copying
    case validating
    case installing
  }

  /// The operation currently being performed.
  var phase: Phase
  /// The number of files completed in the current phase.
  var completedCount: Int
  /// The number of files expected in the current phase, when known.
  var totalCount: Int?
}

/// The result of enumerating one linked directory.
struct LUTFolderScanResult: Sendable {

  /// Supported files found recursively below the directory.
  var files: [LUTFolderFile]
  /// A renewed bookmark when the previous bookmark was stale.
  var renewedBookmarkData: Data?
  /// The resolved directory URL used to install foreground observation.
  var resolvedDirectoryURL: URL
}

/// File-system operations for linked LUT directories.
///
/// This boundary is nonisolated so potentially remote File Provider I/O can run
/// away from the main actor. Callers own all observable state transitions.
enum LUTFolderScanner {

  enum ScannerError: LocalizedError {
    case accessDenied(String)
    case unableToEnumerate(String)
    case missingSourceFile(String)

    var errorDescription: String? {
      switch self {
      case .accessDenied(let name):
        return "Färg no longer has access to the LUT folder '\(name)'."
      case .unableToEnumerate(let name):
        return "Couldn't read the contents of the LUT folder '\(name)'."
      case .missingSourceFile(let path):
        return "The LUT '\(path)' changed before synchronization. Scan the folder again."
      }
    }
  }

  /// Creates a persistent bookmark while the picker-provided scope is active.
  nonisolated static func makeBookmark(for pickedURL: URL) throws -> Data {
    guard pickedURL.startAccessingSecurityScopedResource() else {
      throw ScannerError.accessDenied(pickedURL.lastPathComponent)
    }
    defer { pickedURL.stopAccessingSecurityScopedResource() }

    return try pickedURL.bookmarkData(
      options: .minimalBookmark,
      includingResourceValuesForKeys: nil,
      relativeTo: nil
    )
  }

  /// Recursively enumerates supported LUTs in a linked directory.
  nonisolated static func scan(_ folder: LUTFolderLink) throws -> LUTFolderScanResult {
    let resolved = try resolve(folder)
    defer { resolved.url.stopAccessingSecurityScopedResource() }

    var coordinationError: NSError?
    var scanResult: Result<[LUTFolderFile], any Error>?

    NSFileCoordinator().coordinate(
      readingItemAt: resolved.url,
      options: [],
      error: &coordinationError
    ) { coordinatedURL in
      scanResult = Result {
        try enumerateFiles(in: coordinatedURL, folderName: folder.displayName)
      }
    }

    if let coordinationError {
      throw coordinationError
    }
    guard let scanResult else {
      throw ScannerError.unableToEnumerate(folder.displayName)
    }

    return LUTFolderScanResult(
      files: try scanResult.get(),
      renewedBookmarkData: resolved.renewedBookmarkData,
      resolvedDirectoryURL: resolved.url
    )
  }

  /// Copies detected additions and updates into a staging directory.
  nonisolated static func copyChangedFiles(
    in plan: LUTFolderSyncPlan,
    folder: LUTFolderLink,
    to stagingDirectory: URL,
    progress: @escaping @Sendable (_ completed: Int, _ total: Int) -> Void
  ) throws -> [String: URL] {
    let fileManager = FileManager.default
    try fileManager.createDirectory(
      at: stagingDirectory,
      withIntermediateDirectories: true
    )

    let resolved = try resolve(folder)
    defer { resolved.url.stopAccessingSecurityScopedResource() }

    let copiedChanges = plan.changes.filter {
      switch $0.kind {
      case .added, .updated:
        return true
      case .removed:
        return false
      }
    }
    progress(0, copiedChanges.count)

    var coordinationError: NSError?
    var copyResult: Result<[String: URL], any Error>?

    // Coordinate the authorized directory once. Coordinating every child file
    // individually is prohibitively slow for large File Provider collections.
    NSFileCoordinator().coordinate(
      readingItemAt: resolved.url,
      options: [],
      error: &coordinationError
    ) { coordinatedDirectoryURL in
      copyResult = Result {
        var copied: [String: URL] = [:]
        for (index, change) in copiedChanges.enumerated() {
          let sourceURL = coordinatedDirectoryURL.appending(
            path: change.relativePath,
            directoryHint: .notDirectory
          )
          let destinationURL = stagingDirectory.appending(
            path: "\(UUID().uuidString).\(sourceURL.pathExtension.lowercased())",
            directoryHint: .notDirectory
          )

          if let plannedFingerprint = change.fingerprint {
            let values = try sourceURL.resourceValues(
              forKeys: [.contentModificationDateKey, .fileSizeKey]
            )
            let currentFingerprint = LUTFileFingerprint(
              byteCount: Int64(values.fileSize ?? 0),
              modificationDate: values.contentModificationDate
            )
            guard
              currentFingerprint.byteCount == plannedFingerprint.byteCount,
              currentFingerprint.modificationDate == plannedFingerprint.modificationDate
            else {
              throw ScannerError.missingSourceFile(change.relativePath)
            }
          }

          try fileManager.copyItem(at: sourceURL, to: destinationURL)
          copied[change.relativePath] = destinationURL
          progress(index + 1, copiedChanges.count)
        }
        return copied
      }
    }

    do {
      if let coordinationError {
        throw coordinationError
      }
      guard let copyResult else {
        throw ScannerError.unableToEnumerate(folder.displayName)
      }
      return try copyResult.get()
    } catch {
      try? fileManager.removeItem(at: stagingDirectory)
      throw error
    }
  }

  private nonisolated static func resolve(
    _ folder: LUTFolderLink
  ) throws -> (url: URL, renewedBookmarkData: Data?) {
    var isStale = false
    let url = try URL(
      resolvingBookmarkData: folder.bookmarkData,
      bookmarkDataIsStale: &isStale
    )
    guard url.startAccessingSecurityScopedResource() else {
      throw ScannerError.accessDenied(folder.displayName)
    }

    do {
      let renewedBookmarkData: Data?
      if isStale {
        renewedBookmarkData = try url.bookmarkData(
          options: .minimalBookmark,
          includingResourceValuesForKeys: nil,
          relativeTo: nil
        )
      } else {
        renewedBookmarkData = nil
      }
      return (url, renewedBookmarkData)
    } catch {
      url.stopAccessingSecurityScopedResource()
      throw error
    }
  }

  private nonisolated static func enumerateFiles(
    in directoryURL: URL,
    folderName: String
  ) throws -> [LUTFolderFile] {
    let keys: [URLResourceKey] = [
      .contentModificationDateKey,
      .fileSizeKey,
      .isRegularFileKey,
    ]
    var enumerationError: (any Error)?
    guard let enumerator = FileManager.default.enumerator(
      at: directoryURL,
      includingPropertiesForKeys: keys,
      options: [.skipsHiddenFiles, .skipsPackageDescendants],
      errorHandler: { _, error in
        enumerationError = error
        return false
      }
    ) else {
      throw ScannerError.unableToEnumerate(folderName)
    }

    var files: [LUTFolderFile] = []
    for case let fileURL as URL in enumerator {
      guard let format = LUT.Format(fileExtension: fileURL.pathExtension) else {
        continue
      }
      let values = try fileURL.resourceValues(forKeys: Set(keys))
      guard values.isRegularFile == true else { continue }

      let relativeComponents = fileURL.pathComponents.dropFirst(
        directoryURL.pathComponents.count
      )
      guard relativeComponents.isEmpty == false else { continue }

      files.append(
        LUTFolderFile(
          relativePath: relativeComponents.joined(separator: "/"),
          format: format,
          fingerprint: LUTFileFingerprint(
            byteCount: Int64(values.fileSize ?? 0),
            modificationDate: values.contentModificationDate
          )
        )
      )
    }

    if let enumerationError {
      throw enumerationError
    }
    files.sort {
      $0.relativePath.localizedStandardCompare($1.relativePath) == .orderedAscending
    }
    return files
  }
}
