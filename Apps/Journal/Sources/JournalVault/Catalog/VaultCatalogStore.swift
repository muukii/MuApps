import Foundation
import SwiftData

/// Sendable snapshot of one catalog row, safe to hand to the sync engine.
public struct VaultDescriptor: Hashable, Sendable {
  /// Stable identifier for the vault and its CloudKit custom zone.
  public let vaultID: VaultID

  /// User-facing vault title shown in picker and sharing surfaces.
  public let title: String

  /// User-facing icon shown next to the vault title in lightweight surfaces.
  public let icon: VaultIcon

  /// Whether this device owns the vault zone or joined it through a share.
  public let ownership: VaultOwnership

  /// CloudKit owner name for participant vaults. `nil` for owned vaults.
  public let zoneOwnerName: String?

  /// Whether CloudKit currently has a share associated with this vault.
  public let isShared: Bool

  /// Share URL cached from CloudKit for lightweight presentation surfaces.
  public let shareURL: URL?

  /// CloudKit record name for the saved zone-wide `CKShare`, when known.
  public let shareRecordName: String?

  /// Number of known participants, including the owner.
  public let participantCount: Int

  /// Collapsed share permission for picker and settings display.
  public let permission: VaultPermissionSummary

  public init(
    vaultID: VaultID,
    title: String,
    icon: VaultIcon = .default,
    ownership: VaultOwnership,
    zoneOwnerName: String? = nil,
    isShared: Bool = false,
    shareURL: URL? = nil,
    shareRecordName: String? = nil,
    participantCount: Int = 1,
    permission: VaultPermissionSummary = .owner
  ) {
    self.vaultID = vaultID
    self.title = title
    self.icon = icon
    self.ownership = ownership
    self.zoneOwnerName = zoneOwnerName
    self.isShared = isShared
    self.shareURL = shareURL
    self.shareRecordName = shareRecordName
    self.participantCount = participantCount
    self.permission = permission
  }
}

/// The small catalog store behind the vault picker, launch routing, and widget
/// summaries. Holds no card content — those live in each vault's own
/// `VaultContentStore`.
///
/// CloudKit mirroring is disabled here too: how much of the catalog should sync
/// between the user's own devices is an open design question, and vaults
/// discovered remotely are materialized by the sync engine anyway.
public struct VaultCatalogStore: Sendable {

  public static let schema = Schema([
    VaultIndex.self,
    VaultLocalState.self,
    VaultSummary.self,
  ])

  public let container: ModelContainer
  public let layout: VaultStoreLayout

  /// Opens (creating on first launch) the catalog store at
  /// `layout.catalogStoreURL`.
  public static func open(layout: VaultStoreLayout) throws -> VaultCatalogStore {
    try layout.ensureRootDirectories()
    let configuration = ModelConfiguration(
      schema: schema,
      url: layout.catalogStoreURL,
      cloudKitDatabase: .none
    )
    let container = try ModelContainer(for: schema, configurations: configuration)
    return VaultCatalogStore(container: container, layout: layout)
  }
}

// MARK: - Reading

extension VaultCatalogStore {

  /// All known vaults in picker order.
  @MainActor
  public func vaultDescriptors() throws -> [VaultDescriptor] {
    let descriptor = FetchDescriptor<VaultIndex>(sortBy: [SortDescriptor(\.sortIndex)])
    return try container.mainContext.fetch(descriptor).map { index in
      let vaultID = VaultID(rawValue: index.vaultID)
      let summary = try fetchSummary(vaultID: vaultID, in: container.mainContext)
      return VaultDescriptor(
        vaultID: vaultID,
        title: index.title,
        icon: index.icon,
        ownership: index.ownership,
        zoneOwnerName: index.zoneOwnerName,
        isShared: summary?.isShared ?? (index.ownership == .participant),
        shareURL: summary?.shareURL.flatMap(URL.init(string:)),
        shareRecordName: summary?.shareRecordName,
        participantCount: max(1, summary?.participantCount ?? 1),
        permission: summary?.permission ?? {
          switch index.ownership {
          case .owned:
            return .owner
          case .participant:
            return .readWrite
          }
        }()
      )
    }
  }
}

// MARK: - Writing

