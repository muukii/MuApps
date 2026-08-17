import CloudKit
import CloudKitSupport
import Foundation

/// CloudKit transport wrapper for the `AttachmentResource` record type.
///
/// File asset replacement is intentionally controlled by the mapper: absence of
/// a local upload file should leave the remote `file` field untouched.
@CloudKitRecord(type: "AttachmentResource")
final class AttachmentResourceRecord {
  @CKField("attachmentID", .string, required: true)
  var attachmentIDRawValue: String

  @CKField("role", .string, required: true)
  var roleRawValue: String

  @CKField("byteSize", .int, default: 0)
  var byteSize: Int

  @CKField("contentType", .string)
  var contentType: String?

  @CKField("pixelWidth", .int)
  var pixelWidth: Int?

  @CKField("pixelHeight", .int)
  var pixelHeight: Int?

  @CKField("duration", .double)
  var duration: Double?

  @CKField("waveformData", .data)
  var waveformData: Data?

  @CKField("isHDR", .bool, default: false)
  var isHDR: Bool

  @CKField("colorSpaceName", .string)
  var colorSpaceName: String?

  @CKField("createdAt", .date, required: true)
  var createdAt: Date

  @CKField("file", .asset)
  var file: CKAsset?
}
