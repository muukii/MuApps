import CloudKit
import CloudKitSupport
import Foundation

/// CloudKit transport wrapper for the vault zone's mutable notification pulse.
///
/// There is exactly one valid record name: `notification-pulse`. The wrapper
/// intentionally carries only generic attention metadata; it never duplicates
/// Card content or acts as a reliable delivery cursor.
@CloudKitRecord(type: "VaultNotificationPulse")
final class VaultNotificationPulseRecord {
  @CKField("latestActivityRecordName", .string, required: true)
  var latestActivityRecordName: String

  @CKField("kindRawValue", .string, required: true)
  var kindRawValue: String

  @CKField("updatedAt", .date, required: true)
  var updatedAt: Date
}
