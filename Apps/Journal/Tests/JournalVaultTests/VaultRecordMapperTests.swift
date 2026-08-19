import CloudKit
import Foundation
import Testing

@testable import JournalVault

struct VaultRecordMapperTests {

  private func makeRecord(type: VaultRecordType, recordName: String) -> CKRecord {
    CKRecord(
      recordType: type.rawValue,
      recordID: CKRecord.ID(recordName: recordName, zoneID: VaultID().zoneID())
    )
  }

  @Test
  func cardFields_roundTrip() {
    let completedAt = Date(timeIntervalSince1970: 1_700_000_120)
    let card = Card(
      kind: .todo,
      body: "hello",
      completedAt: completedAt,
      location: Coordinate(latitude: 35.0, longitude: 139.7)
    )
    let record = makeRecord(type: .card, recordName: card.id.uuidString)
    VaultRecordMapper.applyFields(of: card, to: record)

    let imported = Card(id: card.id)
    VaultRecordMapper.update(imported, from: record)

    #expect(imported.kind == .todo)
    #expect(imported.body == "hello")
    #expect(imported.completedAt == completedAt)
    #expect(imported.isCompleted)
    #expect(imported.createdAt == card.createdAt)
    #expect(imported.updatedAt == card.updatedAt)
    #expect(imported.location?.latitude == 35.0)
    #expect(imported.location?.longitude == 139.7)
  }

  @Test
  func cardKind_unknownRawValueSurvivesRoundTrip() {
    // A kind from a newer app version must round-trip through this build
    // unchanged, not collapse to "unknown" on the server.
    let card = Card()
    card.kindRawValue = "spatialVideo"
    let record = makeRecord(type: .card, recordName: card.id.uuidString)
    VaultRecordMapper.applyFields(of: card, to: record)

    let imported = Card(id: card.id)
    VaultRecordMapper.update(imported, from: record)

    #expect(imported.kindRawValue == "spatialVideo")
    #expect(imported.kind == .unknown)
  }

  @Test
  func cardFields_linkRoundTrip() {
    let card = Card(kind: .link, body: "https://example.com/article")
    let record = makeRecord(type: .card, recordName: card.id.uuidString)
    VaultRecordMapper.applyFields(of: card, to: record)

    let imported = Card(id: card.id)
    VaultRecordMapper.update(imported, from: record)

    #expect(imported.kind == .link)
    #expect(imported.body == "https://example.com/article")
  }

  @Test
  func cardImport_missingFieldsKeepsTolerantFallbacks() {
    let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
    let updatedAt = Date(timeIntervalSince1970: 1_700_000_060)
    let card = Card(
      kind: .todo,
      body: "local body",
      completedAt: Date(timeIntervalSince1970: 1_700_000_030),
      createdAt: createdAt,
      updatedAt: updatedAt,
      location: Coordinate(latitude: 35.0, longitude: 139.7)
    )
    let record = makeRecord(type: .card, recordName: card.id.uuidString)

    VaultRecordMapper.update(card, from: record)

    #expect(card.kind == .todo)
    #expect(card.body == "")
    #expect(card.completedAt == nil)
    #expect(card.createdAt == createdAt)
    #expect(card.updatedAt == updatedAt)
    #expect(card.location == nil)
  }

  @Test
  func cardEdgeFields_roundTrip() {
    let parentID = UUID()
    let edge = CardEdge(
      cardID: UUID(),
      parentEdgeID: parentID,
      sortIndex: 4,
      layout: Data([0x01])
    )
    let record = makeRecord(type: .cardEdge, recordName: edge.id.uuidString)
    VaultRecordMapper.applyFields(of: edge, to: record)

    let imported = CardEdge(id: edge.id, cardID: UUID())
    VaultRecordMapper.update(imported, from: record)

    #expect(imported.cardID == edge.cardID)
    #expect(imported.parentEdgeID == parentID)
    #expect(imported.sortIndex == 4)
    #expect(imported.layout == Data([0x01]))
  }

  @Test
  func cardEdgeFields_nilParentImportsAsRoot() {
    let edge = CardEdge(cardID: UUID(), parentEdgeID: nil)
    let record = makeRecord(type: .cardEdge, recordName: edge.id.uuidString)
    VaultRecordMapper.applyFields(of: edge, to: record)

    // Start from a non-nil parent to prove import clears it.
    let imported = CardEdge(id: edge.id, cardID: UUID(), parentEdgeID: UUID())
    VaultRecordMapper.update(imported, from: record)

    #expect(imported.parentEdgeID == nil)
  }

