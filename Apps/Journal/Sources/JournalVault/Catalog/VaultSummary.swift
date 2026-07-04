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
/// Share-related fields are maintained by the sharing flows
/// (`CKSystemSharingUIObserver` observation updates them when the user saves or
/// stops a share through system UI); this milestone only persists the shape.
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

  /// Last time a Shared with You notice was posted to the vault's Messages
  /// thread. Unused until the notice policy is decided (see design doc).
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
