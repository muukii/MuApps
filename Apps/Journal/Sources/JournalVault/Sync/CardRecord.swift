import CloudKit
import CloudKitSupport
import Foundation

/// CloudKit transport wrapper for the `Card` record type.
///
/// This is not a domain model. It owns a `CKRecord` directly and should stay
/// inside the sync boundary, where mapper/import code can translate between
/// CloudKit transport shape and SwiftData-backed `Card` rows.
@CloudKitRecord(type: "Card")
final class CardRecord {
  @CKField("kind", .string, required: true)
  var kindRawValue: String

  @CKField("body", .string, default: "")
  var body: String

  @CKField("completedAt", .date)
  var completedAt: Date?

  @CKField("createdAt", .date, required: true)
  var createdAt: Date

  @CKField("updatedAt", .date, required: true)
  var updatedAt: Date

  @CKField("location", .location)
  var location: Coordinate?
}
