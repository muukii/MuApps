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

// MARK: - Live Card Values

extension JournalVault.Card {

  /// Detached one-line text used to identify this placement after its context
  /// menu closes.
  ///
  /// Text-like cards retain a short excerpt of authored content. Media cards
  /// use their localized kind instead of exposing persisted payload text that
  /// is not intended for display.
  var replyDisplaySummary: String {
    switch kind {
    case .text, .todo, .link, .file, .unknown:
      let normalizedBody = body.split(whereSeparator: \.isWhitespace)
        .joined(separator: " ")
      if normalizedBody.isEmpty == false {
        return String(normalizedBody.prefix(120))
      }
    case .photo, .video, .livePhoto, .audio, .suggestion, .doodle, .bauhaus:
      break
    @unknown default:
      break
    }

    return String(localized: kind.vaultListDisplayTitle)
  }

  /// Resolves the first attachment whose primary resource row is available.
  ///
  /// CloudKit may materialize the attachment row before its primary resource.
  /// In that state the card remains renderable with its content placeholder.
  fileprivate func resolvedSavedAttachment(
    in store: VaultContentStore
  ) -> ResolvedVaultAttachment? {
    attachments
      .sorted { lhs, rhs in
        if lhs.createdAt != rhs.createdAt {
          return lhs.createdAt < rhs.createdAt
        }
        return lhs.id.uuidString < rhs.id.uuidString
      }
      .lazy
      .compactMap { ResolvedVaultAttachment(attachment: $0, store: store) }
      .first
  }
}

extension JournalVault.Card {

