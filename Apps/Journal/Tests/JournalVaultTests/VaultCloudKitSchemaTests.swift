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
        VaultRecordMapper.VaultInfoKey.iconKind,
        VaultRecordMapper.VaultInfoKey.iconValue,
        VaultRecordMapper.VaultInfoKey.createdAt,
        VaultRecordMapper.VaultInfoKey.updatedAt,
      ],
      .card: [
        VaultRecordMapper.CardKey.kind,
        VaultRecordMapper.CardKey.body,
        VaultRecordMapper.CardKey.completedAt,
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
        VaultRecordMapper.AttachmentResourceKey.waveformData,
        VaultRecordMapper.AttachmentResourceKey.isHDR,
        VaultRecordMapper.AttachmentResourceKey.colorSpaceName,
        VaultRecordMapper.AttachmentResourceKey.createdAt,
        VaultRecordMapper.AttachmentResourceKey.file,
      ],
      .activity: [
        VaultRecordMapper.VaultActivityKey.kindRawValue,
        VaultRecordMapper.VaultActivityKey.subjectEdgeID,
        VaultRecordMapper.VaultActivityKey.rootEdgeID,
        VaultRecordMapper.VaultActivityKey.createdAt,
      ],
      .notificationPulse: [
        VaultRecordMapper.VaultNotificationPulseKey.latestActivityRecordName,
        VaultRecordMapper.VaultNotificationPulseKey.kindRawValue,
        VaultRecordMapper.VaultNotificationPulseKey.updatedAt,
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
        $0.storage
          == .optionalRecordNameString(
            fieldName: VaultRecordMapper.CardEdgeKey.parentEdgeID
          )
      }
    )
  }

  @Test
  func activityCreatedAt_isDeclaredSortableForRetention() {
    let descriptor = VaultCloudKitSchema.descriptor(for: .activity)

    #expect(
      descriptor.field(named: VaultRecordMapper.VaultActivityKey.createdAt)?.indexExpectation
        == .sortable
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
    let completedAt = Date(timeIntervalSince1970: 1_725_000_030)

    wrapper.kindRawValue = Card.Kind.todo.rawValue
    wrapper.body = "hello"
    wrapper.completedAt = completedAt
    wrapper.createdAt = createdAt
    wrapper.updatedAt = updatedAt
    wrapper.location = Coordinate(latitude: 35.0, longitude: 139.7)

    #expect(CardRecord.recordType == VaultRecordType.card.rawValue)
    #expect(CardRecord.descriptor.recordType == VaultRecordType.card.rawValue)
    #expect(
      CardRecord.descriptor.field(named: VaultRecordMapper.CardKey.body)?.defaultValueDescription
        == "")
    #expect(wrapper.record.recordType == VaultRecordType.card.rawValue)
    #expect(wrapper.record[VaultRecordMapper.CardKey.kind] as? String == Card.Kind.todo.rawValue)
    #expect(wrapper.record[VaultRecordMapper.CardKey.body] as? String == "hello")
    #expect(wrapper.record[VaultRecordMapper.CardKey.completedAt] as? Date == completedAt)
    #expect(wrapper.record[VaultRecordMapper.CardKey.createdAt] as? Date == createdAt)
    #expect(wrapper.record[VaultRecordMapper.CardKey.updatedAt] as? Date == updatedAt)

    let imported = CardRecord(record: wrapper.record)
    #expect(imported.kindRawValue == Card.Kind.todo.rawValue)
    #expect(imported.body == "hello")
    #expect(imported.completedAt == completedAt)
    #expect(imported.createdAt == createdAt)
    #expect(imported.updatedAt == updatedAt)
    #expect(imported.location?.latitude == 35.0)
    #expect(imported.location?.longitude == 139.7)
  }

  @Test
  func activityAndPulse_macroGeneratedWrappersBridgeThroughCKRecord() {
    let zoneID = VaultID().zoneID()
    let activityRecordID = CKRecord.ID(recordName: UUID().uuidString, zoneID: zoneID)
    let subjectEdgeID = UUID()
    let rootEdgeID = UUID()
    let createdAt = Date(timeIntervalSince1970: 1_725_000_000)
    let activity = VaultActivityRecord(recordID: activityRecordID)
    activity.kindRawValue = "futureActivityKind"
    activity.subjectEdgeIDRawValue = subjectEdgeID.uuidString
    activity.rootEdgeIDRawValue = rootEdgeID.uuidString
    activity.createdAt = createdAt

    #expect(VaultActivityRecord.recordType == VaultRecordType.activity.rawValue)
    #expect(
      activity.record[VaultRecordMapper.VaultActivityKey.kindRawValue] as? String
        == "futureActivityKind"
    )
    #expect(activity.record[VaultRecordMapper.VaultActivityKey.createdAt] as? Date == createdAt)

    let pulseRecordID = CKRecord.ID(
      recordName: VaultNotificationPulse.fixedRecordName,
      zoneID: zoneID
    )
    let pulse = VaultNotificationPulseRecord(recordID: pulseRecordID)
    pulse.latestActivityRecordName = activityRecordID.recordName
    pulse.kindRawValue = "futureActivityKind"
    pulse.updatedAt = createdAt

    #expect(
      VaultNotificationPulseRecord.recordType == VaultRecordType.notificationPulse.rawValue
    )
    #expect(
      pulse.record[VaultRecordMapper.VaultNotificationPulseKey.latestActivityRecordName] as? String
        == activityRecordID.recordName
    )
    #expect(
      pulse.record[VaultRecordMapper.VaultNotificationPulseKey.updatedAt] as? Date == createdAt
    )
  }
}
