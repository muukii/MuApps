import Foundation
import SwiftData

/// Outbox row: a local change that still has to reach CloudKit.
///
/// Written in the **same SwiftData transaction** as the content change it
/// describes, so a local mutation can never exist without its pending upload
/// (and vice versa). At most one row exists per record; a newer change to the
/// same record re-arms the existing row.
///
/// `CKSyncEngine` keeps its own persisted pending-change set; these rows are
/// the vault-scoped durable source of truth used to (re)seed it, and they
/// survive engine state resets and vault-level repair.
@Model
public final class PendingMutation {

  /// CloudKit record name (== the model row's UUID string).
  @Attribute(.unique)
  public var recordName: String

  /// CloudKit record type (`VaultRecordType` raw value).
  public var recordType: String

  public var kind: Kind

  /// When the change was (re)enqueued. Compared against `stagedAt` to decide
  /// whether a send success may clear the row.
  public var enqueuedAt: Date

  /// Set when the change was handed to an outgoing batch. A row is cleared on
  /// send success only if it wasn't re-enqueued after staging
  /// (`enqueuedAt <= stagedAt`), so an edit made while an upload is in flight
  /// is never lost.
  public var stagedAt: Date?

  public init(
    recordName: String,
    recordType: String,
    kind: Kind,
    enqueuedAt: Date = Date(),
    stagedAt: Date? = nil
  ) {
    self.recordName = recordName
    self.recordType = recordType
    self.kind = kind
    self.enqueuedAt = enqueuedAt
    self.stagedAt = stagedAt
  }
}

// MARK: - Kind

extension PendingMutation {

  public enum Kind: String, Codable, Sendable {
    /// Upload the row's current state (create or update — CloudKit doesn't
    /// distinguish).
    case save

    /// Delete the record remotely. The local row is already gone; this
    /// tombstone carries everything the delete needs.
    case delete
  }
}
