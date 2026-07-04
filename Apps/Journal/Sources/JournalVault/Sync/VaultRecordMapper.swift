import CloudKit
import CoreLocation
import Foundation

/// Field-level mapping between vault store rows and their CloudKit records.
///
/// `CKRecord` is transport shape, not persistence: outgoing records are always
/// rebuilt from the live row (plus archived system fields from `SyncMetadata`),
/// and incoming records are applied field-by-field onto rows. These are pure
/// functions with no store access, so the mapping is unit-testable offline.
///
/// Field keys are part of the server schema — renaming one is a migration for
/// every record already uploaded.
enum VaultRecordMapper {

  enum VaultInfoKey {
    static let title = "title"
    static let createdAt = "createdAt"
    static let updatedAt = "updatedAt"
  }

  enum CardKey {
    static let kind = "kind"
    static let body = "body"
    static let createdAt = "createdAt"
    static let updatedAt = "updatedAt"
    static let location = "location"
  }

  enum CardEdgeKey {
    static let cardID = "cardID"
    static let parentEdgeID = "parentEdgeID"
    static let sortIndex = "sortIndex"
    static let layout = "layout"
    static let createdAt = "createdAt"
    static let updatedAt = "updatedAt"
  }

  enum AttachmentKey {
    static let cardID = "cardID"
    static let kind = "kind"
    static let byteSize = "byteSize"
    static let thumbnail = "thumbnail"
    static let createdAt = "createdAt"
    static let file = "file"
  }

  // MARK: - Outgoing

  static func applyFields(of info: VaultInfo, to record: CKRecord) {
    record[VaultInfoKey.title] = info.title
    record[VaultInfoKey.createdAt] = info.createdAt
    record[VaultInfoKey.updatedAt] = info.updatedAt
  }

  static func applyFields(of card: Card, to record: CKRecord) {
    record[CardKey.kind] = card.kindRawValue
    record[CardKey.body] = card.body
    record[CardKey.createdAt] = card.createdAt
    record[CardKey.updatedAt] = card.updatedAt
    record[CardKey.location] = card.location.map {
      CLLocation(latitude: $0.latitude, longitude: $0.longitude)
    }
  }

  static func applyFields(of edge: CardEdge, to record: CKRecord) {
    record[CardEdgeKey.cardID] = edge.cardID.uuidString
    // A plain field, not CKRecord.parent: the sharing boundary is the zone, and
    // tree semantics (cycles, cascades) are domain rules, not record hierarchy.
    record[CardEdgeKey.parentEdgeID] = edge.parentEdgeID?.uuidString
    record[CardEdgeKey.sortIndex] = edge.sortIndex
    record[CardEdgeKey.layout] = edge.layout
    record[CardEdgeKey.createdAt] = edge.createdAt
    record[CardEdgeKey.updatedAt] = edge.updatedAt
  }

  /// `assetFileURL` is the local media file to upload, or `nil` when the bytes
  /// aren't on this device (an imported row) — the record then updates without
  /// touching the existing remote asset... the server keeps the previous value
  /// for fields the record doesn't set.
  static func applyFields(of attachment: Attachment, assetFileURL: URL?, to record: CKRecord) {
    record[AttachmentKey.cardID] = attachment.cardID.uuidString
    record[AttachmentKey.kind] = attachment.kindRawValue
    record[AttachmentKey.byteSize] = attachment.byteSize
    record[AttachmentKey.thumbnail] = attachment.thumbnail
    record[AttachmentKey.createdAt] = attachment.createdAt
    if let assetFileURL {
      record[AttachmentKey.file] = CKAsset(fileURL: assetFileURL)
    }
  }

  // MARK: - Incoming

  static func update(_ info: VaultInfo, from record: CKRecord) {
    info.title = record[VaultInfoKey.title] as? String ?? ""
    if let createdAt = record[VaultInfoKey.createdAt] as? Date {
      info.createdAt = createdAt
    }
    if let updatedAt = record[VaultInfoKey.updatedAt] as? Date {
      info.updatedAt = updatedAt
    }
  }

  static func update(_ card: Card, from record: CKRecord) {
    if let kind = record[CardKey.kind] as? String {
      card.kindRawValue = kind
    }
    card.body = record[CardKey.body] as? String ?? ""
    if let createdAt = record[CardKey.createdAt] as? Date {
      card.createdAt = createdAt
    }
    if let updatedAt = record[CardKey.updatedAt] as? Date {
      card.updatedAt = updatedAt
    }
    if let location = record[CardKey.location] as? CLLocation {
      card.location = Coordinate(location.coordinate)
    } else {
      card.location = nil
    }
  }

  static func update(_ edge: CardEdge, from record: CKRecord) {
    if let cardID = (record[CardEdgeKey.cardID] as? String).flatMap(UUID.init(uuidString:)) {
      edge.cardID = cardID
    }
    edge.parentEdgeID = (record[CardEdgeKey.parentEdgeID] as? String)
      .flatMap(UUID.init(uuidString:))
    edge.sortIndex = record[CardEdgeKey.sortIndex] as? Int ?? 0
    edge.layout = record[CardEdgeKey.layout] as? Data
    if let createdAt = record[CardEdgeKey.createdAt] as? Date {
      edge.createdAt = createdAt
    }
    if let updatedAt = record[CardEdgeKey.updatedAt] as? Date {
      edge.updatedAt = updatedAt
    }
  }

  static func update(_ attachment: Attachment, from record: CKRecord) {
    if let cardID = (record[AttachmentKey.cardID] as? String).flatMap(UUID.init(uuidString:)) {
      attachment.cardID = cardID
    }
    if let kind = record[AttachmentKey.kind] as? String {
      attachment.kindRawValue = kind
    }
    attachment.byteSize = record[AttachmentKey.byteSize] as? Int ?? 0
    attachment.thumbnail = record[AttachmentKey.thumbnail] as? Data
    if let createdAt = record[AttachmentKey.createdAt] as? Date {
      attachment.createdAt = createdAt
    }
  }

  // MARK: - System fields

  /// Encodes only the record's system fields (identity, change tag, share
  /// linkage) for `SyncMetadata`. User fields are re-derived from the row at
  /// send time.
  static func encodeSystemFields(of record: CKRecord) -> Data {
    let archiver = NSKeyedArchiver(requiringSecureCoding: true)
    record.encodeSystemFields(with: archiver)
    archiver.finishEncoding()
    return archiver.encodedData
  }

  /// Rebuilds a record shell (system fields only) from `SyncMetadata`, carrying
  /// the server's change tag for conflict detection on the next save.
  static func record(fromSystemFields data: Data) -> CKRecord? {
    guard let unarchiver = try? NSKeyedUnarchiver(forReadingFrom: data) else { return nil }
    unarchiver.requiresSecureCoding = true
    defer { unarchiver.finishDecoding() }
    return CKRecord(coder: unarchiver)
  }
}
