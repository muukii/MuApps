import CloudKitSupport
import Foundation

/// Code-owned description of the CloudKit records Journal stores per vault.
///
/// The real deployed schema still lives in CloudKit. This manifest documents
/// the app-side contract next to the mapper so reviews, tests, and future macro
/// work can reason about record types without reading every `CKRecord` subscript.
public enum VaultCloudKitSchema {
  /// Descriptors for all record types currently uploaded by the vault sync
  /// boundary.
  public static let records: [CloudKitRecordDescriptor] = [
    vaultInfo,
    card,
    cardEdge,
    attachment,
    attachmentResource,
  ]

  /// Returns the descriptor for one vault record type.
  public static func descriptor(for recordType: VaultRecordType) -> CloudKitRecordDescriptor {
    switch recordType {
    case .vaultInfo:
      vaultInfo
    case .card:
      card
    case .cardEdge:
      cardEdge
    case .attachment:
      attachment
    case .attachmentResource:
      attachmentResource
    }
  }

  /// Minimal vault metadata record stored in each custom zone.
  public static let vaultInfo = CloudKitRecordDescriptor(
    recordType: VaultRecordType.vaultInfo.rawValue,
    fields: [
      field(
        VaultRecordMapper.VaultInfoKey.title,
        .string,
        missing: .defaultValue("empty title")
      ),
      dateField(VaultRecordMapper.VaultInfoKey.createdAt),
      dateField(VaultRecordMapper.VaultInfoKey.updatedAt),
    ],
    notes: [
      "Record name is the vault UUID string.",
      "The zone-wide share preview is derived from this metadata.",
    ]
  )

  /// Captured content atom.
  public static let card = CloudKitRecordDescriptor(
    recordType: VaultRecordType.card.rawValue,
    fields: [
      field(
        VaultRecordMapper.CardKey.kind,
        .string,
        missing: .preserveExistingValue,
        notes: ["Raw card modality; unknown future values must round-trip."]
      ),
      field(
        VaultRecordMapper.CardKey.body,
        .string,
        missing: .defaultValue("empty body")
      ),
      dateField(VaultRecordMapper.CardKey.createdAt),
      dateField(VaultRecordMapper.CardKey.updatedAt),
      optionalField(
        VaultRecordMapper.CardKey.location,
        .location,
        missing: .clearValue
      ),
    ],
    notes: [
      "Record name is the card UUID string.",
      "Media payloads live in Attachment and AttachmentResource records.",
    ]
  )

  /// Placement of a card inside the vault tree.
  public static let cardEdge = CloudKitRecordDescriptor(
    recordType: VaultRecordType.cardEdge.rawValue,
    fields: [
      field(
        VaultRecordMapper.CardEdgeKey.cardID,
        .string,
        missing: .defaultValue("record name UUID placeholder")
      ),
      optionalField(
        VaultRecordMapper.CardEdgeKey.parentEdgeID,
        .string,
        missing: .clearValue
      ),
      field(
        VaultRecordMapper.CardEdgeKey.sortIndex,
        .int,
        missing: .defaultValue("0")
      ),
      optionalField(
        VaultRecordMapper.CardEdgeKey.layout,
        .data,
        missing: .clearValue
      ),
      dateField(VaultRecordMapper.CardEdgeKey.createdAt),
      dateField(VaultRecordMapper.CardEdgeKey.updatedAt),
    ],
    relationships: [
      CloudKitRelationshipDescriptor(
        sourceRecordType: VaultRecordType.cardEdge.rawValue,
        targetRecordType: VaultRecordType.card.rawValue,
        storage: .recordNameString(fieldName: VaultRecordMapper.CardEdgeKey.cardID),
        isRequired: true,
        notes: ["Plain UUID field, not `CKRecord.parent`."]
      ),
      CloudKitRelationshipDescriptor(
        sourceRecordType: VaultRecordType.cardEdge.rawValue,
        targetRecordType: VaultRecordType.cardEdge.rawValue,
        storage: .optionalRecordNameString(fieldName: VaultRecordMapper.CardEdgeKey.parentEdgeID),
        isRequired: false,
        notes: ["Nil means root edge."]
      ),
    ],
    notes: [
      "Tree semantics, cycle repair, and cascades are domain rules, not CloudKit record hierarchy.",
    ]
  )

