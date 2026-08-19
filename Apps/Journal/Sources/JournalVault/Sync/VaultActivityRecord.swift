import CloudKit
import CloudKitSupport
import Foundation

/// CloudKit transport wrapper for one immutable ``VaultActivity`` history row.
///
/// The record's UUID name is its identity; the wrapper only describes fields
/// that are safe to serialize. Incoming code creates a local snapshot for a
/// previously unseen record and never mutates an existing Activity's fields.
@CloudKitRecord(type: "VaultActivity")
final class VaultActivityRecord {
  @CKField("kindRawValue", .string, required: true)
  var kindRawValue: String

  @CKField("subjectEdgeID", .string)
  var subjectEdgeIDRawValue: String?

  @CKField("rootEdgeID", .string)
  var rootEdgeIDRawValue: String?

  @CKField("createdAt", .date, required: true)
  var createdAt: Date
}
