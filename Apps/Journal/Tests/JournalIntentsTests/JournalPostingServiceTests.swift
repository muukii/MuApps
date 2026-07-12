import Foundation
import SwiftData
import Testing

@testable import JournalIntents
import JournalVault

@MainActor
struct JournalPostingServiceTests {
  @Test
  func writableVaults_excludesReadOnlyDestinations() throws {
    let layout = makeTemporaryLayout()
    let vaults = try seedWritableAndReadOnlyVaults(in: layout)
    let service = JournalPostingService(layout: layout, reloadWidgetTimelines: {})

    let writableVaults = try service.writableVaults()

    #expect(writableVaults.map(\.id) == [vaults.writable])
    #expect(writableVaults.map(\.title) == ["Writable"])
  }

  @Test
  func post_rejectsReadOnlyVaultWithoutReloadingWidget() throws {
    let layout = makeTemporaryLayout()
    let vaults = try seedWritableAndReadOnlyVaults(in: layout)
    var reloadCount = 0
    let service = JournalPostingService(layout: layout) {
      reloadCount += 1
    }

    do {
      try service.post(
        cards: [.init(kind: .text, text: "Must not save")],
        to: vaults.readOnly
      )
      Issue.record("Posting to a read-only vault unexpectedly succeeded.")
    } catch let error as JournalPostingService.Error {
      guard case .readOnlyVault(let rejectedVaultID) = error else {
        Issue.record("Expected readOnlyVault, received \(error).")
        return
      }
      #expect(rejectedVaultID == vaults.readOnly)
    }

    #expect(reloadCount == 0)
  }

  @Test
  func post_writesOnlyToSelectedVaultAndReloadsWidgetAfterSuccess() throws {
    let layout = makeTemporaryLayout()
    let vaultIDs = try seedTwoWritableVaults(in: layout)
    var reloadCount = 0

    do {
      let service = JournalPostingService(layout: layout) {
        reloadCount += 1
      }
      try service.post(
        cards: [.init(kind: .text, text: "Targeted")],
        to: vaultIDs.second
      )
    }

    let firstStore = try VaultContentStore.open(
      vaultID: vaultIDs.first,
      layout: layout,
      recoveryPolicy: .failWithoutReset
    )
    let secondStore = try VaultContentStore.open(
      vaultID: vaultIDs.second,
      layout: layout,
      recoveryPolicy: .failWithoutReset
    )
    let firstCards = try firstStore.container.mainContext.fetch(FetchDescriptor<Card>())
    let secondCards = try secondStore.container.mainContext.fetch(FetchDescriptor<Card>())

    #expect(firstCards.isEmpty)
    #expect(secondCards.map(\.body) == ["Targeted"])
    #expect(reloadCount == 1)
  }

  @Test
  func post_doesNotReloadWidgetWhenStoreTransactionFails() throws {
    let layout = makeTemporaryLayout()
    let vaultIDs = try seedTwoWritableVaults(in: layout)
    var reloadCount = 0
    let service = JournalPostingService(layout: layout) {
      reloadCount += 1
    }

    do {
      try service.post(
        cards: [.init(kind: .photo)],
        to: vaultIDs.first
      )
      Issue.record("A photo without media unexpectedly saved.")
    } catch let error as VaultContentStore.Error {
      guard case .missingMediaPayload(.photo) = error else {
        Issue.record("Expected missingMediaPayload(.photo), received \(error).")
        return
      }
    }

    #expect(reloadCount == 0)
  }

  private func seedWritableAndReadOnlyVaults(
    in layout: VaultStoreLayout
  ) throws -> (writable: VaultID, readOnly: VaultID) {
    let registry = VaultStoreRegistry(layout: layout)
    let catalog = try VaultCatalogStore.open(layout: layout)
    let writable = try catalog.createVault(title: "Writable", using: registry)
    let readOnly = VaultID()
    try catalog.materializeRemoteVault(
      VaultDescriptor(
        vaultID: readOnly,
        title: "Read Only",
        ownership: .participant,
        zoneOwnerName: "_owner"
      )
    )
    try catalog.applyShareInfo(
      vaultID: readOnly,
      isShared: true,
      shareURL: nil,
      shareRecordName: nil,
      participantCount: 2,
      permission: .readOnly
    )
    return (writable, readOnly)
  }

  private func seedTwoWritableVaults(
    in layout: VaultStoreLayout
  ) throws -> (first: VaultID, second: VaultID) {
    let registry = VaultStoreRegistry(layout: layout)
    let catalog = try VaultCatalogStore.open(layout: layout)
    return (
      try catalog.createVault(title: "First", using: registry),
      try catalog.createVault(title: "Second", using: registry)
    )
  }

  private func makeTemporaryLayout() -> VaultStoreLayout {
    VaultStoreLayout(
      rootDirectoryURL: FileManager.default.temporaryDirectory.appending(
        path: "JournalIntentsTests-\(UUID().uuidString)",
        directoryHint: .isDirectory
      )
    )
  }
}