  /// Logical media attachment for one card.
  public static let attachment = CloudKitRecordDescriptor(
    recordType: VaultRecordType.attachment.rawValue,
    fields: [
      field(
        VaultRecordMapper.AttachmentKey.cardID,
        .string,
        missing: .defaultValue("record name UUID placeholder")
      ),
      field(
        VaultRecordMapper.AttachmentKey.kind,
        .string,
        missing: .preserveExistingValue,
        notes: ["Raw attachment modality; unknown future values must round-trip."]
      ),
      field(
        VaultRecordMapper.AttachmentKey.byteSize,
        .int,
        missing: .defaultValue("0")
      ),
      field(
        VaultRecordMapper.AttachmentKey.primaryResourceID,
        .string,
        missing: .rejectRecord,
        notes: ["Required to materialize a newly imported attachment row."]
      ),
      optionalField(
        VaultRecordMapper.AttachmentKey.thumbnail,
        .data,
        missing: .clearValue
      ),
      dateField(VaultRecordMapper.AttachmentKey.createdAt),
    ],
    relationships: [
      CloudKitRelationshipDescriptor(
        sourceRecordType: VaultRecordType.attachment.rawValue,
        targetRecordType: VaultRecordType.card.rawValue,
        storage: .recordNameString(fieldName: VaultRecordMapper.AttachmentKey.cardID),
        isRequired: true
      ),
      CloudKitRelationshipDescriptor(
        sourceRecordType: VaultRecordType.attachment.rawValue,
        targetRecordType: VaultRecordType.attachmentResource.rawValue,
        storage: .recordNameString(fieldName: VaultRecordMapper.AttachmentKey.primaryResourceID),
        isRequired: true,
        notes: ["Points at the resource normal renderers should prefer."]
      ),
    ]
  )

  /// Concrete file-backed resource for an attachment.
  public static let attachmentResource = CloudKitRecordDescriptor(
    recordType: VaultRecordType.attachmentResource.rawValue,
    fields: [
      field(
        VaultRecordMapper.AttachmentResourceKey.attachmentID,
        .string,
        missing: .defaultValue("record name UUID placeholder")
      ),
      field(
        VaultRecordMapper.AttachmentResourceKey.role,
        .string,
        missing: .defaultValue("unknown role"),
        notes: ["Raw resource role; unknown future values must round-trip."]
      ),
      field(
        VaultRecordMapper.AttachmentResourceKey.byteSize,
        .int,
        missing: .defaultValue("0")
      ),
      optionalField(VaultRecordMapper.AttachmentResourceKey.contentType, .string),
      optionalField(VaultRecordMapper.AttachmentResourceKey.pixelWidth, .int),
      optionalField(VaultRecordMapper.AttachmentResourceKey.pixelHeight, .int),
      optionalField(VaultRecordMapper.AttachmentResourceKey.duration, .double),
      field(
        VaultRecordMapper.AttachmentResourceKey.isHDR,
        .bool,
        missing: .defaultValue("false")
      ),
      optionalField(VaultRecordMapper.AttachmentResourceKey.colorSpaceName, .string),
      dateField(VaultRecordMapper.AttachmentResourceKey.createdAt),
      optionalField(
        VaultRecordMapper.AttachmentResourceKey.file,
        .asset,
        missing: .preserveExistingValue,
        notes: ["Absent on upload means preserve the existing remote asset field."]
      ),
    ],
    relationships: [
      CloudKitRelationshipDescriptor(
        sourceRecordType: VaultRecordType.attachmentResource.rawValue,
        targetRecordType: VaultRecordType.attachment.rawValue,
        storage: .recordNameString(fieldName: VaultRecordMapper.AttachmentResourceKey.attachmentID),
        isRequired: true
      ),
    ],
    notes: [
      "`localFileRevision` is intentionally local-only and is not a CloudKit field.",
    ]
  )
}

// MARK: - Field helpers

extension VaultCloudKitSchema {
  private static func field(
    _ name: String,
    _ valueKind: CloudKitFieldValueKind,
    missing: CloudKitMissingFieldBehavior,
    indexExpectation: CloudKitFieldIndexExpectation = .none,
    notes: [String] = []
  ) -> CloudKitFieldDescriptor {
    CloudKitFieldDescriptor(
      name,
      valueKind: valueKind,
      isRequiredForUpload: true,
      missingFieldBehavior: missing,
      indexExpectation: indexExpectation,
      notes: notes
    )
  }

  private static func optionalField(
    _ name: String,
    _ valueKind: CloudKitFieldValueKind,
    missing: CloudKitMissingFieldBehavior = .clearValue,
    indexExpectation: CloudKitFieldIndexExpectation = .none,
    notes: [String] = []
  ) -> CloudKitFieldDescriptor {
    CloudKitFieldDescriptor(
      name,
      valueKind: valueKind,
      isRequiredForUpload: false,
      missingFieldBehavior: missing,
      indexExpectation: indexExpectation,
      notes: notes
    )
  }

  private static func dateField(_ name: String) -> CloudKitFieldDescriptor {
    field(
      name,
      .date,
      missing: .preserveExistingValue
    )
  }
}
