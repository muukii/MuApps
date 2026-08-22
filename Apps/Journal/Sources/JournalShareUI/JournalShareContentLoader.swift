import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// Result of importing all item providers supplied by the host app.
struct JournalShareLoadResult: Sendable {
  var payloads: [JournalSharePayload]
  var warnings: [JournalShareLoadWarning]
}

/// A visible warning for one provider that could not be imported.
///
/// A host app may vend auxiliary providers beside its primary payload. Journal
/// keeps successfully imported content, but surfaces every omission so posting
/// a partial result is always an explicit user decision.
struct JournalShareLoadWarning: Identifiable, Sendable {
  let id = UUID()
  let message: String
}

/// Converts `NSItemProvider` values into persistence-ready share payloads.
///
/// Providers are loaded in their original order so `createPost(cards:)`
/// preserves the order in which the host app presented the shared items.
@MainActor
struct JournalShareContentLoader {

  func load(from inputItems: [NSExtensionItem]) async throws -> JournalShareLoadResult {
    guard inputItems.isEmpty == false else {
      throw JournalShareImportError.noInputItems
    }

    var payloads: [JournalSharePayload] = []
    var warnings: [JournalShareLoadWarning] = []

    do {
      for inputItem in inputItems {
        for provider in inputItem.attachments ?? [] {
          try Task.checkCancellation()
          do {
            let payload = try await load(from: provider)
            if Task.isCancelled {
              payload.cleanUpTemporaryFiles()
              throw CancellationError()
            }
            payloads.append(payload)
          } catch is CancellationError {
            throw CancellationError()
          } catch {
            warnings.append(
              JournalShareLoadWarning(message: warningMessage(for: provider, error: error))
            )
          }
        }
      }
    } catch {
      payloads.forEach { $0.cleanUpTemporaryFiles() }
      throw error
    }

    guard payloads.isEmpty == false else {
      throw JournalShareImportError.noSupportedContent
    }
    return JournalShareLoadResult(payloads: payloads, warnings: warnings)
  }

  private func load(from provider: NSItemProvider) async throws -> JournalSharePayload {
    if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) {
      return try await loadImage(from: provider)
    }

    if provider.hasItemConformingToTypeIdentifier(UTType.movie.identifier) {
      return try await loadMovie(from: provider)
    }

    if provider.hasItemConformingToTypeIdentifier(UTType.url.identifier) {
      return try await loadURL(from: provider)
    }

    if provider.hasItemConformingToTypeIdentifier(UTType.text.identifier) {
      return try await loadText(from: provider)
    }

    if provider.registeredTypeIdentifiers.isEmpty == false {
      return try await loadGenericFile(from: provider)
    }

