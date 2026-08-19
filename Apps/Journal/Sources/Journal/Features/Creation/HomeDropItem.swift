import AppUIComponents
import CoreTransferable
import Foundation
import JournalVault
import MediaProcessing
import UniformTypeIdentifiers

/// One external value materialized by the Home composer drop destination.
///
/// The value deliberately skips `CardEditDraft`: a drop is an explicit import
/// action and must not replace or clear the unpublished card currently owned by
/// the composer. File-backed cases own an app-temporary copy until one root-card
/// transaction either commits or fails.
struct HomeDropItem: Sendable {

  /// Supported persisted meanings for one transferred value.
  enum Content: Sendable {
    case text(String)
    case link(String)
    case photo(file: HomeDropFile, thumbnail: Data?)
    case video(file: HomeDropFile, thumbnail: Data?)
    case audio(file: HomeDropFile)
    case file(HomeDropFile)
    case failure(FailureReason)
  }

  /// Failures captured as values so one unreadable provider does not prevent
  /// successfully transferred siblings from reaching the posting coordinator.
  enum FailureReason: Error, Sendable {
    case directoriesAreUnsupported
    case emptyText
    case fileUnavailable
  }

  let content: Content

  /// Converts the transfer value into the existing vault write contract.
  func cardDraft() throws -> VaultContentStore.CardDraft {
    switch content {
    case .text(let text):
      return .init(kind: .text, text: text)

    case .link(let storageString):
      return .init(kind: .link, text: storageString)

    case .photo(let file, let thumbnail):
      return .init(
        kind: .photo,
        mediaResources: [
          .init(
            role: .originalImage,
            fileURL: file.temporaryFile.fileURL,
            fileTransferMode: .move,
            byteSize: file.temporaryFile.byteSize,
            contentType: file.contentTypeIdentifier
          )
        ],
        thumbnail: thumbnail
      )

    case .video(let file, let thumbnail):
      return .init(
        kind: .video,
        mediaResources: [
          .init(
            role: .originalVideo,
            fileURL: file.temporaryFile.fileURL,
            fileTransferMode: .move,
            byteSize: file.temporaryFile.byteSize,
            contentType: file.contentTypeIdentifier
          )
        ],
        thumbnail: thumbnail
      )

    case .audio(let file):
      return .init(
        kind: .audio,
        mediaResources: [
          .init(
            role: .audio,
            fileURL: file.temporaryFile.fileURL,
            fileTransferMode: .move,
            byteSize: file.temporaryFile.byteSize,
            contentType: file.contentTypeIdentifier
          )
        ]
      )

    case .file(let file):
      return .init(
        kind: .file,
        text: file.displayName,
        mediaResources: [
          .init(
            role: .file,
            fileURL: file.temporaryFile.fileURL,
            fileTransferMode: .move,
            byteSize: file.temporaryFile.byteSize,
            contentType: file.contentTypeIdentifier
          )
        ]
      )

    case .failure(let reason):
      throw reason
    }
  }

  /// Releases any app-owned transfer copy after persistence has consumed it or
  /// after a failed transaction no longer needs retry material.
  nonisolated func cleanUpTemporaryFiles() {
    switch content {
    case .photo(let file, _), .video(let file, _), .audio(let file), .file(let file):
      file.temporaryFile.cleanUp()
    case .text, .link, .failure:
      break
    }
  }

  /// Removes app-temporary imports abandoned by a process termination.
  nonisolated static func cleanUpStaleTemporaryFiles() {
    HomeDropTemporaryFile.cleanUpStaleImports()
  }

  /// Builds the semantic value for dropped text without involving composer
  /// mutation. A complete detected HTTP(S) value becomes Link; prose remains Text.
  nonisolated static func importedText(_ rawText: String) -> HomeDropItem {
    guard rawText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false else {
      return HomeDropItem(content: .failure(.emptyText))
    }

    if let linkURL = JournalLinkURL(entireWebURL: rawText) {
      return HomeDropItem(content: .link(linkURL.storageString))
    }
    return HomeDropItem(content: .text(rawText))
  }

  /// Builds a Link for a web URL or imports the target of a dropped file URL.
  nonisolated static func importedURL(_ url: URL) -> HomeDropItem {
    guard url.isFileURL else {
      return importedText(url.absoluteString)
    }
    return importedFile(from: url)
  }

