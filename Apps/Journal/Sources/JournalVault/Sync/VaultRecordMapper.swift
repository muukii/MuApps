import CloudKit
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
    static let iconKind = "iconKind"
    static let iconValue = "iconValue"
    static let createdAt = "createdAt"
    static let updatedAt = "updatedAt"
  }

  enum CardKey {
    static let kind = "kind"
    static let body = "body"
    static let completedAt = "completedAt"
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
    let infoRecord = VaultInfoRecord(record: record)
    infoRecord.title = info.title
    infoRecord.iconKindRawValue = info.iconKindRawValue
    infoRecord.iconValue = info.iconValue
    infoRecord.createdAt = info.createdAt
    infoRecord.updatedAt = info.updatedAt
  }

  static func applyFields(of card: Card, to record: CKRecord) {
    let cardRecord = CardRecord(record: record)
    cardRecord.kindRawValue = card.kindRawValue
    cardRecord.body = card.body
    cardRecord.completedAt = card.kind == .todo ? card.completedAt : nil
    cardRecord.createdAt = card.createdAt
    cardRecord.updatedAt = card.updatedAt
    cardRecord.location = card.location
  }

  static func applyFields(of edge: CardEdge, to record: CKRecord) {
    let edgeRecord = CardEdgeRecord(record: record)
    edgeRecord.cardIDRawValue = edge.cardID.uuidString
    // A plain field, not CKRecord.parent: the sharing boundary is the zone, and
    // tree semantics (cycles, cascades) are domain rules, not record hierarchy.
    edgeRecord.parentEdgeIDRawValue = edge.parentEdgeID?.uuidString
    edgeRecord.sortIndex = edge.sortIndex
    edgeRecord.layout = edge.layout
    edgeRecord.createdAt = edge.createdAt
    edgeRecord.updatedAt = edge.updatedAt
  }

  static func applyFields(of attachment: Attachment, to record: CKRecord) {
    let attachmentRecord = AttachmentRecord(record: record)
    attachmentRecord.cardIDRawValue = attachment.cardID.uuidString
    attachmentRecord.kindRawValue = attachment.kindRawValue
    attachmentRecord.byteSize = attachment.byteSize
    attachmentRecord.primaryResourceIDRawValue = attachment.primaryResourceID.uuidString
    attachmentRecord.thumbnail = attachment.thumbnail
    attachmentRecord.createdAt = attachment.createdAt
  }

  /// `assetFileURL` is the local resource file to upload. When the file is not
  /// available locally, the record updates its metadata without touching the
  /// existing remote asset.
  static func applyFields(
    of resource: AttachmentResource,
    assetFileURL: URL?,
    to record: CKRecord
  ) {
    let resourceRecord = AttachmentResourceRecord(record: record)
    resourceRecord.attachmentIDRawValue = resource.attachmentID.uuidString
    resourceRecord.roleRawValue = resource.roleRawValue
    resourceRecord.byteSize = resource.byteSize
    resourceRecord.contentType = resource.contentType
    resourceRecord.pixelWidth = resource.pixelWidth
    resourceRecord.pixelHeight = resource.pixelHeight
    resourceRecord.duration = resource.duration
    resourceRecord.isHDR = resource.isHDR
    resourceRecord.colorSpaceName = resource.colorSpaceName
    resourceRecord.createdAt = resource.createdAt
    if let assetFileURL {
      resourceRecord.file = CKAsset(fileURL: assetFileURL)
    }
  }

  // MARK: - Incoming

  static func update(_ info: VaultInfo, from record: CKRecord) {
    let infoRecord = VaultInfoRecord(record: record)
    info.title = infoRecord.title
    if record[VaultInfoKey.iconKind] != nil, record[VaultInfoKey.iconValue] != nil {
      info.iconKindRawValue = infoRecord.iconKindRawValue
      info.iconValue = infoRecord.iconValue
    }
    if record[VaultInfoKey.createdAt] != nil {
      info.createdAt = infoRecord.createdAt
    }
    if record[VaultInfoKey.updatedAt] != nil {
      info.updatedAt = infoRecord.updatedAt
    }
  }

  /// Decodes valid icon metadata without inventing a value for legacy records.
  static func vaultIcon(from record: CKRecord) -> VaultIcon? {
    let infoRecord = VaultInfoRecord(record: record)
    guard
      let rawKind = infoRecord.iconKindRawValue,
      let kind = VaultIcon.Kind(rawValue: rawKind),
      let value = infoRecord.iconValue,
      value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    else {
      return nil
    }
    return VaultIcon(kind: kind, value: value)
  }

  static func update(_ card: Card, from record: CKRecord) {
    let cardRecord = CardRecord(record: record)
    if record[CardKey.kind] != nil {
      card.kindRawValue = cardRecord.kindRawValue
    }
    card.body = cardRecord.body
    card.completedAt = card.kind == .todo ? cardRecord.completedAt : nil
    if record[CardKey.createdAt] != nil {
      card.createdAt = cardRecord.createdAt
    }
    if record[CardKey.updatedAt] != nil {
      card.updatedAt = cardRecord.updatedAt
    }
    card.location = cardRecord.location
  }

  static func update(_ edge: CardEdge, from record: CKRecord) {
    let edgeRecord = CardEdgeRecord(record: record)
    // A live remote record recreates a placement that was previously retained
    // as locally deleted. `deletedAt` itself is intentionally not transported.
    edge.deletedAt = nil
    if record[CardEdgeKey.cardID] != nil,
      let cardID = UUID(uuidString: edgeRecord.cardIDRawValue)
    {
      edge.setCardReferenceID(cardID)
    }
    edge.setParentEdgeReferenceID(
      edgeRecord.parentEdgeIDRawValue.flatMap(UUID.init(uuidString:))
    )
    edge.sortIndex = edgeRecord.sortIndex
    edge.layout = edgeRecord.layout
    if record[CardEdgeKey.createdAt] != nil {
      edge.createdAt = edgeRecord.createdAt
    }
    if record[CardEdgeKey.updatedAt] != nil {
      edge.updatedAt = edgeRecord.updatedAt
    }
  }

  static func update(_ attachment: Attachment, from record: CKRecord) {
    let attachmentRecord = AttachmentRecord(record: record)
    if record[AttachmentKey.cardID] != nil,
      let cardID = UUID(uuidString: attachmentRecord.cardIDRawValue)
    {
      attachment.setCardReferenceID(cardID)
    }
    if record[AttachmentKey.kind] != nil {
      attachment.kindRawValue = attachmentRecord.kindRawValue
    }
    attachment.byteSize = attachmentRecord.byteSize
    if record[AttachmentKey.primaryResourceID] != nil,
      let primaryResourceID = UUID(uuidString: attachmentRecord.primaryResourceIDRawValue)
    {
      attachment.setPrimaryResourceReferenceID(primaryResourceID)
    }
    attachment.thumbnail = attachmentRecord.thumbnail
    if record[AttachmentKey.createdAt] != nil {
      attachment.createdAt = attachmentRecord.createdAt
    }
  }

  static func update(_ resource: AttachmentResource, from record: CKRecord) {
    let resourceRecord = AttachmentResourceRecord(record: record)
    if record[AttachmentResourceKey.attachmentID] != nil,
      let attachmentID = UUID(uuidString: resourceRecord.attachmentIDRawValue)
    {
      resource.setAttachmentReferenceID(attachmentID)
    }
    if record[AttachmentResourceKey.role] != nil {
      resource.roleRawValue = resourceRecord.roleRawValue
    }
    resource.byteSize = resourceRecord.byteSize
    resource.contentType = resourceRecord.contentType
    resource.pixelWidth = resourceRecord.pixelWidth
    resource.pixelHeight = resourceRecord.pixelHeight
    resource.duration = resourceRecord.duration
    resource.isHDR = resourceRecord.isHDR
    resource.colorSpaceName = resourceRecord.colorSpaceName
    if record[AttachmentResourceKey.createdAt] != nil {
      resource.createdAt = resourceRecord.createdAt
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
