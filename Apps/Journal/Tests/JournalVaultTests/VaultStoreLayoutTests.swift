import Foundation
import Testing

@testable import JournalVault

struct VaultStoreLayoutTests {

  @Test
  func pathsAreVaultScoped() {
    let layout = makeTemporaryLayout()
    let vaultID = VaultID()

    #expect(layout.catalogStoreURL.lastPathComponent == "catalog.sqlite")
    #expect(
      layout.contentStoreURL(for: vaultID).path
        .hasSuffix("Vaults/\(vaultID.uuidString)/store.sqlite")
    )
    #expect(
      layout.mediaDirectoryURL(for: vaultID).path
        .hasSuffix("Vaults/\(vaultID.uuidString)/media")
    )
  }

  @Test
  func zoneNameRoundTripsThroughVaultID() {
    let vaultID = VaultID()
    #expect(VaultID(zoneName: vaultID.zoneName) == vaultID)

    // Zones the vault layer doesn't own must not parse.
    #expect(VaultID(zoneName: "Media") == nil)
    #expect(VaultID(zoneName: "Vault-not-a-uuid") == nil)
  }
}
