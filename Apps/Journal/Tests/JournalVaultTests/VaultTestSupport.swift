import Foundation
@testable import JournalVault

/// A fresh, isolated on-disk layout per test, rooted in the temporary
/// directory so tests never share store files.
func makeTemporaryLayout() -> VaultStoreLayout {
  VaultStoreLayout(
    rootDirectoryURL: FileManager.default.temporaryDirectory.appending(
      path: "JournalVaultTests-\(UUID().uuidString)",
      directoryHint: .isDirectory
    )
  )
}

/// Existing content-store tests model a personal vault unless a test explicitly
/// exercises participant delivery. Production write APIs intentionally require
/// a `VaultActivityDeliveryPolicy`; this test-only convenience keeps unrelated
/// card, file, and deletion tests focused on their original contracts.
@MainActor
extension VaultContentStore {

  func createThread(cards drafts: [CardDraft]) throws -> [CardEdge] {
    try createThread(cards: drafts, deliveryPolicy: .historyOnly)
  }

  func appendCard(_ draft: CardDraft, to parentEdgeID: UUID) throws -> CardEdge {
    try appendCard(draft, to: parentEdgeID, deliveryPolicy: .historyOnly)
  }
}
