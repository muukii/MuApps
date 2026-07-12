import Foundation
import Synchronization

/// Opens and caches vault stores — exactly one `ModelContainer` per vault per
/// process — and fans local-mutation signals out to the sync layer.
///
/// One container per store file matters: SwiftUI observation and the sync
/// engine's background imports must flow through the same container for
/// changes to propagate between them. Every store open in the app (and in the
/// sync engine) goes through here.
public final class VaultStoreRegistry: Sendable {

  public let layout: VaultStoreLayout

  /// Recovery behavior inherited by every first store open in this process.
  public let openRecoveryPolicy: VaultContentStore.OpenRecoveryPolicy

  private struct State {
    var stores: [VaultID: VaultContentStore] = [:]
    var subscribers: [UUID: AsyncStream<VaultID>.Continuation] = [:]
  }

  private let state = Mutex(State())

  public init(
    layout: VaultStoreLayout,
    openRecoveryPolicy: VaultContentStore.OpenRecoveryPolicy = .resetPreReleaseStore
  ) {
    self.layout = layout
    self.openRecoveryPolicy = openRecoveryPolicy
  }

  /// Returns the vault's open store, opening it on first access. Opening
  /// happens inside the lock so concurrent callers can never race two
  /// containers onto the same store file.
  public func store(for vaultID: VaultID) throws -> VaultContentStore {
    try state.withLock { state in
      if let store = state.stores[vaultID] {
        return store
      }
      let store = try VaultContentStore.open(
        vaultID: vaultID,
        layout: layout,
        recoveryPolicy: openRecoveryPolicy,
        onLocalMutation: { [weak self] in self?.broadcast(vaultID) }
      )
      state.stores[vaultID] = store
      return store
    }
  }

  /// Releases the cached store identity for a vault that is about to be
  /// deleted locally.
  ///
  /// The registry can't forcibly close a SwiftData `ModelContainer`; this
  /// method removes the registry's strong reference so the deletion flow can
  /// drop every app-owned handle before removing the vault directory.
  public func discardStore(for vaultID: VaultID) {
    state.withLock { state in
      _ = state.stores.removeValue(forKey: vaultID)
    }
  }

  /// A stream of vault IDs whose stores just saved local mutations. The sync
  /// engine consumes this to turn `PendingMutation` rows into CloudKit pending
  /// changes without the stores knowing the engine exists.
  public func localMutations() -> AsyncStream<VaultID> {
    let id = UUID()
    return AsyncStream { continuation in
      state.withLock { $0.subscribers[id] = continuation }
      continuation.onTermination = { [weak self] _ in
        self?.state.withLock { _ = $0.subscribers.removeValue(forKey: id) }
      }
    }
  }

  private func broadcast(_ vaultID: VaultID) {
    let continuations = state.withLock { Array($0.subscribers.values) }
    for continuation in continuations {
      continuation.yield(vaultID)
    }
  }
}
