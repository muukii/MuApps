import CloudKit

/// One vault == one CloudKit custom record zone. The zone *is* the sharing
/// boundary (`CKShare(recordZoneID:)`), so zone naming is part of the sync
/// contract: the vault ID is embedded in the zone name and recovered from it
/// when changes arrive.
extension VaultID {

  private static let zoneNamePrefix = "Vault-"

  public var zoneName: String {
    Self.zoneNamePrefix + uuidString
  }

  /// Recovers a vault ID from a zone name; `nil` for zones the vault sync layer
  /// doesn't own (e.g. the legacy `Media` zone or the default zone).
  public init?(zoneName: String) {
    guard zoneName.hasPrefix(Self.zoneNamePrefix) else { return nil }
    self.init(uuidString: String(zoneName.dropFirst(Self.zoneNamePrefix.count)))
  }

  /// The vault's zone ID. `ownerName` is `nil` for owned vaults (current user)
  /// and the sharer's user record name for participant vaults.
  public func zoneID(ownerName: String? = nil) -> CKRecordZone.ID {
    CKRecordZone.ID(zoneName: zoneName, ownerName: ownerName ?? CKCurrentUserDefaultName)
  }
}

extension VaultDescriptor {

  /// The zone this vault's records live in, honoring the sharer's ownership for
  /// participant vaults.
  var zoneID: CKRecordZone.ID {
    vaultID.zoneID(ownerName: zoneOwnerName)
  }
}
