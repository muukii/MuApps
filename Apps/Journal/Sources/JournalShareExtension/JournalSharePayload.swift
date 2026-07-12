import Foundation
import JournalVault
import UniformTypeIdentifiers

/// One value imported from another app and ready to become a Journal card.
///
/// File-backed cases own an extension-container temporary copy. The copy stays
/// alive while the share sheet is open so a failed post can be retried, then is
/// removed when the user cancels or after the vault transaction commits.
struct JournalSharePayload: Identifiable, Sendable {

  /// Supported share-sheet modalities, kept independent from SwiftUI so the
  /// loader and persistence bridge can be exercised without rendering the UI.
  enum Content: Sendable {
    case text(String)
    case link(URL)
    case photo(file: JournalShareTemporaryFile, contentTypeIdentifier: String, thumbnail: Data?)
    case video(file: JournalShareTemporaryFile, contentTypeIdentifier: String, thumbnail: Data?)
    case file(file: JournalShareTemporaryFile, displayName: String, contentTypeIdentifier: String?)
  }

  let id = UUID()
  let content: Content

  /// A short title suitable for the compact review list in the share sheet.
  var title: String {
    switch content {
    case .text(let text):
      return text
    case .link(let url):
      return url.host(percentEncoded: false) ?? url.absoluteString
    case .photo:
      return String(localized: "Photo")
    case .video(let file, _, _):
      return file.fileURL.lastPathComponent
    case .file(_, let displayName, _):
      return displayName
    }
  }

  /// SF Symbol representing the modality in the share-sheet review list.
  var symbolName: String {
    switch content {
    case .text:
      return "text.alignleft"
    case .link:
      return "link"
    case .photo:
      return "photo"
    case .video:
      return "video"
    case .file:
      return "doc"
    }
  }

  /// Converts the imported value at the persistence boundary.
  ///
  /// Explicit resource drafts preserve the provider's content type rather than
  /// allowing the vault's default JPEG/MPEG-4 assumptions to rewrite it.
  func cardDraft() -> VaultContentStore.CardDraft {
    switch content {
    case .text(let text):
      return .init(kind: .text, text: text)

    case .link(let url):
      return .init(kind: .link, text: url.absoluteString)

    case .photo(let file, let contentTypeIdentifier, let thumbnail):
      return .init(
        kind: .photo,
        mediaResources: [
          .init(
            role: .originalImage,
            fileURL: file.fileURL,
            fileTransferMode: .move,
            byteSize: file.byteSize,
            contentType: contentTypeIdentifier
          )
        ],
        thumbnail: thumbnail
      )

    case .video(let file, let contentTypeIdentifier, let thumbnail):
      return .init(
        kind: .video,
        mediaResources: [
          .init(
            role: .originalVideo,
            fileURL: file.fileURL,
            fileTransferMode: .move,
            byteSize: file.byteSize,
            contentType: contentTypeIdentifier
          )
        ],
        thumbnail: thumbnail
      )

    case .file(let file, let displayName, let contentTypeIdentifier):
      return .init(
        kind: .file,
        text: displayName,
        mediaResources: [
          .init(
            role: .file,
            fileURL: file.fileURL,
            fileTransferMode: .move,
            byteSize: file.byteSize,
            contentType: contentTypeIdentifier
          )
        ]
      )
    }
  }

  /// Removes file-backed temporary copies owned by this payload.
  nonisolated func cleanUpTemporaryFiles() {
    switch content {
    case .photo(let file, _, _), .video(let file, _, _), .file(let file, _, _):
      file.cleanUp()
    case .text, .link:
      break
    }
  }
}

// MARK: - Temporary file ownership

/// A private copy of a provider-owned file inside the share extension's
/// temporary container.
///
/// `NSItemProvider` file URLs are valid only during its loading callback. This
/// type makes that lifetime boundary explicit and gives every imported file a
/// unique directory that can be removed atomically.
struct JournalShareTemporaryFile: Sendable {
  let fileURL: URL
  let owningDirectoryURL: URL
  let byteSize: Int

