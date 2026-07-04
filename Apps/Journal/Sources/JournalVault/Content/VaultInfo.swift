import Foundation
import SwiftData

/// The single self-describing row of one vault content store.
///
/// Synced as the vault zone's minimal record (record name == vault ID), so a
/// zone always has at least one record carrying the vault's display metadata —
/// the later `CKShare(recordZoneID:)` flow builds its share preview from it,
/// and a device that discovers the zone remotely learns the title from it.
@Model
public final class VaultInfo {

  @Attribute(.unique)
  public var vaultID: UUID

  public var title: String

  public var createdAt: Date
  public var updatedAt: Date

  public init(
    vaultID: UUID,
    title: String,
    createdAt: Date = Date(),
    updatedAt: Date = Date()
  ) {
    self.vaultID = vaultID
    self.title = title
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }
}
