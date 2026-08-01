import AVFoundation
import AppUIComponents
import CaptureAudio
import CaptureBauhaus
import CaptureDoodle
import CapturePhoto
import Foundation
import JournalVault
import SwiftUI

#if canImport(UIKit)
  import UIKit
#elseif canImport(AppKit)
  import AppKit
#endif

// MARK: - Live Entry Projection

/// Live saved-entry handle used by the list and detail UI.
///
/// The handle carries SwiftData model references. Display, share, and edit
/// values are derived at the edge of each operation, so CloudKit imports update
/// the UI through SwiftData observation instead of a hand-built reload snapshot.
struct VaultSavedEntry: Identifiable {

  let edge: JournalVault.CardEdge
  let card: JournalVault.Card
  let store: VaultContentStore

  var id: UUID { edgeID }

  var edgeID: UUID { edge.id }
  var cardID: UUID { card.id }
  var parentEdgeID: UUID? { edge.parentEdgeID }
  var sortIndex: Int { edge.sortIndex }
  var kind: JournalVault.Card.Kind { card.kind }
  var body: String { card.body }
  var createdAt: Date { card.createdAt }
  var updatedAt: Date { card.updatedAt }
  var location: JournalVault.Coordinate? { card.location }

  private var attachment: VaultSavedAttachment? {
    card.attachments
      .sorted { lhs, rhs in
        if lhs.createdAt != rhs.createdAt {
          return lhs.createdAt < rhs.createdAt
        }
        return lhs.id.uuidString < rhs.id.uuidString
      }
      .lazy
      .compactMap { VaultSavedAttachment(attachment: $0, store: store) }
      .first
  }
}

extension VaultSavedEntry {

  /// Rehydrates this saved card into the shared editing draft model.
  ///
  /// Media cards require the full vault media file. Raster previews are
  /// intentionally not used to create a lossy edit draft.
  @MainActor
  func editDraft() async throws -> CardEditDraft {
    switch kind {
    case .text:
      return CardEditDraft(kind: .text, text: body, location: location)
    case .link:
      return CardEditDraft(kind: .link, text: body, location: location)
    case .file:
      // Generic file cards preserve arbitrary bytes and metadata, but the
      // composer does not yet expose a lossless file-replacement editor.
      throw VaultSavedEntryEditDraftError.unsupportedKind
    case .photo:
      let data = try await mediaData(matching: .photo)
      guard let image = UIImage(data: data) else {
        throw VaultSavedEntryEditDraftError.mediaDecodeFailed
      }
      return CardEditDraft(
        kind: .photo,
        photo: CapturedPhoto(imageData: data, pixelSize: image.pixelSize),
        location: location
      )
    case .video:
      let fileURL = try mediaFileURL(matching: .video)
      let editableURL = try VaultSavedEntryEditMediaPreparer.mediaCopy(
        from: fileURL,
        fallbackPathExtension: "mov"
      )
      let resource = attachment?.primaryResource
      return CardEditDraft(
        kind: .video,
        video: CapturedVideo(
          fileURL: editableURL,
          thumbnailData: attachment?.thumbnail,
          pixelSize: resource?.pixelSize ?? .zero,
          duration: resource?.duration ?? 0,
          contentTypeIdentifier: resource?.contentType,
          byteSize: resource?.byteSize
        ),
        location: location
      )
    case .livePhoto:
      let stillData = try await mediaData(matching: .stillImage)
      let pairedVideoFileURL = try mediaFileURL(matching: .pairedVideo)
      let editablePairedVideoURL =
        try VaultSavedEntryEditMediaPreparer.mediaCopy(
          from: pairedVideoFileURL,
          fallbackPathExtension: "mov"
        )
      let stillResource = try mediaResource(matching: .stillImage)
      let pairedVideoResource = try mediaResource(matching: .pairedVideo)
      return CardEditDraft(
        kind: .livePhoto,
        livePhoto: CapturedLivePhoto(
          stillImageData: stillData,
          pairedVideoFileURL: editablePairedVideoURL,
          thumbnailData: attachment?.thumbnail,
          pixelSize: stillResource.pixelSize ?? .zero,
          duration: pairedVideoResource.duration ?? 0,
          stillImageContentTypeIdentifier: stillResource.contentType,
          pairedVideoContentTypeIdentifier: pairedVideoResource.contentType,
          stillImageByteSize: stillResource.byteSize,
          pairedVideoByteSize: pairedVideoResource.byteSize
        ),
        location: location
      )
    case .audio:
      let fileURL = try mediaFileURL(
        matching: JournalVault.Attachment.Kind.audio
      )
      let editableURL = try VaultSavedEntryEditMediaPreparer.audioCopy(
        from: fileURL
      )
      return CardEditDraft(
        kind: .audio,
        audio: AudioRecording(
          fileURL: editableURL,
          duration: VaultSavedEntryEditMediaPreparer.audioDuration(
            from: editableURL
          )
        ),
        location: location
      )
    case .suggestion:
      let data = try await mediaData(matching: .suggestion)
      guard let suggestion = SuggestionCardPayload.decode(from: data) else {
        throw VaultSavedEntryEditDraftError.mediaDecodeFailed
      }
      return CardEditDraft(
        kind: .suggestion,
        suggestion: suggestion,
        suggestionMediaFileURLsByResourceID:
          suggestionMediaFileURLsByResourceID(for: suggestion),
        location: location
      )
    case .doodle:
      let data = try await mediaData(matching: .doodle)
      guard
        let drawing = try? JSONDecoder().decode(DoodleDrawing.self, from: data)
      else {
        throw VaultSavedEntryEditDraftError.mediaDecodeFailed
      }
      return CardEditDraft(kind: .doodle, doodle: drawing, location: location)
    case .bauhaus:
      let data = try await mediaData(matching: .bauhaus)
      guard
        let document = try? JSONDecoder().decode(
          BauhausGridDocument.self,
          from: data
        )
      else {
        throw VaultSavedEntryEditDraftError.mediaDecodeFailed
      }
      return CardEditDraft(
        kind: .bauhaus,
        bauhaus: document,
        location: location
      )
    case .unknown:
      throw VaultSavedEntryEditDraftError.unsupportedKind
    @unknown default:
      throw VaultSavedEntryEditDraftError.unsupportedKind
    }
  }