  /// Rehydrates this saved card into the shared editing draft model.
  ///
  /// Media cards require the full vault media file. Raster previews are
  /// intentionally not used to create a lossy edit draft.
  @MainActor
  func editDraft(store: VaultContentStore) async throws -> CardEditDraft {
    let attachment = resolvedSavedAttachment(in: store)

    switch kind {
    case .text:
      return CardEditDraft(kind: .text, text: body, location: location)
    case .todo:
      return CardEditDraft(
        kind: .todo,
        text: body,
        completedAt: completedAt,
        location: location
      )
    case .link:
      return CardEditDraft(kind: .link, text: body, location: location)
    case .file:
      // Generic file cards preserve arbitrary bytes and metadata, but the
      // composer does not yet expose a lossless file-replacement editor.
      throw VaultSavedEntryEditDraftError.unsupportedKind
    case .photo:
      let data = try await mediaData(
        matching: .photo,
        attachment: attachment
      )
      guard let image = UIImage(data: data) else {
        throw VaultSavedEntryEditDraftError.mediaDecodeFailed
      }
      return CardEditDraft(
        kind: .photo,
        photo: CapturedPhoto(imageData: data, pixelSize: image.pixelSize),
        location: location
      )
    case .video:
      let fileURL = try mediaFileURL(
        matching: .video,
        attachment: attachment
      )
      let editableURL = try VaultSavedEntryEditMediaPreparer.mediaCopy(
        from: fileURL,
        fallbackPathExtension: "mov"
      )
      let resource = attachment?.primaryResource
      return CardEditDraft(
        kind: .video,
        video: CapturedVideo(
          fileURL: editableURL,
          pixelSize: resource?.pixelSize ?? .zero,
          duration: resource?.duration ?? 0,
          contentTypeIdentifier: resource?.contentType,
          byteSize: resource?.byteSize
        ),
        location: location
      )
    case .livePhoto:
      let stillData = try await mediaData(
        matching: .stillImage,
        attachment: attachment
      )
      let pairedVideoFileURL = try mediaFileURL(
        matching: .pairedVideo,
        attachment: attachment
      )
      let editablePairedVideoURL =
        try VaultSavedEntryEditMediaPreparer.mediaCopy(
          from: pairedVideoFileURL,
          fallbackPathExtension: "mov"
        )
      let stillResource = try mediaResource(
        matching: .stillImage,
        attachment: attachment
      )
      let pairedVideoResource = try mediaResource(
        matching: .pairedVideo,
        attachment: attachment
      )
      return CardEditDraft(
        kind: .livePhoto,
        livePhoto: CapturedLivePhoto(
          stillImageData: stillData,
          pairedVideoFileURL: editablePairedVideoURL,
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
        matching: JournalVault.Attachment.Kind.audio,
        attachment: attachment
      )
      let editableURL = try VaultSavedEntryEditMediaPreparer.audioCopy(
        from: fileURL
      )
      let waveform = attachment?.primaryResource.waveformData.flatMap {
        AudioWaveform.decode(from: $0)
      }
      return CardEditDraft(
        kind: .audio,
        audio: AudioRecording(
          fileURL: editableURL,
          // Decoding the copy is a fallback for records saved before the
          // captured length was persisted.
          duration: attachment?.primaryResource.duration
            ?? VaultSavedEntryEditMediaPreparer.audioDuration(from: editableURL),
          waveform: waveform
        ),
        location: location
      )
    case .suggestion:
      let data = try await mediaData(
        matching: .suggestion,
        attachment: attachment
      )
      guard let suggestion = SuggestionCardPayload.decode(from: data) else {
        throw VaultSavedEntryEditDraftError.mediaDecodeFailed
      }
      return CardEditDraft(
        kind: .suggestion,
        suggestion: suggestion,
        suggestionMediaFileURLsByResourceID:
          suggestionMediaFileURLsByResourceID(
            for: suggestion,
            attachment: attachment
          ),
        location: location
      )
    case .doodle:
      let data = try await mediaData(
        matching: .doodle,
        attachment: attachment
      )
      guard
        let drawing = try? JSONDecoder().decode(DoodleDrawing.self, from: data)
      else {
        throw VaultSavedEntryEditDraftError.mediaDecodeFailed
      }
      return CardEditDraft(kind: .doodle, doodle: drawing, location: location)
    case .bauhaus:
      let data = try await mediaData(
        matching: .bauhaus,
        attachment: attachment
      )
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

  private func mediaFileURL(
    matching kind: JournalVault.Attachment.Kind,
    attachment: ResolvedVaultAttachment?
  ) throws -> URL {
    guard attachment?.kind == kind,
      let fileURL = attachment?.fileURL,
      FileManager.default.fileExists(atPath: fileURL.path)
    else {
      throw VaultSavedEntryEditDraftError.mediaUnavailable
    }
    return fileURL
  }

  private func mediaFileURL(
    matching role: JournalVault.AttachmentResource.Role,
    attachment: ResolvedVaultAttachment?
  ) throws -> URL {
    let resource = try mediaResource(
      matching: role,
      attachment: attachment
    )
    guard FileManager.default.fileExists(atPath: resource.fileURL.path) else {
      throw VaultSavedEntryEditDraftError.mediaUnavailable
    }
    return resource.fileURL
  }

  private func mediaResource(
    matching role: JournalVault.AttachmentResource.Role,
    attachment: ResolvedVaultAttachment?
  ) throws -> ResolvedVaultAttachmentResource {
    guard let resource = attachment?.resources.first(where: { $0.role == role })
    else {
      throw VaultSavedEntryEditDraftError.mediaUnavailable
    }
    return resource
  }

  private func mediaData(
    matching kind: JournalVault.Attachment.Kind,
    attachment: ResolvedVaultAttachment?
  ) async throws -> Data {
    let fileURL = try mediaFileURL(
      matching: kind,
      attachment: attachment
    )
    guard let data = await VaultSavedEntryMediaFileReader.data(from: fileURL)
    else {
      throw VaultSavedEntryEditDraftError.mediaUnavailable
    }
    return data
  }

  private func mediaData(
    matching role: JournalVault.AttachmentResource.Role,
    attachment: ResolvedVaultAttachment?
  ) async throws -> Data {
    let fileURL = try mediaFileURL(
      matching: role,
      attachment: attachment
    )
    guard let data = await VaultSavedEntryMediaFileReader.data(from: fileURL)
    else {
      throw VaultSavedEntryEditDraftError.mediaUnavailable
    }
    return data
  }

  private func suggestionMediaFileURLsByResourceID(
    for suggestion: SuggestionCardPayload,
    attachment: ResolvedVaultAttachment?
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

/// File-system-resolved attachment values used while deriving operation values.
///
/// This is private implementation state, not a presentation or persistence
/// model. Its only job is to normalize resource order and local file URLs once.
private struct ResolvedVaultAttachment {

  let kind: JournalVault.Attachment.Kind
  let fileURL: URL
  let fileRevision: Int
  let primaryResource: ResolvedVaultAttachmentResource
  let resources: [ResolvedVaultAttachmentResource]

  init?(attachment: JournalVault.Attachment, store: VaultContentStore) {
    let resources = attachment.resources
      .sorted { lhs, rhs in
        if lhs.createdAt != rhs.createdAt {
          return lhs.createdAt < rhs.createdAt
        }
        return lhs.id.uuidString < rhs.id.uuidString
      }
      .map { ResolvedVaultAttachmentResource(resource: $0, store: store) }

    guard
      let primaryResource = resources.first(where: {
        $0.id == attachment.primaryResourceID
      })
    else {
      return nil
    }

    self.kind = attachment.kind
    self.fileURL = primaryResource.fileURL
    self.fileRevision = resources.reduce(0) { $0 &+ $1.localFileRevision }
    self.primaryResource = primaryResource
    self.resources = resources
  }
}

/// File-system-resolved values for one concrete attachment resource.
private struct ResolvedVaultAttachmentResource {

  let id: UUID
  let role: JournalVault.AttachmentResource.Role
  let byteSize: Int
  let contentType: String?
  let pixelSize: CGSize?
  let duration: Double?
  let waveformData: Data?
  let fileURL: URL
  let localFileRevision: Int

  init(resource: JournalVault.AttachmentResource, store: VaultContentStore) {
    self.id = resource.id
    self.role = resource.role
    self.byteSize = resource.byteSize
    self.contentType = resource.contentType
    if let pixelWidth = resource.pixelWidth,
      let pixelHeight = resource.pixelHeight
    {
      self.pixelSize = CGSize(width: pixelWidth, height: pixelHeight)
    } else {
      self.pixelSize = nil
    }
    self.duration = resource.duration
    self.waveformData = resource.waveformData
    self.fileURL = store.fileURL(for: resource)
    self.localFileRevision = resource.localFileRevision
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
  var roots: [JournalVault.CardEdge]

  static func sections(
    for roots: [JournalVault.CardEdge],
    calendar: Calendar
  ) -> [VaultSavedDaySection] {
    var sectionIndexesByDay: [Date: Int] = [:]
    var sections: [VaultSavedDaySection] = []

    for root in roots {
      guard let card = root.card else { continue }
      let day = calendar.startOfDay(for: card.createdAt)
      if let sectionIndex = sectionIndexesByDay[day] {
        sections[sectionIndex].roots.append(root)
      } else {
        sectionIndexesByDay[day] = sections.count
        sections.append(
          VaultSavedDaySection(id: day, day: day, roots: [root])
        )
      }
    }

    return sections
  }
}

extension EntryContent {

  /// Creates renderable authored content directly from a live vault card.
  ///
  /// The card remains the observed SwiftData source of truth. `store` is used
  /// only to resolve each attachment resource's local file URL at render time.
  init(card: JournalVault.Card, store: VaultContentStore) {
    let attachment = card.resolvedSavedAttachment(in: store)

    switch card.kind {
    case .text:
      self = .text(card.body)
    case .todo:
      self = .todo(
        TodoContentSource(text: card.body, completedAt: card.completedAt)
      )
    case .link:
      self = .link(card.body)
    case .file:
      let fileAttachment = attachment?.kind == .file ? attachment : nil
      self = .file(
        FileContentSource(
          displayName: card.body,
          fileURL: fileAttachment?.fileURL,
          contentType: fileAttachment?.primaryResource.contentType,
          byteSize: fileAttachment?.primaryResource.byteSize
        )
      )
    case .photo:
      let photoAttachment = attachment?.kind == .photo ? attachment : nil
      self = .photo(
        PhotoContentSource(
          fileURL: photoAttachment?.fileURL,
          fileRevision: photoAttachment?.fileRevision ?? 0,
          pixelSize: photoAttachment?.primaryResource.pixelSize
        )
      )
    case .video:
      let videoAttachment = attachment?.kind == .video ? attachment : nil
      self = .video(
        VideoContentSource(
          fileURL: videoAttachment?.fileURL,
          fileRevision: videoAttachment?.fileRevision ?? 0,
          pixelSize: videoAttachment?.primaryResource.pixelSize
        )
      )
    case .livePhoto:
      let livePhotoAttachment =
        attachment?.kind == .livePhoto ? attachment : nil
      self = .livePhoto(
        LivePhotoContentSource(
          fileURL: livePhotoAttachment?.fileURL,
          pairedVideoFileURL: livePhotoAttachment?.pairedVideoFileURL,
          fileRevision: livePhotoAttachment?.fileRevision ?? 0,
          pixelSize: livePhotoAttachment?.primaryResource.pixelSize
        )
      )
    case .audio:
      let audioAttachment = attachment?.kind == .audio ? attachment : nil
      self = .audio(
        AudioContentSource(
          fileURL: audioAttachment?.fileURL,
          waveformLevels: audioAttachment?.waveformLevels,
          duration: audioAttachment?.primaryResource.duration
        )
      )
    case .suggestion:
      let suggestionAttachment =
        attachment?.kind == .suggestion ? attachment : nil
      self = .suggestion(
        SuggestionContentSource(
          fileURL: suggestionAttachment?.fileURL,
          fileRevision: suggestionAttachment?.fileRevision ?? 0,
          mediaFileURLsByResourceID:
            suggestionAttachment?.suggestionMediaFileURLsByResourceID ?? [:]
        )
      )
    case .doodle:
      let doodleAttachment = attachment?.kind == .doodle ? attachment : nil
      self = .doodle(
        DoodleContentSource(
          fileURL: doodleAttachment?.fileURL,
          fileRevision: doodleAttachment?.fileRevision ?? 0,
          pixelSize: doodleAttachment?.primaryResource.pixelSize
        )
      )
    case .bauhaus:
      let bauhausAttachment = attachment?.kind == .bauhaus ? attachment : nil
      self = .bauhaus(
        BauhausContentSource(
          fileURL: bauhausAttachment?.fileURL,
          fileRevision: bauhausAttachment?.fileRevision ?? 0
        )
      )
    case .unknown:
      self = .unknown
    @unknown default:
      self = .unknown
    }
  }
}

extension JournalVault.Card {

  /// Creates the detached values handed to the share/export feature.
  ///
  /// The share sheet renders temporary files from this value copy, so it never
  /// holds a live SwiftData model or reaches back into the selected vault.
  func shareSource(
    edgeID: UUID,
    store: VaultContentStore
  ) -> EntryShareSource {
    EntryShareSource(
      id: edgeID,
      kind: kind,
      body: body,
      completedAt: completedAt,
      attachment: resolvedSavedAttachment(in: store)?.shareSource
    )
  }
}

extension ResolvedVaultAttachment {

  fileprivate var shareSource: EntryShareAttachmentSource {
    EntryShareAttachmentSource(
      kind: kind,
      fileURL: fileURL,
      contentType: primaryResource.contentType,
      byteSize: primaryResource.byteSize,
      duration: primaryResource.duration
    )
  }

  fileprivate var pairedVideoFileURL: URL? {
    resources.first { $0.role == .pairedVideo }?.fileURL
  }

  /// Validated meter levels for rendering an audio attachment.
  ///
  /// Decoding at this projection boundary keeps persistence-version handling
  /// out of the reusable UI component module.
  fileprivate var waveformLevels: Data? {
    guard kind == .audio,
      let data = primaryResource.waveformData,
      let waveform = AudioWaveform.decode(from: data)
    else {
      return nil
    }

    return waveform.levels
  }

  fileprivate var suggestionMediaFileURLsByResourceID: [UUID: URL] {
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

extension JournalVault.Card.Kind {

  /// Localized title used when Home describes a content kind without its body.
  var vaultListDisplayTitle: LocalizedStringResource {
    switch self {
    case .text:
      "Text"
    case .todo:
      "Todo"
    case .link:
      "Link"
    case .file:
      "File"
    case .photo:
      "Photo"
    case .video:
      "Video"
    case .livePhoto:
      "Live Photo"
    case .audio:
      "Audio"
    case .suggestion:
      "Suggestion"
    case .doodle:
      "Doodle"
    case .bauhaus:
      "Bauhaus"
    case .unknown:
      "Entry"
    @unknown default:
      "Entry"
    }
  }

  /// SF Symbol used by Home's content-kind filters and fallback labels.
  var vaultListSymbolName: String {
    switch self {
    case .text:
      "text.alignleft"
    case .todo:
      "checkmark.circle"
    case .link:
      "link"
    case .file:
      "doc"
    case .photo:
      "photo"
    case .video:
      "video"
    case .livePhoto:
      "livephoto"
    case .audio:
      "waveform"
    case .suggestion:
      "sparkles"
    case .doodle:
      "scribble"
    case .bauhaus:
      "square.grid.3x3"
    case .unknown:
      "questionmark.square.dashed"
    @unknown default:
      "questionmark.square.dashed"
    }
  }
}

extension UIImage {

  /// Pixel dimensions for persistence metadata derived from reloaded image data.
  fileprivate var pixelSize: CGSize {
    CGSize(width: size.width * scale, height: size.height * scale)
  }
}
