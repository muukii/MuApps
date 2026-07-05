import Foundation
import SwiftData

/// How this device relates to a vault's CloudKit zone.
public enum VaultOwnership: String, Codable, Sendable {
  /// The vault's zone lives (or will live) in this user's private database;
  /// this device may create the zone and a `CKShare` for it.
  case owned

  /// The vault was joined through someone else's `CKShare`; its zone is read
  /// through the shared database and owned by another iCloud user.
  case participant
}

/// Catalog row: one per vault this device knows about.
///
/// This is the durable identity record behind the vault picker and launch
/// routing. Card content lives in the vault's own store; this row only says
/// "the vault exists, and here is how to reach it".
///
/// The catalog store has CloudKit mirroring disabled, so unlike the legacy
/// mirrored models it can use `.unique` and non-optional properties freely.
@Model
public final class VaultIndex {

  @Attribute(.unique)
  public var vaultID: UUID

  public var title: String

  /// Raw `VaultIcon.Kind` value. `nil` means the row predates vault icons and
  /// should render with `VaultIcon.default`.
  public var iconKindRawValue: String?

  /// SF Symbol name or emoji string paired with `iconKindRawValue`.
  public var iconValue: String?

  public var ownership: VaultOwnership

  /// CloudKit zone owner for `participant` vaults. `nil` means the zone belongs
  /// to the current user (`CKCurrentUserDefaultName`).
  public var zoneOwnerName: String?

  public var createdAt: Date

  /// Stable manual order for the vault picker.
  public var sortIndex: Int

  public init(
    vaultID: UUID,
    title: String,
    icon: VaultIcon = .default,
    ownership: VaultOwnership = .owned,
    zoneOwnerName: String? = nil,
    createdAt: Date = Date(),
    sortIndex: Int = 0
  ) {
    self.vaultID = vaultID
    self.title = title
    self.iconKindRawValue = icon.kind.rawValue
    self.iconValue = icon.value
    self.ownership = ownership
    self.zoneOwnerName = zoneOwnerName
    self.createdAt = createdAt
    self.sortIndex = sortIndex
  }
}
