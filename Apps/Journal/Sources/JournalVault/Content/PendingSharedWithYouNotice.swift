import Foundation
import SwiftData

/// Local-only intent to project one locally authored Activity into Shared with
/// You after its CloudKit save acknowledgement.
///
/// This row is never a CloudKit record and is created only by local authored,
/// participant-visible writes. That origin boundary prevents remote imports
/// from reposting the same Messages notice from every participant device, and
/// keeps personal/owner-only activity from becoming retroactive notice work.
/// The CloudKit acknowledgement transaction moves a row from
/// ``State/waitingForActivityUpload`` to ``State/ready`` only after the
/// matching Activity save acknowledgement. The app delivery worker changes a
/// ready row to ``State/attempted`` *before* posting for at-most-once behavior;
/// a rare crash can therefore miss one notice rather than duplicate it in a
/// Messages thread.
@Model
public final class PendingSharedWithYouNotice {

  /// Stable idempotency key: the Activity ID this intent belongs to.
  @Attribute(.unique)
  public var activityID: UUID

  /// Raw delivery state retained verbatim for future state-machine changes.
  public var stateRawValue: String

  /// When delivery was irrevocably attempted. `nil` means the future delivery
  /// worker has not yet crossed the at-most-once boundary.
  public var attemptedAt: Date?

  /// Number of transient collaboration-highlight lookups attempted for this
  /// intent.
  ///
  /// This local counter is deliberately independent of the Activity record:
  /// retrying an unavailable system service must never mutate or re-upload the
  /// durable collaboration history that caused the notice.
  public var attemptCount: Int

  /// Most recent time the delivery worker tried to resolve or post this intent.
  ///
  /// The timestamp provides diagnostics and a durable retry boundary after an
  /// app relaunch. It is not an idempotency key; ``activityID`` remains the
  /// stable one-to-one identity for this local-only row.
  public var lastAttemptAt: Date?

  /// Local creation time, useful for bounded retry and diagnostics without
  /// relying on CloudKit record timestamps.
  public var createdAt: Date

  public init(
    activityID: UUID,
    state: State = .waitingForActivityUpload,
    attemptedAt: Date? = nil,
    attemptCount: Int = 0,
    lastAttemptAt: Date? = nil,
    createdAt: Date = Date()
  ) {
    self.activityID = activityID
    stateRawValue = state.rawValue
    self.attemptedAt = attemptedAt
    self.attemptCount = attemptCount
    self.lastAttemptAt = lastAttemptAt
    self.createdAt = createdAt
  }

  /// Known local delivery state, preserving future states rather than rewriting
  /// them when an older app opens the same local store.
  public var state: State { State(rawValue: stateRawValue) }
}

// MARK: - State

extension PendingSharedWithYouNotice {

  /// Lifecycle states for a local Shared with You delivery intent.
  public enum State: Equatable, Hashable, Sendable {
    /// Waiting for the matching Activity's CloudKit save acknowledgement.
    case waitingForActivityUpload

    /// The matching Activity is durably present in CloudKit and can be
    /// projected by a future Shared with You delivery worker.
    case ready

    /// Delivery was attempted and must not be retried automatically.
    case attempted

    /// The current vault/share cannot produce a Messages collaboration
    /// highlight. This is terminal like ``attempted`` so a future worker does
    /// not retry a known-ineligible intent indefinitely.
    case skipped

    /// A future state introduced by a newer build and preserved locally.
    case unknown(String)

    /// Reconstructs a state without normalizing an unrecognized raw value.
    public init(rawValue: String) {
      switch rawValue {
      case "waitingForActivityUpload":
        self = .waitingForActivityUpload
      case "ready":
        self = .ready
      case "attempted":
        self = .attempted
      case "skipped":
        self = .skipped
      default:
        self = .unknown(rawValue)
      }
    }

    /// Stable serialized value for the current state.
    public var rawValue: String {
      switch self {
      case .waitingForActivityUpload:
        "waitingForActivityUpload"
      case .ready:
        "ready"
      case .attempted:
        "attempted"
      case .skipped:
        "skipped"
      case .unknown(let rawValue):
        rawValue
      }
    }
  }
}
