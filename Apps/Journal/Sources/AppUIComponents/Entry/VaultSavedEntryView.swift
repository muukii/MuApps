import CoreGraphics
import Foundation
import JournalVault

/// Display value consumed by saved-entry components.
///
/// This is intentionally smaller than the vault store row graph. Feature code
/// owns persistence, editing, deletion, and tree traversal; `AppUIComponents`
/// only needs the stable values required to draw saved authored content.
public struct VaultSavedEntryModel: Identifiable, Hashable {
  public let id: UUID
  public let kind: JournalVault.Card.Kind
  public let body: String
  public let completedAt: Date?
  public let createdAt: Date
  public let updatedAt: Date
  public let location: JournalVault.Coordinate?
  public let attachment: VaultSavedEntryAttachmentModel?

  public init(
    id: UUID,
    kind: JournalVault.Card.Kind,
    body: String,
    completedAt: Date? = nil,
    createdAt: Date,
    updatedAt: Date,
    location: JournalVault.Coordinate?,
    attachment: VaultSavedEntryAttachmentModel?
  ) {
    self.id = id
    self.kind = kind
    self.body = body
    self.completedAt = completedAt
    self.createdAt = createdAt
    self.updatedAt = updatedAt
    self.location = location
    self.attachment = attachment
  }

  /// Authored content projected away from the persistence row graph.
  public var content: EntryContent {
    EntryContent(
      kind: kind,
      body: body,
      completedAt: completedAt,
      attachment: attachment?.contentAttachment
    )
  }
}

/// Saved file-backed attachment values needed by saved-entry components.
public struct VaultSavedEntryAttachmentModel: Hashable {
  public let kind: JournalVault.Attachment.Kind
  public let fileURL: URL
  public let pairedVideoFileURL: URL?
  public let fileRevision: Int
  public let thumbnail: Data?
  public let pixelSize: CGSize?
  public let contentType: String?
  public let byteSize: Int?
  /// Validated, quantized audio levels ordered from recording start to end.
  public let waveformLevels: Data?
  public let suggestionMediaFileURLsByResourceID: [UUID: URL]

  public init(
    kind: JournalVault.Attachment.Kind,
    fileURL: URL,
    pairedVideoFileURL: URL? = nil,
    fileRevision: Int = 0,
    thumbnail: Data?,
    pixelSize: CGSize? = nil,
    contentType: String? = nil,
    byteSize: Int? = nil,
    waveformLevels: Data? = nil,
    suggestionMediaFileURLsByResourceID: [UUID: URL] = [:]
  ) {
    self.kind = kind
    self.fileURL = fileURL
    self.pairedVideoFileURL = pairedVideoFileURL
    self.fileRevision = fileRevision
    self.thumbnail = thumbnail
    self.pixelSize = pixelSize
    self.contentType = contentType
    self.byteSize = byteSize
    self.waveformLevels = waveformLevels
    self.suggestionMediaFileURLsByResourceID = suggestionMediaFileURLsByResourceID
  }
}

extension VaultSavedEntryAttachmentModel {

  fileprivate var contentAttachment: EntryContentAttachment {
    EntryContentAttachment(
      kind: kind,
      fileURL: fileURL,
      pairedVideoFileURL: pairedVideoFileURL,
      fileRevision: fileRevision,
      thumbnailData: thumbnail,
      pixelSize: pixelSize,
      contentType: contentType,
      byteSize: byteSize,
      waveformLevels: waveformLevels,
      suggestionMediaFileURLsByResourceID: suggestionMediaFileURLsByResourceID
    )
  }
}

extension JournalVault.Card.Kind {

  public var vaultListDisplayTitle: LocalizedStringResource {
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

  public var vaultListSymbolName: String {
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
