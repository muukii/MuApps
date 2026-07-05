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
    static let primaryResourceID = "primaryResourceID"
    static let thumbnail = "thumbnail"
    static let createdAt = "createdAt"
  }

  enum AttachmentResourceKey {
    static let attachmentID = "attachmentID"
    static let role = "role"
    static let byteSize = "byteSize"
    static let contentType = "contentType"
    static let pixelWidth = "pixelWidth"
    static let pixelHeight = "pixelHeight"
    static let duration = "duration"
    static let isHDR = "isHDR"
    static let colorSpaceName = "colorSpaceName"
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

  static func applyFields(of attachment: Attachment, to record: CKRecord) {
    record[AttachmentKey.cardID] = attachment.cardID.uuidString
    record[AttachmentKey.kind] = attachment.kindRawValue
    record[AttachmentKey.byteSize] = attachment.byteSize
    record[AttachmentKey.primaryResourceID] = attachment.primaryResourceID.uuidString
    record[AttachmentKey.thumbnail] = attachment.thumbnail
    record[AttachmentKey.createdAt] = attachment.createdAt
  }

  /// `assetFileURL` is the local resource file to upload. When the file is not
  /// available locally, the record updates its metadata without touching the
  /// existing remote asset.
  static func applyFields(
    of resource: AttachmentResource,
    assetFileURL: URL?,
    to record: CKRecord
  ) {
    record[AttachmentResourceKey.attachmentID] = resource.attachmentID.uuidString
    record[AttachmentResourceKey.role] = resource.roleRawValue
    record[AttachmentResourceKey.byteSize] = resource.byteSize
    record[AttachmentResourceKey.contentType] = resource.contentType
    record[AttachmentResourceKey.pixelWidth] = resource.pixelWidth
    record[AttachmentResourceKey.pixelHeight] = resource.pixelHeight
    record[AttachmentResourceKey.duration] = resource.duration
    record[AttachmentResourceKey.isHDR] = resource.isHDR
    record[AttachmentResourceKey.colorSpaceName] = resource.colorSpaceName
    record[AttachmentResourceKey.createdAt] = resource.createdAt
    if let assetFileURL {
      record[AttachmentResourceKey.file] = CKAsset(fileURL: assetFileURL)
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
    if let primaryResourceID = (record[AttachmentKey.primaryResourceID] as? String)
      .flatMap(UUID.init(uuidString:))
    {
      attachment.primaryResourceID = primaryResourceID
    }
    attachment.thumbnail = record[AttachmentKey.thumbnail] as? Data
    if let createdAt = record[AttachmentKey.createdAt] as? Date {
      attachment.createdAt = createdAt
    }
  }

  static func update(_ resource: AttachmentResource, from record: CKRecord) {
    if let attachmentID = (record[AttachmentResourceKey.attachmentID] as? String).flatMap(UUID.init(uuidString:)) {
      resource.attachmentID = attachmentID
    }
    if let role = record[AttachmentResourceKey.role] as? String {
      resource.roleRawValue = role
    }
    resource.byteSize = record[AttachmentResourceKey.byteSize] as? Int ?? 0
    resource.contentType = record[AttachmentResourceKey.contentType] as? String
    resource.pixelWidth = record[AttachmentResourceKey.pixelWidth] as? Int
    resource.pixelHeight = record[AttachmentResourceKey.pixelHeight] as? Int
    resource.duration = record[AttachmentResourceKey.duration] as? Double
    resource.isHDR = record[AttachmentResourceKey.isHDR] as? Bool ?? false
    resource.colorSpaceName = record[AttachmentResourceKey.colorSpaceName] as? String
    if let createdAt = record[AttachmentResourceKey.createdAt] as? Date {
      resource.createdAt = createdAt
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