  private func mediaFileURL(matching kind: JournalVault.Attachment.Kind) throws
    -> URL
  {
    guard attachment?.kind == kind,
      let fileURL = attachment?.fileURL,
      FileManager.default.fileExists(atPath: fileURL.path)
    else {
      throw VaultSavedEntryEditDraftError.mediaUnavailable
    }
    return fileURL
  }

  private func mediaFileURL(matching role: JournalVault.AttachmentResource.Role)
    throws -> URL
  {
    let resource = try mediaResource(matching: role)
    guard FileManager.default.fileExists(atPath: resource.fileURL.path) else {
      throw VaultSavedEntryEditDraftError.mediaUnavailable
    }
    return resource.fileURL
  }

  private func mediaResource(
    matching role: JournalVault.AttachmentResource.Role
  ) throws
    -> VaultSavedAttachmentResource
  {
    guard let resource = attachment?.resources.first(where: { $0.role == role })
    else {
      throw VaultSavedEntryEditDraftError.mediaUnavailable
    }
    return resource
  }

  private func mediaData(matching kind: JournalVault.Attachment.Kind)
    async throws -> Data
  {
    let fileURL = try mediaFileURL(matching: kind)
    guard let data = await VaultSavedEntryMediaFileReader.data(from: fileURL)
    else {
      throw VaultSavedEntryEditDraftError.mediaUnavailable
    }
    return data
  }

  private func mediaData(matching role: JournalVault.AttachmentResource.Role)
    async throws -> Data
  {
    let fileURL = try mediaFileURL(matching: role)
    guard let data = await VaultSavedEntryMediaFileReader.data(from: fileURL)
    else {
      throw VaultSavedEntryEditDraftError.mediaUnavailable
    }
    return data
  }

  private func suggestionMediaFileURLsByResourceID(
    for suggestion: SuggestionCardPayload
  ) -> [UUID: URL] {
    guard let attachment else { return [:] }

    let resourcesByID = Dictionary(
      uniqueKeysWithValues: attachment.resources.map { ($0.id, $0.fileURL) }
    )
    return suggestion.mediaResources.reduce(into: [UUID: URL]()) {
      result,
      media in
      guard let resourceID = media.resourceID,
        let fileURL = resourcesByID[resourceID],
        FileManager.default.fileExists(atPath: fileURL.path)
      else {
        return
      }
      result[resourceID] = fileURL
    }
  }
}

private struct VaultSavedAttachment {

