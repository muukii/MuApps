import Foundation
import SwiftData

/// Collapsed view of a vault's share permission for display purposes.
public enum VaultPermissionSummary: String, Codable, Sendable {
  case owner
  case readWrite
  case readOnly
}

/// Denormalized per-vault summary for lightweight surfaces — the vault picker,
/// widgets, and Shared with You presentation — so none of them have to open the
/// vault's content store.
///
/// Share-related fields are maintained by the sync boundary: local sharing
/// flows (`prepareShare` / stop-sharing callbacks) and every remote path that
/// sees the zone-wide `CKShare` (initial discovery, engine record fetches,
/// invite acceptance) mirror the share into this row via `applyShareInfo`.
@Model
public final class VaultSummary {

  @Attribute(.unique)
  public var vaultID: UUID

  public var title: String

  public var isShared: Bool

  public var shareURL: String?

  public var shareRecordName: String?

  /// Number of people in the vault, including the owner. `1` while unshared.
  public var participantCount: Int

  public var permission: VaultPermissionSummary

  /// Last time Tinycurve invoked a Shared with You notice post for this vault.
  ///
  /// This is diagnostic summary state only. The corresponding
  /// ``PendingSharedWithYouNotice/activityID`` row is the event-level
  /// at-most-once boundary; this aggregate timestamp must never decide whether
  /// a particular Activity is eligible to post.
  public var lastSharedWithYouNoticeAt: Date?

  public init(
    vaultID: UUID,
    title: String,
    isShared: Bool = false,
    shareURL: String? = nil,
    shareRecordName: String? = nil,
    participantCount: Int = 1,
    permission: VaultPermissionSummary = .owner,
    lastSharedWithYouNoticeAt: Date? = nil
  ) {
    self.vaultID = vaultID
    self.title = title
    self.isShared = isShared
    self.shareURL = shareURL
    self.shareRecordName = shareRecordName
    self.participantCount = participantCount
    self.permission = permission
    self.lastSharedWithYouNoticeAt = lastSharedWithYouNoticeAt
  }
}