  /// Copies and classifies one provider-owned file while its transient URL is valid.
  nonisolated private static func importedFile(
    from sourceURL: URL,
    fallbackContentType: UTType? = nil,
    requiredKind: ImportedFileKind? = nil
  ) -> HomeDropItem {
    let didAccessSecurityScope = sourceURL.startAccessingSecurityScopedResource()
    defer {
      if didAccessSecurityScope {
        sourceURL.stopAccessingSecurityScopedResource()
      }
    }

    do {
      let contentType =
        UTType(filenameExtension: sourceURL.pathExtension)
        ?? fallbackContentType
      let temporaryFile = try HomeDropTemporaryFile.copy(
        from: sourceURL,
        contentType: contentType
      )
      let file = HomeDropFile(
        temporaryFile: temporaryFile,
        displayName: temporaryFile.fileURL.lastPathComponent,
        contentTypeIdentifier: contentType?.identifier
      )

      switch requiredKind ?? ImportedFileKind(contentType: contentType) {
      case .photo:
        let thumbnail = try? Data(contentsOf: temporaryFile.fileURL)
          .journalImageThumbnailData()
        return HomeDropItem(content: .photo(file: file, thumbnail: thumbnail))
      case .video:
        let thumbnail = try? MediaThumbnailGenerator.videoThumbnail(
          from: temporaryFile.fileURL
        ).data
        return HomeDropItem(content: .video(file: file, thumbnail: thumbnail))
      case .audio:
        return HomeDropItem(content: .audio(file: file))
      case .file:
        return HomeDropItem(content: .file(file))
      }
    } catch let reason as FailureReason {
      return HomeDropItem(content: .failure(reason))
    } catch {
      return HomeDropItem(content: .failure(.fileUnavailable))
    }
  }

  /// Semantic file category chosen before construction of the vault draft.
  private enum ImportedFileKind {
    case photo
    case video
    case audio
    case file

    nonisolated init(contentType: UTType?) {
      guard let contentType else {
        self = .file
        return
      }
      if contentType.conforms(to: .image) {
        self = .photo
      } else if contentType.conforms(to: .movie) {
        self = .video
      } else if contentType.conforms(to: .audio) {
        self = .audio
      } else {
        self = .file
      }
    }
  }
}

nonisolated extension HomeDropItem: Transferable {

  static var transferRepresentation: some TransferRepresentation {
    // Keep specific file representations ahead of URL, text, and generic item
    // fallbacks so media from Photos or Files retains its modality.
    FileRepresentation(importedContentType: .image) { received in
      importedFile(
        from: received.file,
        fallbackContentType: .image,
        requiredKind: .photo
      )
    }
    FileRepresentation(importedContentType: .movie) { received in
      importedFile(
        from: received.file,
        fallbackContentType: .movie,
        requiredKind: .video
      )
    }
    FileRepresentation(importedContentType: .audio) { received in
      importedFile(
        from: received.file,
        fallbackContentType: .audio,
        requiredKind: .audio
      )
    }
    ProxyRepresentation(importing: { (url: URL) in
      importedURL(url)
    })
    ProxyRepresentation(importing: { (text: String) in
      importedText(text)
    })
    FileRepresentation(importedContentType: .item) { received in
      importedFile(from: received.file, fallbackContentType: .item)
    }
  }
}

/// File metadata needed to construct one media or generic-file card draft.
struct HomeDropFile: Sendable {

  /// App-owned copy whose lifetime spans transfer completion and local posting.
  let temporaryFile: HomeDropTemporaryFile

  /// User-facing name persisted as the body of a generic File card.
  let displayName: String

  /// Concrete UTI inferred from the provider file name when available.
  let contentTypeIdentifier: String?
}

/// Immutable owner of one provider file copied under a unique temporary folder.
///
/// CoreTransferable guarantees a received file only inside its import closure.
/// This owner makes the extended lifetime explicit. Explicit cleanup runs after
/// every posting attempt, while `deinit` protects cancelled drop sessions that
/// never reach the action closure.
final class HomeDropTemporaryFile: @unchecked Sendable {

  let fileURL: URL
  let owningDirectoryURL: URL
  let byteSize: Int