  let id: UUID
  let kind: JournalVault.Attachment.Kind
  let byteSize: Int
  let primaryResourceID: UUID
  let fileURL: URL
  let fileRevision: Int
  let thumbnail: Data?
  let resources: [VaultSavedAttachmentResource]

  init?(attachment: JournalVault.Attachment, store: VaultContentStore) {
    let resources = attachment.resources
      .sorted { lhs, rhs in
        if lhs.createdAt != rhs.createdAt {
          return lhs.createdAt < rhs.createdAt
        }
        return lhs.id.uuidString < rhs.id.uuidString
      }
      .map { VaultSavedAttachmentResource(resource: $0, store: store) }

    guard
      let primaryResource = resources.first(where: {
        $0.id == attachment.primaryResourceID
      })
    else {
      return nil
    }

    self.id = attachment.id
    self.kind = attachment.kind
    self.byteSize = attachment.byteSize
    self.primaryResourceID = attachment.primaryResourceID
    self.fileURL = primaryResource.fileURL
    self.fileRevision = resources.reduce(0) { $0 &+ $1.localFileRevision }
    self.thumbnail = attachment.thumbnail
    self.resources = resources
  }

  var primaryResource: VaultSavedAttachmentResource? {
    resources.first { $0.id == primaryResourceID }
  }
}

private struct VaultSavedAttachmentResource {

  let id: UUID
  let role: JournalVault.AttachmentResource.Role
  let byteSize: Int
  let contentType: String?
  let pixelWidth: Int?
  let pixelHeight: Int?
  let duration: Double?
  let fileURL: URL
  let localFileRevision: Int

  init(resource: JournalVault.AttachmentResource, store: VaultContentStore) {
    self.id = resource.id
    self.role = resource.role
    self.byteSize = resource.byteSize
    self.contentType = resource.contentType
    self.pixelWidth = resource.pixelWidth
    self.pixelHeight = resource.pixelHeight
    self.duration = resource.duration
    self.fileURL = store.fileURL(for: resource)
    self.localFileRevision = resource.localFileRevision
  }

  var pixelSize: CGSize? {
    guard let pixelWidth, let pixelHeight else {
      return nil
    }

    return CGSize(width: pixelWidth, height: pixelHeight)
  }
}

/// Errors surfaced when a saved vault entry cannot be reopened as an editable draft.
enum VaultSavedEntryEditDraftError: LocalizedError {
  case vaultUnavailable
  case mediaUnavailable
  case mediaDecodeFailed
  case mediaCopyFailed
  case unsupportedKind

  var errorDescription: String? {
    switch self {
    case .vaultUnavailable:
      return String(localized: "The selected vault is not available.")
    case .mediaUnavailable:
      return String(
        localized:
          "This entry's media file is not available on this device yet."
      )
    case .mediaDecodeFailed:
      return String(
        localized: "This entry's media file could not be read for editing."
      )
    case .mediaCopyFailed:
      return String(
        localized: "This entry's media file could not be prepared for editing."
      )
    case .unsupportedKind:
      return String(localized: "This content type is not editable yet.")
    }
  }
}

/// File I/O shared by saved-entry edit rehydration.
private enum VaultSavedEntryMediaFileReader {
  nonisolated static func data(from fileURL: URL) async -> Data? {
    await Task.detached(priority: .utility) {
      try? Data(contentsOf: fileURL)
    }.value
  }
}

/// File preparation needed before persisted media can re-enter the edit pipeline.
private enum VaultSavedEntryEditMediaPreparer {

  @MainActor
  static func audioCopy(from sourceURL: URL) throws -> URL {
    try mediaCopy(from: sourceURL, fallbackPathExtension: "m4a")
  }

  @MainActor
  static func mediaCopy(
    from sourceURL: URL,
    fallbackPathExtension: String
  ) throws -> URL {
    guard FileManager.default.fileExists(atPath: sourceURL.path) else {
      throw VaultSavedEntryEditDraftError.mediaUnavailable
    }

    let pathExtension =
      sourceURL.pathExtension.isEmpty
      ? fallbackPathExtension : sourceURL.pathExtension
    let destinationURL = FileManager.default.temporaryDirectory
      .appendingPathComponent("journal-vault-edit-media-\(UUID().uuidString)")
      .appendingPathExtension(pathExtension)

    do {
      try FileManager.default.copyItem(at: sourceURL, to: destinationURL)
      return destinationURL
    } catch {
      throw VaultSavedEntryEditDraftError.mediaCopyFailed
    }
  }

