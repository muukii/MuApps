import Foundation
import SwiftData

/// The single self-describing row of one vault content store.
///
/// Synced as the vault zone's minimal record (record name == vault ID), so a
/// zone always has at least one record carrying the vault's display metadata —
/// the later `CKShare(recordZoneID:)` flow builds its share preview from it,
/// and a device that discovers the zone remotely learns its title and icon.
@Model
public final class VaultInfo {

  @Attribute(.unique)
  public var vaultID: UUID

  public var title: String

  /// Raw `VaultIcon.Kind` value synchronized with the vault metadata record.
  /// `nil` means the CloudKit record predates synchronized vault icons.
  public var iconKindRawValue: String?

  /// SF Symbol name or emoji string paired with `iconKindRawValue`.
  public var iconValue: String?

  public var createdAt: Date
  public var updatedAt: Date

  public init(
    vaultID: UUID,
    title: String,
    icon: VaultIcon? = nil,
    createdAt: Date = Date(),
    updatedAt: Date = Date()
  ) {
    self.vaultID = vaultID
    self.title = title
    self.iconKindRawValue = icon?.kind.rawValue
    self.iconValue = icon?.value
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }

  /// Valid synchronized icon, or `nil` for legacy or unknown metadata.
  public var icon: VaultIcon? {
    guard
      let iconKindRawValue,
      let kind = VaultIcon.Kind(rawValue: iconKindRawValue),
      let iconValue,
      iconValue.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false
    else {
      return nil
    }
    return VaultIcon(kind: kind, value: iconValue)
  }
}