  @Test
  func cardEdgeImport_missingFieldsKeepsTolerantFallbacks() {
    let cardID = UUID()
    let parentID = UUID()
    let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
    let updatedAt = Date(timeIntervalSince1970: 1_700_000_060)
    let edge = CardEdge(
      cardID: cardID,
      parentEdgeID: parentID,
      sortIndex: 8,
      layout: Data([0x0C]),
      createdAt: createdAt,
      updatedAt: updatedAt
    )
    let record = makeRecord(type: .cardEdge, recordName: edge.id.uuidString)

    VaultRecordMapper.update(edge, from: record)

    #expect(edge.cardID == cardID)
    #expect(edge.parentEdgeID == nil)
    #expect(edge.sortIndex == 0)
    #expect(edge.layout == nil)
    #expect(edge.createdAt == createdAt)
    #expect(edge.updatedAt == updatedAt)
  }

  @Test
  func attachmentFields_roundTrip() {
    let attachment = JournalVault.Attachment(
      cardID: UUID(),
      kind: .doodle,
      byteSize: 128,
      primaryResourceID: UUID(),
      thumbnail: Data([0x0A, 0x0B])
    )
    let record = makeRecord(type: .attachment, recordName: attachment.id.uuidString)
    VaultRecordMapper.applyFields(of: attachment, to: record)

    let imported = JournalVault.Attachment(
      id: attachment.id,
      cardID: UUID(),
      primaryResourceID: UUID()
    )
    VaultRecordMapper.update(imported, from: record)

    #expect(imported.cardID == attachment.cardID)
    #expect(imported.kind == .doodle)
    #expect(imported.byteSize == 128)
    #expect(imported.primaryResourceID == attachment.primaryResourceID)
    #expect(imported.thumbnail == Data([0x0A, 0x0B]))
  }

  @Test
  func attachmentImport_missingFieldsKeepsTolerantFallbacks() {
    let cardID = UUID()
    let primaryResourceID = UUID()
    let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
    let attachment = JournalVault.Attachment(
      cardID: cardID,
      kind: .audio,
      byteSize: 256,
      primaryResourceID: primaryResourceID,
      thumbnail: Data([0x0D]),
      createdAt: createdAt
    )
    let record = makeRecord(type: .attachment, recordName: attachment.id.uuidString)

    VaultRecordMapper.update(attachment, from: record)

    #expect(attachment.cardID == cardID)
    #expect(attachment.kind == .audio)
    #expect(attachment.byteSize == 0)
    #expect(attachment.primaryResourceID == primaryResourceID)
    #expect(attachment.thumbnail == nil)
    #expect(attachment.createdAt == createdAt)
  }

  @Test
  func attachmentResourceFields_roundTrip() {
    let resource = JournalVault.AttachmentResource(
      attachmentID: UUID(),
      role: .originalImage,
      byteSize: 512,
      contentType: "public.jpeg",
      pixelWidth: 640,
      pixelHeight: 480,
      duration: 1.25,
      waveformData: Data([0x01, 0x02, 0x03]),
      isHDR: true,
      colorSpaceName: "Display P3"
    )
    let record = makeRecord(type: .attachmentResource, recordName: resource.id.uuidString)
    VaultRecordMapper.applyFields(of: resource, assetFileURL: nil, to: record)

    let imported = JournalVault.AttachmentResource(
      id: resource.id,
      attachmentID: UUID(),
      role: .unknown
    )
    VaultRecordMapper.update(imported, from: record)

    #expect(imported.attachmentID == resource.attachmentID)
    #expect(imported.role == .originalImage)
    #expect(imported.byteSize == 512)
    #expect(imported.contentType == "public.jpeg")
    #expect(imported.pixelWidth == 640)
    #expect(imported.pixelHeight == 480)
    #expect(imported.duration == 1.25)
    #expect(imported.waveformData == Data([0x01, 0x02, 0x03]))
    #expect(imported.isHDR)
    #expect(imported.colorSpaceName == "Display P3")
    #expect(record[VaultRecordMapper.AttachmentResourceKey.file] == nil)
  }

  @Test
  func attachmentResourceImport_missingFieldsKeepsTolerantFallbacks() {
    let attachmentID = UUID()
    let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
    let resource = JournalVault.AttachmentResource(
      attachmentID: attachmentID,
      role: .audio,
      byteSize: 512,
      contentType: "public.mpeg-4-audio",
      pixelWidth: 320,
      pixelHeight: 200,
      duration: 3.5,
      waveformData: Data([0xFF]),
      isHDR: true,
      colorSpaceName: "Display P3",
      createdAt: createdAt
    )
    let record = makeRecord(type: .attachmentResource, recordName: resource.id.uuidString)

    VaultRecordMapper.update(resource, from: record)

    #expect(resource.attachmentID == attachmentID)
    #expect(resource.role == .audio)
    #expect(resource.byteSize == 0)
    #expect(resource.contentType == nil)
    #expect(resource.pixelWidth == nil)
    #expect(resource.pixelHeight == nil)
    #expect(resource.duration == nil)
    #expect(resource.waveformData == nil)
    #expect(!resource.isHDR)
    #expect(resource.colorSpaceName == nil)
    #expect(resource.createdAt == createdAt)
  }

