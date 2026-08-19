import Foundation
import SwiftData

/// The one mutable notification-trigger record stored in each vault zone.
///
/// Activity is immutable history. Pulse is deliberately separate, mutable
/// transport state so future Activity retention deletes cannot be observed as
/// participant-visible notification events. A vault has at most one Pulse row.
@Model
public final class VaultNotificationPulse {

  /// Fixed CloudKit record identity for the singleton Pulse in a vault zone.
  ///
  /// This is distinct from the persisted ``recordName`` property so callers
  /// can name both the fixed identity and an instance's stored key without
  /// relying on an ambiguous static-versus-instance member lookup.
  public static let fixedRecordName = "notification-pulse"

  /// Canonical CloudKit record type name.
  public static let recordType = VaultRecordType.notificationPulse.rawValue

  /// Local uniqueness key and CloudKit record name for this singleton.
  ///
  /// The value is always ``fixedRecordName``; persisting it makes duplicate
  /// local rows impossible even when the store is reopened between authored
  /// actions.
  @Attribute(.unique)
  public private(set) var recordName: String

  /// CloudKit record name of the Activity that most recently re-armed this
  /// Pulse. It is a generic attention hint, not a strict notification cursor.
  public var latestActivityRecordName: String

  /// Raw Activity kind used by later notification and routing projections.
  /// Unknown values stay intact for forward-compatible transport.
  public var kindRawValue: String

  /// Time this mutable record was most recently updated by an eligible action.
  public var updatedAt: Date

  public init(
    latestActivityRecordName: String,
    kind: VaultActivity.Kind,
    updatedAt: Date = Date()
  ) {
    recordName = Self.fixedRecordName
    self.latestActivityRecordName = latestActivityRecordName
    kindRawValue = kind.rawValue
    self.updatedAt = updatedAt
  }

  /// Known Activity kind, preserving unrecognized future raw values.
  public var kind: VaultActivity.Kind { .init(rawValue: kindRawValue) }
}
