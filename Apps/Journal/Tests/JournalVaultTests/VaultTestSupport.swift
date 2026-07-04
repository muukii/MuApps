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