extension VaultCatalogStore {

  /// Creates a new owned vault: its directory, content store, seeded
  /// `VaultInfo` row (queued for upload), and the catalog rows.
  ///
  /// The CloudKit zone is **not** created here — the sync engine creates it
  /// lazily when the vault's first record upload reports `zoneNotFound`.
  ///
  /// Ordering note: the content store is seeded before the catalog rows are
  /// saved. A crash in between leaves an orphan vault directory, which is inert
  /// — the catalog is the source of truth for which vaults exist.
  @MainActor
  @discardableResult
  public func createVault(title: String, icon: VaultIcon = .default, using registry: VaultStoreRegistry) throws -> VaultID {
    let vaultID = VaultID()
    try layout.ensureVaultDirectories(for: vaultID)

    let store = try registry.store(for: vaultID)
    try store.seedVaultInfo(title: title, icon: icon)

    let context = container.mainContext
    context.insert(
      VaultIndex(
        vaultID: vaultID.rawValue,
        title: title,
        icon: icon,
        ownership: .owned,
        sortIndex: try nextSortIndex(in: context)
      )
    )
    context.insert(VaultLocalState(vaultID: vaultID.rawValue))
    context.insert(VaultSummary(vaultID: vaultID.rawValue, title: title))
    try context.save()
    return vaultID
  }

  /// Materializes catalog rows for a vault discovered remotely — a zone fetched
  /// from CloudKit that this device has no row for (created on the user's other
  /// device, or a newly joined share). Idempotent.
  ///
  /// The title is typically empty at this point; it arrives with the vault's
  /// `VaultInfo` record via `applyImportedVaultInfo`.
  @MainActor
  public func materializeRemoteVault(_ descriptor: VaultDescriptor) throws {
    let context = container.mainContext
    guard try fetchIndex(vaultID: descriptor.vaultID, in: context) == nil else { return }
    try layout.ensureVaultDirectories(for: descriptor.vaultID)

    context.insert(
      VaultIndex(
        vaultID: descriptor.vaultID.rawValue,
        title: descriptor.title,
        icon: descriptor.icon,
        ownership: descriptor.ownership,
        zoneOwnerName: descriptor.zoneOwnerName,
        sortIndex: try nextSortIndex(in: context)
      )
    )
    context.insert(VaultLocalState(vaultID: descriptor.vaultID.rawValue))
    context.insert(
      VaultSummary(
        vaultID: descriptor.vaultID.rawValue,
        title: descriptor.title,
        // A participant vault is by definition shared; permission details
        // arrive later with the share metadata.
        isShared: descriptor.ownership == .participant,
        permission: {
          switch descriptor.ownership {
          case .owned:
            return .owner
          case .participant:
            return .readWrite
          }
        }()
      )
    )
    try context.save()
  }

  /// Applies display metadata imported from a vault's `VaultInfo` record.
  ///
  /// `icon == nil` means the remote record predates synchronized icons; in
  /// that case the catalog keeps its existing local icon.
  @MainActor
  public func applyImportedVaultInfo(
    vaultID: VaultID,
    title: String,
    icon: VaultIcon? = nil
  ) throws {
    let context = container.mainContext
    guard let index = try fetchIndex(vaultID: vaultID, in: context) else { return }
    index.title = title
    if let icon {
      index.iconKindRawValue = icon.kind.rawValue
      index.iconValue = icon.value
    }
    if let summary = try fetchSummary(vaultID: vaultID, in: context) {
      summary.title = title
    }
    try context.save()
  }

  /// Updates the local catalog title used by picker, widgets, and settings.
  ///
  /// This does not touch the vault content store. Callers that are changing the
  /// shared vault title should update `VaultInfo` first, then mirror that title
  /// into the catalog through this method.
  @MainActor
  public func renameVault(vaultID: VaultID, title: String) throws {
    let context = container.mainContext
    guard let index = try fetchIndex(vaultID: vaultID, in: context) else { return }

    index.title = title
    if let summary = try fetchSummary(vaultID: vaultID, in: context) {
      summary.title = title
    }
    try context.save()
  }