  /// Copies a transient provider URL into a unique, extension-owned directory.
  nonisolated static func copy(
    from sourceURL: URL,
    suggestedName: String? = nil,
    contentType: UTType? = nil
  ) throws -> JournalShareTemporaryFile {
    let fileManager = FileManager.default
    let resourceValues = try sourceURL.resourceValues(forKeys: [.isDirectoryKey])
    guard resourceValues.isDirectory != true else {
      throw JournalShareImportError.directoriesAreUnsupported
    }

    let owningDirectoryURL = fileManager.temporaryDirectory
      .appending(path: "journal-share-import-\(UUID().uuidString)", directoryHint: .isDirectory)
    try fileManager.createDirectory(
      at: owningDirectoryURL,
      withIntermediateDirectories: true
    )

    do {
      let fileName = normalizedFileName(
        suggestedName ?? sourceURL.lastPathComponent,
        contentType: contentType
      )
      let destinationURL = owningDirectoryURL
        .appending(path: fileName, directoryHint: .notDirectory)
      try fileManager.copyItem(at: sourceURL, to: destinationURL)
      let byteSize = try destinationURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
      return JournalShareTemporaryFile(
        fileURL: destinationURL,
        owningDirectoryURL: owningDirectoryURL,
        byteSize: byteSize
      )
    } catch {
      try? fileManager.removeItem(at: owningDirectoryURL)
      throw error
    }
  }

  /// Removes this import's whole unique directory. Safe to call repeatedly,
  /// including after `VaultContentStore` has moved the contained file.
  nonisolated func cleanUp() {
    try? FileManager.default.removeItem(at: owningDirectoryURL)
  }

  /// Removes abandoned imports from an earlier extension process while leaving
  /// current share sessions alone.
  nonisolated static func cleanUpStaleImports(olderThan age: TimeInterval = 24 * 60 * 60) {
    let fileManager = FileManager.default
    let temporaryDirectory = fileManager.temporaryDirectory
    let cutoff = Date().addingTimeInterval(-age)
    guard let children = try? fileManager.contentsOfDirectory(
      at: temporaryDirectory,
      includingPropertiesForKeys: [.contentModificationDateKey],
      options: [.skipsHiddenFiles]
    ) else {
      return
    }

    for child in children where child.lastPathComponent.hasPrefix("journal-share-import-") {
      let modifiedAt = try? child.resourceValues(forKeys: [.contentModificationDateKey])
        .contentModificationDate
      if let modifiedAt, modifiedAt < cutoff {
        try? fileManager.removeItem(at: child)
      }
    }
  }

  nonisolated private static func normalizedFileName(
    _ rawName: String,
    contentType: UTType?
  ) -> String {
    var fileName = URL(fileURLWithPath: rawName).lastPathComponent
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if fileName.isEmpty {
      fileName = String(localized: "Shared File")
    }

    if URL(fileURLWithPath: fileName).pathExtension.isEmpty,
      let pathExtension = contentType?.preferredFilenameExtension
    {
      fileName += ".\(pathExtension)"
    }
    return fileName
  }
}

// MARK: - Import errors

/// User-relevant failures that can occur while materializing shared content.
enum JournalShareImportError: LocalizedError {
  case directoriesAreUnsupported
  case emptyText
  case noInputItems
  case noSupportedContent
  case unsupportedItem

  var errorDescription: String? {
    switch self {
    case .directoriesAreUnsupported:
      return String(localized: "Folders can't be posted yet. Share an individual file instead.")
    case .emptyText:
      return String(localized: "The shared text is empty.")
    case .noInputItems:
      return String(localized: "The other app didn't provide anything to share.")
    case .noSupportedContent:
      return String(localized: "No supported text, link, photo, video, or file was found.")
    case .unsupportedItem:
      return String(localized: "This shared item isn't supported.")
    }
  }
}
