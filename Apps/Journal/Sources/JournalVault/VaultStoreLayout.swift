import Foundation

/// On-disk layout of Journal's vault persistence tree.
///
/// ```text
/// <App Group>/Journal/
///   development/               Debug builds, CloudKit Development database
///   production/                Release/TestFlight/App Store, CloudKit Production database
///     catalog.sqlite           VaultCatalogStore
///     Vaults/
///       <vault-id>/
///         store.sqlite         VaultContentStore(vaultID)
///         media/               attachment bytes, one file per attachment id
///     SyncState/               CKSyncEngine state serializations. Engine state
///                              is per CloudKit *database* (private / shared),
///                              not per vault, so it lives at the environment root.
///     Vaults/<vault-id>/needs-cloudkit-refetch
///                              Pre-release recovery marker consumed by the
///                              CloudKit sync engine after a local store reset.
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

  /// The app/widget layout for one CloudKit environment.
  ///
  /// Development and production CloudKit databases are independent, so their
  /// local catalog, vault stores, media, and CKSyncEngine tokens must not share
  /// one on-disk root.
  public static func appGroup(
    cloudKitEnvironment: VaultCloudKitEnvironment = .current
  ) throws -> VaultStoreLayout {
    guard
      let container = FileManager.default.containerURL(
        forSecurityApplicationGroupIdentifier: appGroupIdentifier
      )
    else {
      throw Error.appGroupContainerUnavailable
    }
    return VaultStoreLayout(
      rootDirectoryURL: appGroupRootDirectoryURL(
        containerURL: container,
        cloudKitEnvironment: cloudKitEnvironment
      )
    )
  }

  static func appGroupRootDirectoryURL(
    containerURL: URL,
    cloudKitEnvironment: VaultCloudKitEnvironment
  ) -> URL {
    containerURL
      .appending(path: "Journal", directoryHint: .isDirectory)
      .appending(path: cloudKitEnvironment.storageDirectoryName, directoryHint: .isDirectory)
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

  func preReleaseCloudKitRefetchMarkerURL(for vaultID: VaultID) -> URL {
    vaultDirectoryURL(for: vaultID)
      .appending(path: "needs-cloudkit-refetch", directoryHint: .notDirectory)
  }

  public func syncStateFileURLs() -> [URL] {
    [
      syncStateDirectoryURL.appending(path: "private-database.json", directoryHint: .notDirectory),
      syncStateDirectoryURL.appending(path: "shared-database.json", directoryHint: .notDirectory),
    ]
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

  /// Removes one vault's entire on-disk content directory.
  ///
  /// This is the local half of vault deletion. Callers must first release any
  /// cached store/instance references they own; SwiftData doesn't expose an
  /// explicit close operation for `ModelContainer`.
  public func removeVaultDirectory(for vaultID: VaultID) throws {
    let directoryURL = vaultDirectoryURL(for: vaultID)
    if FileManager.default.fileExists(atPath: directoryURL.path) {
      try FileManager.default.removeItem(at: directoryURL)
    }
  }

  /// Removes one vault's local content database and media files.
  ///
  /// This is intentionally scoped to `Vaults/<vault-id>/`: the catalog, sync
  /// engine state, and sibling vault stores are left untouched. Pre-release
  /// schema breaks use this to discard incompatible local content instead of
  /// carrying migration code for shapes that never shipped.
  func resetPreReleaseContentStoreForCloudKitRecovery(for vaultID: VaultID) throws {
    let storeURL = contentStoreURL(for: vaultID)
    let fileManager = FileManager.default
    let storeSidecarNames = [
      storeURL.lastPathComponent,
      "\(storeURL.lastPathComponent)-shm",
      "\(storeURL.lastPathComponent)-wal",
    ]

    for fileName in storeSidecarNames {
      let fileURL = storeURL.deletingLastPathComponent()
        .appending(path: fileName, directoryHint: .notDirectory)
      if fileManager.fileExists(atPath: fileURL.path) {
        try fileManager.removeItem(at: fileURL)
      }
    }

    let mediaURL = mediaDirectoryURL(for: vaultID)
    if fileManager.fileExists(atPath: mediaURL.path) {
      try fileManager.removeItem(at: mediaURL)
    }
    try ensureVaultDirectories(for: vaultID)
    try Data().write(to: preReleaseCloudKitRefetchMarkerURL(for: vaultID), options: .atomic)
    try resetCloudKitSyncStateFiles()
  }

  func consumePreReleaseCloudKitRefetchRequest(for vaultID: VaultID) throws -> Bool {
    let markerURL = preReleaseCloudKitRefetchMarkerURL(for: vaultID)
    guard FileManager.default.fileExists(atPath: markerURL.path) else { return false }
    try FileManager.default.removeItem(at: markerURL)
    return true
  }

  func resetCloudKitSyncStateFiles() throws {
    let fileManager = FileManager.default
    for fileURL in syncStateFileURLs() where fileManager.fileExists(atPath: fileURL.path) {
      try fileManager.removeItem(at: fileURL)
    }
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
