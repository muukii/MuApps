import CloudKit
import CloudKitSupport
import Foundation
import Testing

@testable import JournalVault

struct VaultCloudKitSchemaTests {

  @Test
  func descriptors_coverEveryVaultRecordType() {
    let describedTypes = Set(VaultCloudKitSchema.records.map(\.recordType))
    let expectedTypes = Set(VaultRecordType.allCases.map(\.rawValue))

    #expect(describedTypes == expectedTypes)
  }

  @Test
  func descriptors_useMapperFieldKeys() {
    let expectedFields: [VaultRecordType: Set<String>] = [
      .vaultInfo: [
        VaultRecordMapper.VaultInfoKey.title,
        VaultRecordMapper.VaultInfoKey.createdAt,
        VaultRecordMapper.VaultInfoKey.updatedAt,
      ],
      .card: [
        VaultRecordMapper.CardKey.kind,
        VaultRecordMapper.CardKey.body,
        VaultRecordMapper.CardKey.createdAt,
        VaultRecordMapper.CardKey.updatedAt,
        VaultRecordMapper.CardKey.location,
      ],
      .cardEdge: [
        VaultRecordMapper.CardEdgeKey.cardID,
        VaultRecordMapper.CardEdgeKey.parentEdgeID,
        VaultRecordMapper.CardEdgeKey.sortIndex,
        VaultRecordMapper.CardEdgeKey.layout,
        VaultRecordMapper.CardEdgeKey.createdAt,
        VaultRecordMapper.CardEdgeKey.updatedAt,
      ],
      .attachment: [
        VaultRecordMapper.AttachmentKey.cardID,
        VaultRecordMapper.AttachmentKey.kind,
        VaultRecordMapper.AttachmentKey.byteSize,
        VaultRecordMapper.AttachmentKey.primaryResourceID,
        VaultRecordMapper.AttachmentKey.thumbnail,
        VaultRecordMapper.AttachmentKey.createdAt,
      ],
      .attachmentResource: [
        VaultRecordMapper.AttachmentResourceKey.attachmentID,
        VaultRecordMapper.AttachmentResourceKey.role,
        VaultRecordMapper.AttachmentResourceKey.byteSize,
        VaultRecordMapper.AttachmentResourceKey.contentType,
        VaultRecordMapper.AttachmentResourceKey.pixelWidth,
        VaultRecordMapper.AttachmentResourceKey.pixelHeight,
        VaultRecordMapper.AttachmentResourceKey.duration,
        VaultRecordMapper.AttachmentResourceKey.isHDR,
        VaultRecordMapper.AttachmentResourceKey.colorSpaceName,
        VaultRecordMapper.AttachmentResourceKey.createdAt,
        VaultRecordMapper.AttachmentResourceKey.file,
      ],
    ]

    for recordType in VaultRecordType.allCases {
      let descriptor = VaultCloudKitSchema.descriptor(for: recordType)
      let expected = expectedFields[recordType] ?? []
      #expect(Set(descriptor.fields.map(\.name)) == expected)
    }
  }

  @Test
  func cardEdgeParent_isDomainFieldNotCloudKitParent() {
    let descriptor = VaultCloudKitSchema.descriptor(for: .cardEdge)

    #expect(
      descriptor.relationships.contains {
        $0.storage == .optionalRecordNameString(
          fieldName: VaultRecordMapper.CardEdgeKey.parentEdgeID
        )
      }
    )
  }

  @Test
  func cardRecord_macroGeneratedWrapperBridgesThroughCKRecord() {
    let recordID = CKRecord.ID(
      recordName: UUID().uuidString,
      zoneID: VaultID().zoneID()
    )
    let wrapper = CardRecord(recordID: recordID)
    let createdAt = Date(timeIntervalSince1970: 1_725_000_000)
    let updatedAt = Date(timeIntervalSince1970: 1_725_000_060)

    wrapper.kindRawValue = Card.Kind.text.rawValue
    wrapper.body = "hello"
    wrapper.createdAt = createdAt
    wrapper.updatedAt = updatedAt
    wrapper.location = Coordinate(latitude: 35.0, longitude: 139.7)

    #expect(CardRecord.recordType == VaultRecordType.card.rawValue)
    #expect(CardRecord.descriptor.recordType == VaultRecordType.card.rawValue)
    #expect(CardRecord.descriptor.field(named: VaultRecordMapper.CardKey.body)?.defaultValueDescription == "")
    #expect(wrapper.record.recordType == VaultRecordType.card.rawValue)
    #expect(wrapper.record[VaultRecordMapper.CardKey.kind] as? String == Card.Kind.text.rawValue)
    #expect(wrapper.record[VaultRecordMapper.CardKey.body] as? String == "hello")
    #expect(wrapper.record[VaultRecordMapper.CardKey.createdAt] as? Date == createdAt)
    #expect(wrapper.record[VaultRecordMapper.CardKey.updatedAt] as? Date == updatedAt)

    let imported = CardRecord(record: wrapper.record)
    #expect(imported.kindRawValue == Card.Kind.text.rawValue)
    #expect(imported.body == "hello")
    #expect(imported.createdAt == createdAt)
    #expect(imported.updatedAt == updatedAt)
    #expect(imported.location?.latitude == 35.0)
    #expect(imported.location?.longitude == 139.7)
  }
}