    throw JournalShareImportError.unsupportedItem
  }

  private func loadImage(from provider: NSItemProvider) async throws -> JournalSharePayload {
    let transferred = try await provider.journalLoadTransferable(ShareTransferredImage.self)
    let contentType = preferredContentType(in: provider, conformingTo: .image) ?? .image
    return JournalSharePayload(
      content: .photo(
        file: transferred.file,
        contentTypeIdentifier: contentType.identifier
      )
    )
  }

  private func loadMovie(from provider: NSItemProvider) async throws -> JournalSharePayload {
    let transferred = try await provider.journalLoadTransferable(ShareTransferredMovie.self)
    let contentType = preferredContentType(in: provider, conformingTo: .movie)
      ?? UTType(filenameExtension: transferred.file.fileURL.pathExtension)
      ?? .movie
    return JournalSharePayload(
      content: .video(
        file: transferred.file,
        contentTypeIdentifier: contentType.identifier
      )
    )
  }

  private func loadURL(from provider: NSItemProvider) async throws -> JournalSharePayload {
    let url = try await provider.journalLoadTransferable(URL.self)
    guard url.isFileURL else {
      return JournalSharePayload(content: .link(url))
    }

    let didAccessSecurityScope = url.startAccessingSecurityScopedResource()
    defer {
      if didAccessSecurityScope {
        url.stopAccessingSecurityScopedResource()
      }
    }

    let contentType = UTType(filenameExtension: url.pathExtension)
    let temporaryFile = try JournalShareTemporaryFile.copy(
      from: url,
      suggestedName: provider.suggestedName,
      contentType: contentType
    )
    return JournalSharePayload(
      content: .file(
        file: temporaryFile,
        displayName: displayName(
          suggestedName: provider.suggestedName,
          fallbackURL: temporaryFile.fileURL,
          contentType: contentType
        ),
        contentTypeIdentifier: contentType?.identifier
      )
    )
  }

  private func loadText(from provider: NSItemProvider) async throws -> JournalSharePayload {
    let rawText = try await provider.journalLoadTransferable(String.self)
    let text = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
    guard text.isEmpty == false else {
      throw JournalShareImportError.emptyText
    }
    return JournalSharePayload(content: .text(text))
  }

  private func loadGenericFile(from provider: NSItemProvider) async throws -> JournalSharePayload {
    let transferred = try await provider.journalLoadTransferable(ShareTransferredFile.self)
    let contentType = preferredGenericContentType(in: provider)
      ?? UTType(filenameExtension: transferred.file.fileURL.pathExtension)
    return JournalSharePayload(
      content: .file(
        file: transferred.file,
        displayName: displayName(
          suggestedName: provider.suggestedName,
          fallbackURL: transferred.file.fileURL,
          contentType: contentType
        ),
        contentTypeIdentifier: contentType?.identifier
      )
    )
  }

  private func preferredContentType(
    in provider: NSItemProvider,
    conformingTo parentType: UTType
  ) -> UTType? {
    let registeredTypes = provider.registeredTypeIdentifiers.compactMap { identifier in
      UTType(identifier)
    }
    return registeredTypes.first { type in
      type != parentType && type.conforms(to: parentType)
    }
  }

  private func preferredGenericContentType(in provider: NSItemProvider) -> UTType? {
    let registeredTypes = provider.registeredTypeIdentifiers.compactMap { identifier in
      UTType(identifier)
    }
    let specificType = registeredTypes.first { type in
      type != .item && type != .content && type != .data && type != .fileURL
    }
    return specificType ?? registeredTypes.first
  }

  private func displayName(
    suggestedName: String?,
    fallbackURL: URL,
    contentType: UTType?
  ) -> String {
    var name = suggestedName?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if name?.isEmpty != false {
      name = fallbackURL.lastPathComponent
    }
    if name?.isEmpty != false {
      name = String(localized: "Shared File")
    }

    if let name,
      URL(fileURLWithPath: name).pathExtension.isEmpty,
      let pathExtension = contentType?.preferredFilenameExtension
    {
      return "\(name).\(pathExtension)"
    }
    return name ?? String(localized: "Shared File")
  }

  private func warningMessage(for provider: NSItemProvider, error: any Error) -> String {
    if let importError = error as? JournalShareImportError,
      let description = importError.errorDescription
    {
      return description
    }

    let itemName = provider.suggestedName?
      .trimmingCharacters(in: .whitespacesAndNewlines)
    if let itemName, itemName.isEmpty == false {
      return String(localized: "“\(itemName)” couldn't be loaded.")
    }
    return String(localized: "One shared item couldn't be loaded.")
  }
}

// MARK: - CoreTransferable representations

/// Image file copied during the provider's transient file-access callback.
private struct ShareTransferredImage: Sendable {
  let file: JournalShareTemporaryFile
}

nonisolated extension ShareTransferredImage: Transferable {
  static var transferRepresentation: some TransferRepresentation {
    FileRepresentation(importedContentType: .image) { received in
      let contentType = UTType(filenameExtension: received.file.pathExtension)
      return ShareTransferredImage(
        file: try JournalShareTemporaryFile.copy(
          from: received.file,
          contentType: contentType
        )
      )
    }
  }
}

/// Movie file copied during the provider's transient file-access callback.
private struct ShareTransferredMovie: Sendable {
  let file: JournalShareTemporaryFile
}

nonisolated extension ShareTransferredMovie: Transferable {
  static var transferRepresentation: some TransferRepresentation {
    FileRepresentation(importedContentType: .movie) { received in
      let contentType = UTType(filenameExtension: received.file.pathExtension)
      return ShareTransferredMovie(
        file: try JournalShareTemporaryFile.copy(
          from: received.file,
          contentType: contentType
        )
      )
    }
  }
}

/// Generic file copied during the provider's transient file-access callback.
private struct ShareTransferredFile: Sendable {
  let file: JournalShareTemporaryFile
}

nonisolated extension ShareTransferredFile: Transferable {
  static var transferRepresentation: some TransferRepresentation {
    FileRepresentation(importedContentType: .item) { received in
      let contentType = UTType(filenameExtension: received.file.pathExtension)
      return ShareTransferredFile(
        file: try JournalShareTemporaryFile.copy(
          from: received.file,
          contentType: contentType
        )
      )
    }
  }
}

// MARK: - Async NSItemProvider bridge

@MainActor
private extension NSItemProvider {
  /// Async bridge for CoreTransferable's `NSItemProvider` API.
  func journalLoadTransferable<Value: Transferable>(_ type: Value.Type) async throws -> Value {
    try await withCheckedThrowingContinuation { continuation in
      _ = loadTransferable(type: type) { result in
        continuation.resume(with: result)
      }
    }
  }
}