  /// Mirrors the shared vault icon into picker, widget, and launch surfaces.
  ///
  /// This method does not enqueue CloudKit work. Callers must update the
  /// content store's `VaultInfo` first, matching `renameVault`.
  @MainActor
  public func updateVaultIcon(vaultID: VaultID, icon: VaultIcon) throws {
    let context = container.mainContext
    guard let index = try fetchIndex(vaultID: vaultID, in: context) else { return }
    index.iconKindRawValue = icon.kind.rawValue
    index.iconValue = icon.value
    try context.save()
  }

  /// Records that the sync layer finished importing remote changes.
  @MainActor
  public func noteVaultSynced(_ vaultID: VaultID, at date: Date = Date()) throws {
    let context = container.mainContext
    guard let localState = try fetchLocalState(vaultID: vaultID, in: context) else { return }
    localState.lastSyncedAt = date
    try context.save()
  }

  /// Removes a vault from the local catalog.
  ///
  /// This deletes only catalog-facing rows (`VaultIndex`, `VaultLocalState`,
  /// `VaultSummary`). The vault's content store directory and CloudKit zone are
  /// separate boundaries owned by `VaultStoreLayout` and `VaultSyncEngine`.
  @MainActor
  public func deleteVault(vaultID: VaultID) throws {
    let context = container.mainContext
    guard let index = try fetchIndex(vaultID: vaultID, in: context) else { return }

    if let localState = try fetchLocalState(vaultID: vaultID, in: context) {
      context.delete(localState)
    }
    if let summary = try fetchSummary(vaultID: vaultID, in: context) {
      context.delete(summary)
    }
    context.delete(index)
    try context.save()
  }

  /// Persists the latest CloudKit share summary for lightweight UI surfaces.
  ///
  /// `VaultSummary` stores only display and routing metadata. The live
  /// `CKShare` stays owned by `VaultSyncEngine`, and participant membership is
  /// refreshed by the sharing flow as the system UI saves changes.
  @MainActor
  public func applyShareInfo(
    vaultID: VaultID,
    isShared: Bool,
    shareURL: URL?,
    shareRecordName: String?,
    participantCount: Int,
    permission: VaultPermissionSummary
  ) throws {
    let context = container.mainContext
    guard let summary = try fetchSummary(vaultID: vaultID, in: context) else { return }
    summary.isShared = isShared
    summary.shareURL = shareURL?.absoluteString
    summary.shareRecordName = shareRecordName
    summary.participantCount = participantCount
    summary.permission = permission
    try context.save()
  }

  // MARK: - Fetch helpers

  @MainActor
  private func nextSortIndex(in context: ModelContext) throws -> Int {
    let indices = try context.fetch(FetchDescriptor<VaultIndex>())
    return (indices.map(\.sortIndex).max() ?? -1) + 1
  }

  @MainActor
  private func fetchIndex(vaultID: VaultID, in context: ModelContext) throws -> VaultIndex? {
    let rawValue = vaultID.rawValue
    var descriptor = FetchDescriptor<VaultIndex>(predicate: #Predicate { $0.vaultID == rawValue })
    descriptor.fetchLimit = 1
    return try context.fetch(descriptor).first
  }

  @MainActor
  private func fetchSummary(vaultID: VaultID, in context: ModelContext) throws -> VaultSummary? {
    let rawValue = vaultID.rawValue
    var descriptor = FetchDescriptor<VaultSummary>(predicate: #Predicate { $0.vaultID == rawValue })
    descriptor.fetchLimit = 1
    return try context.fetch(descriptor).first
  }

  @MainActor
  private func fetchLocalState(vaultID: VaultID, in context: ModelContext) throws -> VaultLocalState? {
    let rawValue = vaultID.rawValue
    var descriptor = FetchDescriptor<VaultLocalState>(predicate: #Predicate { $0.vaultID == rawValue })
    descriptor.fetchLimit = 1
    return try context.fetch(descriptor).first
  }
}

private extension VaultIndex {

  /// Decoded icon with a stable fallback for catalog rows created before icons.
  var icon: VaultIcon {
    guard
      let rawKind = iconKindRawValue,
      let kind = VaultIcon.Kind(rawValue: rawKind),
      let iconValue
    else {
      return .default
    }
    return VaultIcon(kind: kind, value: iconValue)
  }
}
