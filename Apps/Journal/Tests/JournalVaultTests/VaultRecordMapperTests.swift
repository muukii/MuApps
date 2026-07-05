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
    let card = Card(
      kind: .text,
      body: "hello",
      location: Coordinate(latitude: 35.0, longitude: 139.7)
    )
    let record = makeRecord(type: .card, recordName: card.id.uuidString)
    VaultRecordMapper.applyFields(of: card, to: record)

    let imported = Card(id: card.id)
    VaultRecordMapper.update(imported, from: record)

    #expect(imported.kind == .text)
    #expect(imported.body == "hello")
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
  func attachmentResourceFields_roundTrip() {
    let resource = JournalVault.AttachmentResource(
      attachmentID: UUID(),
      role: .originalImage,
      byteSize: 512,
      contentType: "public.jpeg",
      pixelWidth: 640,
      pixelHeight: 480,
      duration: 1.25,
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
    #expect(imported.isHDR)
    #expect(imported.colorSpaceName == "Display P3")
    #expect(record[VaultRecordMapper.AttachmentResourceKey.file] == nil)
  }

  @Test
  func vaultInfoFields_roundTrip() {
    let info = VaultInfo(vaultID: UUID(), title: "Trip")
    let record = makeRecord(type: .vaultInfo, recordName: info.vaultID.uuidString)
    VaultRecordMapper.applyFields(of: info, to: record)

    let imported = VaultInfo(vaultID: info.vaultID, title: "")
    VaultRecordMapper.update(imported, from: record)

    #expect(imported.title == "Trip")
    #expect(imported.createdAt == info.createdAt)
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
