import Foundation
import SwiftData

/// Transport bookkeeping for one CloudKit record, stored next to the content it
/// describes so vault reset/repair stays vault-scoped.
///
/// `CKRecord` is transport shape, not persistence: instead of archiving whole
/// records, each row keeps only the encoded *system fields* (identity, change
/// tag, share linkage) needed to re-send with a valid change tag and to detect
/// conflicts. User fields are always re-derived from the live row at send time.
///
/// Existence of a row also means "the server has (or had) this record" — the
/// outbox uses that to decide whether a local delete needs a remote tombstone.
@Model
public final class SyncMetadata {

  /// CloudKit record name (== the model row's UUID string).
  @Attribute(.unique)
  public var recordName: String

  /// CloudKit record type (`VaultRecordType` raw value).
  public var recordType: String

  /// `CKRecord` system fields encoded via `encodeSystemFields(with:)`.
  public var systemFieldsData: Data

  public var lastSyncedAt: Date

  public init(
    recordName: String,
    recordType: String,
    systemFieldsData: Data,
    lastSyncedAt: Date = Date()
  ) {
    self.recordName = recordName
    self.recordType = recordType
    self.systemFieldsData = systemFieldsData
    self.lastSyncedAt = lastSyncedAt
  }
}
