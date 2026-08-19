import Foundation
import SwiftData

/// One immutable, user-meaningful action recorded in a vault's durable history.
///
/// This is not a low-level CloudKit change log. A single authored action can
/// create several Cards, edges, and media rows while producing exactly one
/// activity. Activity rows remain after the referenced content is deleted so a
/// future history UI can safely fall back to the action kind and timestamp.
@Model
public final class VaultActivity {

  /// Stable identity of this logical action.
  ///
  /// The UUID string is also the CloudKit record name. The value must never be
  /// regenerated while the activity exists, because pending upload and future
  /// Shared with You delivery both use it as their idempotency key.
  @Attribute(.unique)
  public private(set) var id: UUID

  /// Raw action kind retained verbatim for forward-compatible CloudKit round
  /// trips. Read ``kind`` for the known-domain projection.
  public private(set) var kindRawValue: String

  /// Placement directly created by the action, if that placement can be
  /// represented locally. A future imported or legacy activity may omit it.
  public private(set) var subjectEdgeID: UUID?

  /// Root placement that owns ``subjectEdgeID``'s thread, if known.
  ///
  /// Root posts set this to the same value as ``subjectEdgeID``. Keeping it as
  /// a stable ID instead of a SwiftData relationship lets history outlive
  /// deleted content and tolerate out-of-order imports.
  public private(set) var rootEdgeID: UUID?

  /// Time at which the user performed the logical action, including offline
  /// writes. It is intentionally distinct from eventual CloudKit save time.
  public private(set) var createdAt: Date

  public init(
    id: UUID = UUID(),
    kind: Kind = .contentAdded,
    subjectEdgeID: UUID? = nil,
    rootEdgeID: UUID? = nil,
    createdAt: Date = Date()
  ) {
    self.id = id
    kindRawValue = kind.rawValue
    self.subjectEdgeID = subjectEdgeID
    self.rootEdgeID = rootEdgeID
    self.createdAt = createdAt
  }

  /// Creates an activity while preserving a raw kind received from a newer
  /// application version.
  public convenience init(
    id: UUID = UUID(),
    kindRawValue: String,
    subjectEdgeID: UUID? = nil,
    rootEdgeID: UUID? = nil,
    createdAt: Date = Date()
  ) {
    self.init(
      id: id,
      kind: .init(rawValue: kindRawValue),
      subjectEdgeID: subjectEdgeID,
      rootEdgeID: rootEdgeID,
      createdAt: createdAt
    )
  }

  /// Canonical CloudKit record type name.
  public static let recordType = VaultRecordType.activity.rawValue

  /// Canonical CloudKit record name for this activity.
  public var recordName: String { id.uuidString }

  /// Known action kind, preserving unrecognized raw values instead of
  /// collapsing or deleting a future activity.
  public var kind: Kind { Kind(rawValue: kindRawValue) }
}

// MARK: - Kind

extension VaultActivity {

  /// Logical action categories stored by ``VaultActivity``.
  ///
  /// The initial product slice has only ``contentAdded``. Root-versus-reply is
  /// intentionally derived from ``subjectEdgeID`` and ``rootEdgeID`` rather
  /// than duplicating placement topology in this enum.
  public enum Kind: Equatable, Hashable, Sendable {
    /// A user added a root post or Reply to the vault.
    case contentAdded

    /// A value written by a newer app version that this build must retain.
    case unknown(String)

    /// Reconstructs the domain projection without changing the persisted raw
    /// value when the value is not known by this build.
    public init(rawValue: String) {
      switch rawValue {
      case "contentAdded":
        self = .contentAdded
      default:
        self = .unknown(rawValue)
      }
    }

    /// Stable serialized value for the current case.
    public var rawValue: String {
      switch self {
      case .contentAdded:
        "contentAdded"
      case .unknown(let rawValue):
        rawValue
      }
    }
  }
}