  nonisolated private init(fileURL: URL, owningDirectoryURL: URL, byteSize: Int) {
    self.fileURL = fileURL
    self.owningDirectoryURL = owningDirectoryURL
    self.byteSize = byteSize
  }

  deinit {
    cleanUp()
  }

  /// Copies a transient provider URL into one app-owned temporary directory.
  nonisolated static func copy(
    from sourceURL: URL,
    contentType: UTType? = nil
  ) throws -> HomeDropTemporaryFile {
    let fileManager = FileManager.default
    let values = try sourceURL.resourceValues(forKeys: [.isDirectoryKey])
    guard values.isDirectory != true else {
      throw HomeDropItem.FailureReason.directoriesAreUnsupported
    }

    let owningDirectoryURL = fileManager.temporaryDirectory
      .appending(path: "journal-home-drop-\(UUID().uuidString)", directoryHint: .isDirectory)
    try fileManager.createDirectory(
      at: owningDirectoryURL,
      withIntermediateDirectories: true
    )

    do {
      let destinationURL = owningDirectoryURL.appending(
        path: normalizedFileName(
          sourceURL.lastPathComponent,
          contentType: contentType
        ),
        directoryHint: .notDirectory
      )
      try fileManager.copyItem(at: sourceURL, to: destinationURL)
      let byteSize = try destinationURL.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
      return HomeDropTemporaryFile(
        fileURL: destinationURL,
        owningDirectoryURL: owningDirectoryURL,
        byteSize: byteSize
      )
    } catch {
      try? fileManager.removeItem(at: owningDirectoryURL)
      throw error
    }
  }

  /// Removes this import's unique directory. Repeated calls are harmless.
  nonisolated func cleanUp() {
    try? FileManager.default.removeItem(at: owningDirectoryURL)
  }

  /// Clears crash-abandoned imports without racing current drop sessions.
  nonisolated static func cleanUpStaleImports(olderThan age: TimeInterval = 24 * 60 * 60) {
    let fileManager = FileManager.default
    let cutoff = Date().addingTimeInterval(-age)
    guard
      let children = try? fileManager.contentsOfDirectory(
        at: fileManager.temporaryDirectory,
        includingPropertiesForKeys: [.contentModificationDateKey],
        options: [.skipsHiddenFiles]
      )
    else {
      return
    }

    for child in children where child.lastPathComponent.hasPrefix("journal-home-drop-") {
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
      fileName = "Dropped File"
    }
    if URL(fileURLWithPath: fileName).pathExtension.isEmpty,
      let pathExtension = contentType?.preferredFilenameExtension
    {
      fileName += ".\(pathExtension)"
    }
    return fileName
  }
}

/// Result of independently attempting every value from one Home drop action.
struct HomeDropPostingResult: Equatable {

  /// Root edge identities returned by successful one-card transactions.
  let postedEdgeIDs: [UUID]

  /// Original item positions that failed transfer conversion or persistence.
  let failedItemIndices: [Int]

  var postedCount: Int { postedEdgeIDs.count }
  var failedCount: Int { failedItemIndices.count }
}

/// Posts dropped items without owning or mutating the visible composer draft.
@MainActor
enum HomeDropPostingCoordinator {

  /// Attempts each item independently and releases its temporary files after the
  /// corresponding local transaction succeeds or fails.
  static func post(
    items: [HomeDropItem],
    postCard: @MainActor @Sendable (VaultContentStore.CardDraft) throws -> UUID,
    onFailure: @MainActor @Sendable (Int, String) -> Void = { _, _ in }
  ) -> HomeDropPostingResult {
    var postedEdgeIDs: [UUID] = []
    var failedItemIndices: [Int] = []

    for (index, item) in items.enumerated() {
      do {
        defer { item.cleanUpTemporaryFiles() }
        let draft = try item.cardDraft()
        postedEdgeIDs.append(try postCard(draft))
      } catch {
        failedItemIndices.append(index)
        onFailure(index, String(reflecting: error))
      }
    }

    return HomeDropPostingResult(
      postedEdgeIDs: postedEdgeIDs,
      failedItemIndices: failedItemIndices
    )
  }
}

extension Data {

  /// Generates the standard Journal thumbnail while keeping transfer setup terse.
  fileprivate nonisolated func journalImageThumbnailData() throws -> Data {
    try MediaThumbnailGenerator.imageThumbnail(from: self).data
  }
}
