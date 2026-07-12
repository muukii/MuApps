import Foundation
import JournalVault
import WidgetKit

/// Shared write boundary for App Intents and short-lived Journal extensions.
///
/// The service opens the App Group catalog and one process-local
/// `VaultStoreRegistry`, validates write permission immediately before saving,
/// then delegates the atomic card/outbox transaction to
/// `VaultContentStore.createThread(cards:)`. It does not start a CloudKit sync
/// engine inside an extension process; the durable outbox is picked up by the
/// app's sync lifecycle.
@MainActor
public final class JournalPostingService {
  private struct Storage {
    let catalog: VaultCatalogStore
    let registry: VaultStoreRegistry
  }

  private let explicitLayout: VaultStoreLayout?
  private let reloadWidgetTimelines: @MainActor () -> Void
  private var storage: Storage?

  /// Creates a service backed by the current environment's App Group stores.
  public init() {
    explicitLayout = nil
    reloadWidgetTimelines = {
      WidgetCenter.shared.reloadTimelines(ofKind: JournalWidgetKind.latestNote)
    }
  }

  /// Creates a service with an explicit layout and timeline reload hook.
  ///
  /// This initializer keeps persistence tests isolated from the real App Group
  /// and allows them to observe reload ordering without contacting WidgetKit.
  public init(
    layout: VaultStoreLayout,
    reloadWidgetTimelines: @escaping @MainActor () -> Void = {
      WidgetCenter.shared.reloadTimelines(ofKind: JournalWidgetKind.latestNote)
    }
  ) {
    explicitLayout = layout
    self.reloadWidgetTimelines = reloadWidgetTimelines
  }

  /// Returns catalog vaults that currently accept new content.
  public func writableVaults() throws -> [JournalWritableVault] {
    try resolvedStorage().catalog.vaultDescriptors()
      .filter { $0.permission != .readOnly }
      .map { JournalWritableVault(id: $0.vaultID, title: $0.title) }
  }

  /// Resolves one writable destination by stable identity.
  public func writableVault(id: VaultID) throws -> JournalWritableVault? {
    try writableVaults().first { $0.id == id }
  }

  /// Saves one composed post into a validated destination vault.
  ///
  /// All card drafts are committed as one thread and one durable outbox
  /// transaction. Widget timelines are reloaded only after that transaction
  /// succeeds. An empty draft array is rejected rather than creating a
  /// structurally invalid post.
  public func post(
    cards: [VaultContentStore.CardDraft],
    to vault: JournalWritableVault
  ) throws {
    try post(cards: cards, to: vault.id)
  }

  /// Saves one composed post using a typed vault identifier.
  public func post(
    cards: [VaultContentStore.CardDraft],
    to vaultID: VaultID
  ) throws {
    guard cards.isEmpty == false else {
      throw Error.emptyPost
    }

    let storage = try resolvedStorage()
    let descriptors = try storage.catalog.vaultDescriptors()
    guard let descriptor = descriptors.first(where: { $0.vaultID == vaultID }) else {
      throw Error.vaultNotFound(vaultID)
    }
    guard descriptor.permission != .readOnly else {
      throw Error.readOnlyVault(vaultID)
    }

    let store = try storage.registry.store(for: vaultID)
    _ = try store.createThread(cards: cards)
    reloadWidgetTimelines()
  }

  /// Saves one composed post using a value supplied by App Intents.
  public func post(
    cards: [VaultContentStore.CardDraft],
    to entity: JournalWritableVaultEntity
  ) throws {
    guard let vaultID = entity.vaultID else {
      throw Error.invalidVaultIdentifier(entity.id)
    }
    try post(cards: cards, to: vaultID)
  }

  private func resolvedStorage() throws -> Storage {
    if let storage {
      return storage
    }

    let layout = try explicitLayout ?? VaultStoreLayout.appGroup()
    let storage = Storage(
      catalog: try VaultCatalogStore.open(layout: layout),
      // Extensions must surface an open failure instead of applying the app's
      // pre-release destructive recovery policy from a short-lived process.
      registry: VaultStoreRegistry(layout: layout, openRecoveryPolicy: .failWithoutReset)
    )
    self.storage = storage
    return storage
  }
}

extension JournalPostingService {
  /// Validation failures reported by the shared posting boundary.
  public enum Error: Swift.Error, LocalizedError, Sendable {
    case emptyPost
    case invalidVaultIdentifier(String)
    case vaultNotFound(VaultID)
    case readOnlyVault(VaultID)

    public var errorDescription: String? {
      switch self {
      case .emptyPost:
        return "Add something before posting to Journal."
      case .invalidVaultIdentifier:
        return "The selected Journal Vault is invalid. Choose it again."
      case .vaultNotFound:
        return "The selected Journal Vault is no longer available."
      case .readOnlyVault:
        return "The selected Journal Vault is read-only. Choose a vault you can edit."
      }
    }
  }
}
