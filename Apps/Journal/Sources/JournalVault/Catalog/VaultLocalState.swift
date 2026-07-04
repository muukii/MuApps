import Foundation
import SwiftData

/// Device-local state for one vault — never synced anywhere.
///
/// Kept separate from `VaultIndex` on purpose: if parts of the catalog are ever
/// synced between the user's own devices (an open design question), this model
/// stays behind as the local-only remainder.
@Model
public final class VaultLocalState {

  @Attribute(.unique)
  public var vaultID: UUID

  public var lastOpenedAt: Date?

  /// Last time the sync layer finished importing remote changes for this vault.
  public var lastSyncedAt: Date?

  public init(
    vaultID: UUID,
    lastOpenedAt: Date? = nil,
    lastSyncedAt: Date? = nil
  ) {
    self.vaultID = vaultID
    self.lastOpenedAt = lastOpenedAt
    self.lastSyncedAt = lastSyncedAt
  }
}