  @Test
  func activityFields_roundTripPreservesUnknownKindAndTopology() throws {
    let subjectEdgeID = UUID()
    let rootEdgeID = UUID()
    let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
    let activity = VaultActivity(
      kindRawValue: "futureActivityKind",
      subjectEdgeID: subjectEdgeID,
      rootEdgeID: rootEdgeID,
      createdAt: createdAt
    )
    let record = makeRecord(type: .activity, recordName: activity.recordName)
    VaultRecordMapper.applyFields(of: activity, to: record)

    let imported = try #require(VaultRecordMapper.activity(id: activity.id, from: record))

    #expect(imported.id == activity.id)
    #expect(imported.kindRawValue == "futureActivityKind")
    #expect(imported.kind == .unknown("futureActivityKind"))
    #expect(imported.subjectEdgeID == subjectEdgeID)
    #expect(imported.rootEdgeID == rootEdgeID)
    #expect(imported.createdAt == createdAt)
  }

  @Test
  func activityImport_rejectsMissingRequiredFields() {
    let record = makeRecord(type: .activity, recordName: UUID().uuidString)
    record[VaultRecordMapper.VaultActivityKey.kindRawValue] = "contentAdded"

    #expect(VaultRecordMapper.activity(id: UUID(), from: record) == nil)
  }

  @Test
  func notificationPulseFields_roundTripPreservesUnknownKind() {
    let updatedAt = Date(timeIntervalSince1970: 1_700_000_000)
    let source = VaultNotificationPulse(
      latestActivityRecordName: UUID().uuidString,
      kind: .unknown("futureActivityKind"),
      updatedAt: updatedAt
    )
    let record = makeRecord(type: .notificationPulse, recordName: source.recordName)
    VaultRecordMapper.applyFields(of: source, to: record)

    let imported = VaultNotificationPulse(
      latestActivityRecordName: "old-activity",
      kind: .contentAdded,
      updatedAt: .distantPast
    )
    VaultRecordMapper.update(imported, from: record)

    #expect(imported.recordName == VaultNotificationPulse.fixedRecordName)
    #expect(imported.latestActivityRecordName == source.latestActivityRecordName)
    #expect(imported.kindRawValue == "futureActivityKind")
    #expect(imported.kind == .unknown("futureActivityKind"))
    #expect(imported.updatedAt == updatedAt)
  }

  @Test
  func vaultInfoFields_roundTrip() {
    let icon = VaultIcon.emoji("\u{1F5FE}")
    let info = VaultInfo(vaultID: UUID(), title: "Trip", icon: icon)
    let record = makeRecord(type: .vaultInfo, recordName: info.vaultID.uuidString)
    VaultRecordMapper.applyFields(of: info, to: record)

    let imported = VaultInfo(vaultID: info.vaultID, title: "")
    VaultRecordMapper.update(imported, from: record)

    #expect(imported.title == "Trip")
    #expect(imported.icon == icon)
    #expect(imported.createdAt == info.createdAt)
  }

  @Test
  func vaultInfoImport_missingFieldsKeepsTolerantFallbacks() {
    let createdAt = Date(timeIntervalSince1970: 1_700_000_000)
    let updatedAt = Date(timeIntervalSince1970: 1_700_000_060)
    let info = VaultInfo(
      vaultID: UUID(),
      title: "Existing",
      icon: .systemImage("book.closed"),
      createdAt: createdAt,
      updatedAt: updatedAt
    )
    let record = makeRecord(type: .vaultInfo, recordName: info.vaultID.uuidString)

    VaultRecordMapper.update(info, from: record)

    #expect(info.title == "")
    #expect(info.icon == .systemImage("book.closed"))
    #expect(info.createdAt == createdAt)
    #expect(info.updatedAt == updatedAt)
  }

  @Test
  func systemFields_encodeDecodePreservesIdentity() {
    let record = makeRecord(type: .card, recordName: UUID().uuidString)
    record[VaultRecordMapper.CardKey.body] = "user data"

    let data = VaultRecordMapper.encodeSystemFields(of: record)
    let shell = VaultRecordMapper.record(fromSystemFields: data)

    #expect(shell?.recordID == record.recordID)
    #expect(shell?.recordType == record.recordType)
    // System fields only — user fields are re-derived from the row at send time.
    #expect(shell?[VaultRecordMapper.CardKey.body] == nil)
  }
}
