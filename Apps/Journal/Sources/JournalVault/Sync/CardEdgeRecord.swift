import CloudKit
import CloudKitSupport
import Foundation

/// CloudKit transport wrapper for the `CardEdge` record type.
///
/// Relationship identifiers are stored as raw record-name strings here. UUID
/// validation and tree repair remain mapper/domain responsibilities.
@CloudKitRecord(type: "CardEdge")
final class CardEdgeRecord {
  @CKField("cardID", .string, required: true)
  var cardIDRawValue: String

  @CKField("parentEdgeID", .string)
  var parentEdgeIDRawValue: String?

  @CKField("sortIndex", .int, default: 0)
  var sortIndex: Int

  @CKField("layout", .data)
  var layout: Data?

  @CKField("createdAt", .date, required: true)
  var createdAt: Date

  @CKField("updatedAt", .date, required: true)
  var updatedAt: Date
}
