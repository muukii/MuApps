import Foundation

/// On-disk layout of Journal's vault persistence tree.
///
/// ```text
/// <root>/                      "Journal" inside the App Group container
///   catalog.sqlite             VaultCatalogStore
///   Vaults/
///     <vault-id>/
///       store.sqlite           VaultContentStore(vaultID)
///       media/                 attachment bytes, one file per attachment id
///   SyncState/                 CKSyncEngine state serializations. Engine state
///                              is per CloudKit *database* (private / shared),
///                              not per vault, so it lives at the root.
/// ```
///
/// Per-vault sync bookkeeping (record system fields, the pending-mutation
/// outbox) deliberately lives *inside* each vault's `store.sqlite`
/// (`SyncMetadata` / `PendingMutation`), so deleting, resetting, or repairing
/// one vault is a vault-directory-scoped operation that cannot touch its
/// siblings.
///
/// This type is only path math plus directory creation; it holds no open
/// stores. Tests point `rootDirectoryURL` at a temporary directory.
public struct VaultStoreLayout: Hashable, Sendable {

  /// App Group backing the shared tree, so app extensions (the widget) can read
  /// the same files. Must be listed in the entitlements of every process that
  /// opens vault stores.
  public static let appGroupIdentifier = "group.app.muukii.journal"

  public let rootDirectoryURL: URL

  public init(rootDirectoryURL: URL) {
    self.rootDirectoryURL = rootDirectoryURL
  }

  /// The production layout: `<App Group container>/Journal`.
  public static func appGroup() throws -> VaultStoreLayout {
    guard
      let container = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: appGroupIdentifier
      )
    else {
      throw Error.appGroupContainerUnavailable
    }
    return VaultStoreLayout(
      rootDirectoryURL: container.appending(path: "Journal", directoryHint: .isDirectory)
    )
  }

  // MARK: - Paths

  public var catalogStoreURL: URL {
    rootDirectoryURL.appending(path: "catalog.sqlite", directoryHint: .notDirectory)
  }

  public var vaultsDirectoryURL: URL {
    rootDirectoryURL.appending(path: "Vaults", directoryHint: .isDirectory)
  }

  public var syncStateDirectoryURL: URL {
    rootDirectoryURL.appending(path: "SyncState", directoryHint: .isDirectory)
  }

  public func vaultDirectoryURL(for vaultID: VaultID) -> URL {
    vaultsDirectoryURL.appending(path: vaultID.uuidString, directoryHint: .isDirectory)
  }

  public func contentStoreURL(for vaultID: VaultID) -> URL {
    vaultDirectoryURL(for: vaultID).appending(path: "store.sqlite", directoryHint: .notDirectory)
  }

  public func mediaDirectoryURL(for vaultID: VaultID) -> URL {
    vaultDirectoryURL(for: vaultID).appending(path: "media", directoryHint: .isDirectory)
  }

  // MARK: - Directory creation

  /// Creates the root, `Vaults/`, and `SyncState/` directories. Idempotent.
  public func ensureRootDirectories() throws {
    try FileManager.default.createDirectory(at: vaultsDirectoryURL, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: syncStateDirectoryURL, withIntermediateDirectories: true)
  }

  /// Creates one vault's directory and its `media/` subdirectory. Idempotent.
  public func ensureVaultDirectories(for vaultID: VaultID) throws {
    try FileManager.default.createDirectory(
      at: mediaDirectoryURL(for: vaultID),
      withIntermediateDirectories: true
    )
  }
}

// MARK: - Errors

extension VaultStoreLayout {

  public enum Error: Swift.Error {
    /// The App Group container couldn't be resolved — the entitlement is missing
    /// or misconfigured.
    case appGroupContainerUnavailable
  }
}
