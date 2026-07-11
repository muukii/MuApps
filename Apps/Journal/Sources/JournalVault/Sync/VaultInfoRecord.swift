import CloudKit
import CloudKitSupport
import Foundation

/// CloudKit transport wrapper for the `VaultInfo` record type.
///
/// This object owns only the CloudKit payload shape. Domain-level display
/// metadata policy and catalog mirroring stay in the vault store/runtime layers.
@CloudKitRecord(type: "VaultInfo")
final class VaultInfoRecord {
  @CKField("title", .string, default: "")
  var title: String

  @CKField("iconKind", .string)
  var iconKindRawValue: String?

  @CKField("iconValue", .string)
  var iconValue: String?

  @CKField("createdAt", .date, required: true)
  var createdAt: Date

  @CKField("updatedAt", .date, required: true)
  var updatedAt: Date
}