  @MainActor
  static func audioDuration(from fileURL: URL) -> TimeInterval {
    (try? AVAudioPlayer(contentsOf: fileURL).duration) ?? 0
  }
}

struct VaultSavedDaySection: Identifiable {
  let id: Date
  let day: Date
  var entries: [VaultSavedEntry]

  static func sections(
    for entries: [VaultSavedEntry],
    calendar: Calendar
  ) -> [VaultSavedDaySection] {
    var sectionIndexesByDay: [Date: Int] = [:]
    var sections: [VaultSavedDaySection] = []

    for entry in entries {
      let day = calendar.startOfDay(for: entry.createdAt)
      if let sectionIndex = sectionIndexesByDay[day] {
        sections[sectionIndex].entries.append(entry)
      } else {
        sectionIndexesByDay[day] = sections.count
        sections.append(
          VaultSavedDaySection(id: day, day: day, entries: [entry])
        )
      }
    }

    return sections
  }
}

extension VaultSavedEntry {

  /// Detached values handed to the share/export feature.
  ///
  /// The share sheet renders temporary files from this value copy, so it never
  /// holds a live SwiftData model or reaches back into the selected vault.
  var shareSource: EntryShareSource {
    EntryShareSource(
      id: edgeID,
      kind: kind,
      body: body,
      createdAt: createdAt,
      location: location,
      attachment: attachment?.shareSource
    )
  }

  /// Display projection handed to `AppUIComponents`.
  ///
  /// The saved-list feature owns live vault models and mutation callbacks; the
  /// UI component module receives only the stable values it needs to render a card.
  var entryModel: VaultSavedEntryModel {
    VaultSavedEntryModel(
      id: edgeID,
      kind: kind,
      body: body,
      createdAt: createdAt,
      updatedAt: updatedAt,
      location: location,
      attachment: attachment?.entryModel
    )
  }
}

extension VaultSavedAttachment {

  fileprivate var shareSource: EntryShareAttachmentSource {
    EntryShareAttachmentSource(
      kind: kind,
      fileURL: fileURL,
      thumbnail: thumbnail,
      contentType: primaryResource?.contentType,
      byteSize: primaryResource?.byteSize
    )
  }

  fileprivate var entryModel: VaultSavedEntryAttachmentModel {
    VaultSavedEntryAttachmentModel(
      kind: kind,
      fileURL: fileURL,
      pairedVideoFileURL: resources.first { $0.role == .pairedVideo }?.fileURL,
      fileRevision: fileRevision,
      thumbnail: thumbnail,
      pixelSize: primaryResource?.pixelSize,
      contentType: primaryResource?.contentType,
      byteSize: primaryResource?.byteSize,
      suggestionMediaFileURLsByResourceID: suggestionMediaFileURLsByResourceID
    )
  }

  private var suggestionMediaFileURLsByResourceID: [UUID: URL] {
    resources.reduce(into: [UUID: URL]()) { result, resource in
      switch resource.role {
      case .suggestionImage, .suggestionVideo:
        result[resource.id] = resource.fileURL
      case .originalImage,
        .file,
        .stillImage,
        .pairedVideo,
        .originalVideo,
        .authoredJSON,
        .audio,
        .unknown:
        break
      @unknown default:
        break
      }
    }
  }
}

// MARK: - Sorting

extension Array where Element == VaultSavedEntry {

  func sortedForVaultList() -> [VaultSavedEntry] {
    sorted { lhs, rhs in
      if lhs.createdAt != rhs.createdAt {
        return lhs.createdAt > rhs.createdAt
      }
      return lhs.edgeID.uuidString < rhs.edgeID.uuidString
    }
  }

  func sortedForVaultListSiblings() -> [VaultSavedEntry] {
    sorted { lhs, rhs in
      if lhs.sortIndex != rhs.sortIndex {
        return lhs.sortIndex < rhs.sortIndex
      }
      if lhs.createdAt != rhs.createdAt {
        return lhs.createdAt < rhs.createdAt
      }
      return lhs.edgeID.uuidString < rhs.edgeID.uuidString
    }
  }
}

extension UIImage {

  /// Pixel dimensions for persistence metadata derived from reloaded image data.
  fileprivate var pixelSize: CGSize {
    CGSize(width: size.width * scale, height: size.height * scale)
  }
}
