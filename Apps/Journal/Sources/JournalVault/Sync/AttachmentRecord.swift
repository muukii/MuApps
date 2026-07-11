import CloudKit
import CloudKitSupport
import Foundation

/// CloudKit transport wrapper for the `Attachment` record type.
///
/// Attachment relationships are represented as record-name strings. The
/// importer decides whether those strings are valid enough to update local
/// SwiftData relationships.
@CloudKitRecord(type: "Attachment")
final class AttachmentRecord {
  @CKField("cardID", .string, required: true)
  var cardIDRawValue: String

  @CKField("kind", .string, required: true)
  var kindRawValue: String

  @CKField("byteSize", .int, default: 0)
  var byteSize: Int

  @CKField("primaryResourceID", .string, required: true)
  var primaryResourceIDRawValue: String

  @CKField("thumbnail", .data)
  var thumbnail: Data?

  @CKField("createdAt", .date, required: true)
  var createdAt: Date
}
