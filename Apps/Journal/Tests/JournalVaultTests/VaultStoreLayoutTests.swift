import Foundation
import Testing

@testable import JournalVault

struct VaultStoreLayoutTests {

  @Test
  func cloudKitEnvironmentParsesInfoPlistValues() {
    #expect(VaultCloudKitEnvironment(infoPlistValue: "development") == .development)
    #expect(VaultCloudKitEnvironment(infoPlistValue: "production") == .production)
    #expect(VaultCloudKitEnvironment(infoPlistValue: " Production ") == .production)
    #expect(VaultCloudKitEnvironment(infoPlistValue: "staging") == nil)
    #expect(VaultCloudKitEnvironment(infoPlistValue: nil) == nil)
  }

  @Test
  func appGroupRootIsScopedByCloudKitEnvironment() {
    let containerURL = FileManager.default.temporaryDirectory
      .appending(path: "JournalAppGroup-\(UUID().uuidString)", directoryHint: .isDirectory)

    let developmentURL = VaultStoreLayout.appGroupRootDirectoryURL(
      containerURL: containerURL,
      cloudKitEnvironment: .development
    )
    let productionURL = VaultStoreLayout.appGroupRootDirectoryURL(
      containerURL: containerURL,
      cloudKitEnvironment: .production
    )

    #expect(developmentURL.path.hasSuffix("Journal/development"))
    #expect(productionURL.path.hasSuffix("Journal/production"))
    #expect(developmentURL != productionURL)
  }

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

  @Test
  func resetPreReleaseContentStorePreparesCloudKitRecovery() throws {
    let layout = makeTemporaryLayout()
    let vaultID = VaultID()
    try layout.ensureRootDirectories()
    try layout.ensureVaultDirectories(for: vaultID)

    let storeURL = layout.contentStoreURL(for: vaultID)
    let walURL = storeURL.deletingLastPathComponent()
      .appending(path: "\(storeURL.lastPathComponent)-wal", directoryHint: .notDirectory)
    let shmURL = storeURL.deletingLastPathComponent()
      .appending(path: "\(storeURL.lastPathComponent)-shm", directoryHint: .notDirectory)
    let mediaFileURL = layout.mediaDirectoryURL(for: vaultID)
      .appending(path: UUID().uuidString, directoryHint: .notDirectory)
    let catalogURL = layout.catalogStoreURL
    let syncStateURL = layout.syncStateDirectoryURL
      .appending(path: "private-database.json", directoryHint: .notDirectory)

    try Data([0x01]).write(to: storeURL)
    try Data([0x02]).write(to: walURL)
    try Data([0x03]).write(to: shmURL)
    try Data([0x04]).write(to: mediaFileURL)
    try Data([0x05]).write(to: catalogURL)
    try Data([0x06]).write(to: syncStateURL)

    try layout.resetPreReleaseContentStoreForCloudKitRecovery(for: vaultID)

    #expect(FileManager.default.fileExists(atPath: storeURL.path) == false)
    #expect(FileManager.default.fileExists(atPath: walURL.path) == false)
    #expect(FileManager.default.fileExists(atPath: shmURL.path) == false)
    #expect(FileManager.default.fileExists(atPath: mediaFileURL.path) == false)
    #expect(FileManager.default.fileExists(atPath: layout.mediaDirectoryURL(for: vaultID).path))
    #expect(FileManager.default.fileExists(atPath: catalogURL.path))
    #expect(FileManager.default.fileExists(atPath: syncStateURL.path) == false)
    #expect(try layout.consumePreReleaseCloudKitRefetchRequest(for: vaultID))
    #expect(try layout.consumePreReleaseCloudKitRefetchRequest(for: vaultID) == false)
  }

  @Test
  func removeVaultDirectoryDeletesOnlyThatVault() throws {
    let layout = makeTemporaryLayout()
    let deletedVaultID = VaultID()
    let remainingVaultID = VaultID()
    try layout.ensureRootDirectories()
    try layout.ensureVaultDirectories(for: deletedVaultID)
    try layout.ensureVaultDirectories(for: remainingVaultID)

    let deletedStoreURL = layout.contentStoreURL(for: deletedVaultID)
    let deletedMediaFileURL = layout.mediaDirectoryURL(for: deletedVaultID)
      .appending(path: UUID().uuidString, directoryHint: .notDirectory)
    let remainingMediaFileURL = layout.mediaDirectoryURL(for: remainingVaultID)
      .appending(path: UUID().uuidString, directoryHint: .notDirectory)
    let catalogURL = layout.catalogStoreURL

    try Data([0x01]).write(to: deletedStoreURL)
    try Data([0x02]).write(to: deletedMediaFileURL)
    try Data([0x03]).write(to: remainingMediaFileURL)
    try Data([0x04]).write(to: catalogURL)

    try layout.removeVaultDirectory(for: deletedVaultID)

    #expect(FileManager.default.fileExists(atPath: layout.vaultDirectoryURL(for: deletedVaultID).path) == false)
    #expect(FileManager.default.fileExists(atPath: deletedStoreURL.path) == false)
    #expect(FileManager.default.fileExists(atPath: deletedMediaFileURL.path) == false)
    #expect(FileManager.default.fileExists(atPath: layout.vaultDirectoryURL(for: remainingVaultID).path))
    #expect(FileManager.default.fileExists(atPath: remainingMediaFileURL.path))
    #expect(FileManager.default.fileExists(atPath: catalogURL.path))
  }
}
