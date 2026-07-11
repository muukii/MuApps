import Foundation
import SwiftData
import Testing

@testable import JournalVault

@MainActor
struct VaultCatalogStoreTests {

  @Test
  func newCatalogStartsEmptyUntilUserCreatesVault() throws {
    let layout = makeTemporaryLayout()
    let catalog = try VaultCatalogStore.open(layout: layout)

    #expect(try catalog.vaultDescriptors().isEmpty)
  }

  @Test
  func createVault_seedsContentStoreAndQueuesVaultInfoUpload() throws {
    let layout = makeTemporaryLayout()
    let registry = VaultStoreRegistry(layout: layout)
    let catalog = try VaultCatalogStore.open(layout: layout)

    let vaultID = try catalog.createVault(title: "Trip", using: registry)

    let store = try registry.store(for: vaultID)
    let context = store.container.mainContext

    let info = try #require(try context.fetch(FetchDescriptor<VaultInfo>()).first)
    #expect(info.title == "Trip")
    #expect(info.vaultID == vaultID.rawValue)

    let outbox = try context.fetch(FetchDescriptor<PendingMutation>())
    #expect(outbox.count == 1)
    #expect(outbox.first?.recordType == VaultRecordType.vaultInfo.rawValue)
    #expect(outbox.first?.recordName == vaultID.uuidString)
    #expect(outbox.first?.kind == .save)

    #expect(FileManager.default.fileExists(atPath: layout.mediaDirectoryURL(for: vaultID).path))
  }

  @Test
  func createVault_seedsSelectedIconInCatalogAndVaultInfo() throws {
    let layout = makeTemporaryLayout()
    let registry = VaultStoreRegistry(layout: layout)
    let catalog = try VaultCatalogStore.open(layout: layout)
    let icon = VaultIcon.emoji("\u{1F4DA}")

    let vaultID = try catalog.createVault(title: "Reading", icon: icon, using: registry)

    #expect(try catalog.vaultDescriptors().first?.icon == icon)
    let store = try registry.store(for: vaultID)
    let info = try #require(
      try store.container.mainContext.fetch(FetchDescriptor<VaultInfo>()).first
    )
    #expect(info.icon == icon)
  }

  @Test
  func materializeRemoteVault_isIdempotentAndKeepsOwnership() throws {
    let layout = makeTemporaryLayout()
    let catalog = try VaultCatalogStore.open(layout: layout)
    let descriptor = VaultDescriptor(
      vaultID: VaultID(),
      title: "",
      ownership: .participant,
      zoneOwnerName: "_someoneElse"
    )

    try catalog.materializeRemoteVault(descriptor)
    try catalog.materializeRemoteVault(descriptor)

    let descriptors = try catalog.vaultDescriptors()
    #expect(descriptors.count == 1)
    #expect(descriptors.first?.ownership == .participant)
    #expect(descriptors.first?.zoneOwnerName == "_someoneElse")
  }

  @Test
  func applyImportedVaultInfo_updatesIndexAndSummaryTitles() throws {
    let layout = makeTemporaryLayout()
    let registry = VaultStoreRegistry(layout: layout)
    let catalog = try VaultCatalogStore.open(layout: layout)
    let vaultID = try catalog.createVault(title: "Old", using: registry)

    try catalog.applyImportedVaultInfo(vaultID: vaultID, title: "New")

    #expect(try catalog.vaultDescriptors().first?.title == "New")
    let summaries = try catalog.container.mainContext.fetch(FetchDescriptor<VaultSummary>())
    #expect(summaries.first?.title == "New")
  }

  @Test
  func applyImportedVaultInfo_updatesIconWhenPresentAndPreservesItWhenMissing() throws {
    let layout = makeTemporaryLayout()
    let registry = VaultStoreRegistry(layout: layout)
    let catalog = try VaultCatalogStore.open(layout: layout)
    let originalIcon = VaultIcon.systemImage("book.closed")
    let importedIcon = VaultIcon.emoji("\u{1F30A}")
    let vaultID = try catalog.createVault(
      title: "Old",
      icon: originalIcon,
      using: registry
    )

    try catalog.applyImportedVaultInfo(vaultID: vaultID, title: "New", icon: importedIcon)
    #expect(try catalog.vaultDescriptors().first?.icon == importedIcon)

    try catalog.applyImportedVaultInfo(vaultID: vaultID, title: "Newest", icon: nil)
    let descriptor = try #require(try catalog.vaultDescriptors().first)
    #expect(descriptor.title == "Newest")
    #expect(descriptor.icon == importedIcon)
  }

  @Test
  func renameVault_updatesIndexAndSummaryTitles() throws {
    let layout = makeTemporaryLayout()
    let registry = VaultStoreRegistry(layout: layout)
    let catalog = try VaultCatalogStore.open(layout: layout)
    let vaultID = try catalog.createVault(title: "Draft", using: registry)

    try catalog.renameVault(vaultID: vaultID, title: "Published")

    #expect(try catalog.vaultDescriptors().first?.title == "Published")
    let summaries = try catalog.container.mainContext.fetch(FetchDescriptor<VaultSummary>())
    #expect(summaries.first?.title == "Published")
  }

  @Test
  func deleteVault_removesCatalogRowsOnly() throws {
    let layout = makeTemporaryLayout()
    let registry = VaultStoreRegistry(layout: layout)
    let catalog = try VaultCatalogStore.open(layout: layout)
    let deletedVaultID = try catalog.createVault(title: "Deleted", using: registry)
    let remainingVaultID = try catalog.createVault(title: "Remaining", using: registry)

    try catalog.deleteVault(vaultID: deletedVaultID)

    let descriptors = try catalog.vaultDescriptors()
    #expect(descriptors.map(\.vaultID) == [remainingVaultID])

    let context = catalog.container.mainContext
    let indices = try context.fetch(FetchDescriptor<VaultIndex>())
    let localStates = try context.fetch(FetchDescriptor<VaultLocalState>())
    let summaries = try context.fetch(FetchDescriptor<VaultSummary>())
    #expect(indices.contains { $0.vaultID == deletedVaultID.rawValue } == false)
    #expect(localStates.contains { $0.vaultID == deletedVaultID.rawValue } == false)
    #expect(summaries.contains { $0.vaultID == deletedVaultID.rawValue } == false)

    // Content files are a separate boundary owned by VaultStoreLayout.
    #expect(FileManager.default.fileExists(atPath: layout.vaultDirectoryURL(for: deletedVaultID).path))
  }

  @Test
  func registry_streamsLocalMutationsToSubscribers() async throws {
    let layout = makeTemporaryLayout()
    let registry = VaultStoreRegistry(layout: layout)
    let stream = registry.localMutations()

    let vaultID = VaultID()
    let store = try registry.store(for: vaultID)
    try store.seedVaultInfo(title: "X")

    var iterator = stream.makeAsyncIterator()
    let received = await iterator.next()
    #expect(received == vaultID)
  }
}
