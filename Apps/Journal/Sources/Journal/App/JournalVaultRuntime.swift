import CloudKit
import Foundation
import JournalVault
import Observation
import SwiftData
import WidgetKit

/// App-process owner for the target vault persistence stack.
///
/// `TinycurveApp` creates one runtime for the process and injects it through the
/// SwiftUI environment. It owns the vault catalog, the per-vault instance
/// registry, and the sync engine; app UI reads and writes through the selected
/// vault instance.
@MainActor
@Observable
final class JournalVaultRuntime {

  /// Coarse lifecycle state for the vault runtime.
  enum State: Equatable {
    /// Stores and the sync service are being prepared.
    case starting

    /// The catalog is available and a selected vault can be opened.
    case ready

    /// Runtime setup failed. The associated value is a developer-facing error
    /// string because this state is currently exposed only from debug UI.
    case failed(String)
  }

  /// Coarse lifecycle state for the selected vault.
  enum SelectedVaultState: Equatable {
    /// No vault has been selected.
    case inactive

    /// The vault instance is being opened and activated with the sync layer.
    case opening

    /// A vault instance is available and ready for local reads/writes.
    case active

    /// Opening failed. The associated value is developer-facing debug copy.
    case failed(String)
  }

  /// Current lifecycle state.
  private(set) var state: State = .starting

  /// Catalog rows in picker order.
  private(set) var vaults: [VaultDescriptor] = []

  /// Last time the catalog snapshot was refreshed for display.
  private(set) var lastRefreshedAt: Date?

  /// Most recent non-fatal runtime message, shown in the debug surface.
  private(set) var lastMessage: String?

  /// Most recent first-launch availability decision.
  ///
  /// This is diagnostic state for launch routing and Settings. It is distinct
  /// from runtime readiness: a deferred CloudKit recovery can still be a
  /// resolved launch decision.
  private(set) var lastInitialAvailabilityResolution: VaultInitialAvailabilityResolution?

  /// Current selected-vault lifecycle state.
  private(set) var selectedVaultState: SelectedVaultState = .inactive

  /// The selected vault instance exposed to app screens.
  private(set) var selectedVault: VaultInstance?

  @ObservationIgnored private let catalogStore: VaultCatalogStore
  @ObservationIgnored private let registry: VaultStoreRegistry
  @ObservationIgnored private let instanceRegistry: VaultInstanceRegistry
  @ObservationIgnored private let syncEngine: any VaultSyncEngine
  @ObservationIgnored private var didStart = false

  init(
    catalogStore: VaultCatalogStore,
    registry: VaultStoreRegistry,
    syncEngine: any VaultSyncEngine
  ) {
    let instanceRegistry = VaultInstanceRegistry(
      storeRegistry: registry,
      syncEngine: syncEngine
    )

    self.catalogStore = catalogStore
    self.registry = registry
    self.instanceRegistry = instanceRegistry
    self.syncEngine = syncEngine
  }

  /// Creates the production runtime using the App Group vault layout and the
  /// CloudKit-backed sync boundary.
  static func appGroupCloudKitRuntime() throws -> JournalVaultRuntime {
    let layout = try VaultStoreLayout.appGroup()
    let catalogStore = try VaultCatalogStore.open(layout: layout)
    let registry = VaultStoreRegistry(layout: layout)
    let syncEngine = CloudKitVaultSyncEngine(
      layout: layout,
      catalog: catalogStore,
      registry: registry
    )
    return JournalVaultRuntime(
      catalogStore: catalogStore,
      registry: registry,
      syncEngine: syncEngine
    )
  }

  /// Creates an App Group runtime with the network-less logging sync engine.
  ///
  /// Keep this for previews, debug probes, and narrow tests that need durable
  /// vault stores without talking to CloudKit.
  static func appGroupLoggingRuntime() throws -> JournalVaultRuntime {
    let layout = try VaultStoreLayout.appGroup()
    let catalogStore = try VaultCatalogStore.open(layout: layout)
    let registry = VaultStoreRegistry(layout: layout)
    let syncEngine = LoggingVaultSyncEngine(registry: registry)
    return JournalVaultRuntime(
      catalogStore: catalogStore,
      registry: registry,
      syncEngine: syncEngine
    )
  }

  /// Creates a temporary runtime for SwiftUI previews.
  static func previewRuntime() -> JournalVaultRuntime {
    let layout = VaultStoreLayout(
      rootDirectoryURL: FileManager.default.temporaryDirectory.appending(
        path: "JournalVaultPreview-\(UUID().uuidString)",
        directoryHint: .isDirectory
      )
    )
    let registry = VaultStoreRegistry(layout: layout)
    let catalogStore = try! VaultCatalogStore.open(layout: layout)
    let syncEngine = LoggingVaultSyncEngine(registry: registry)
    return JournalVaultRuntime(
      catalogStore: catalogStore,
      registry: registry,
      syncEngine: syncEngine
    )
  }

  /// Starts the runtime service. Product UI opens a vault only after the user
  /// picks one.
  func start() async {
    guard didStart == false else { return }
    didStart = true
    state = .starting

    do {
      await syncEngine.start()
      try reloadCatalog()
      lastMessage = "Vault runtime started."

      state = .ready
    } catch {
      state = .failed(error.localizedDescription)
      lastMessage = error.localizedDescription
    }
  }

  /// Resolves the first-launch vault availability gate.
  ///
  /// This is intentionally narrower than "sync everything." It performs enough
  /// CloudKit discovery to decide whether a fresh install should recover
  /// existing vaults or continue from local-only state, then refreshes the local
  /// catalog for routing.
  func resolveInitialVaultAvailability() async -> VaultInitialAvailabilityResolution {
    await start()
    let resolution = await syncEngine.resolveInitialVaultAvailability()
    lastInitialAvailabilityResolution = resolution

    do {
      try reloadCatalog()
      lastMessage = resolution.displayMessage
      if case .failed = state, resolution.isResolved {
        state = .ready
      }
    } catch {
      lastMessage = error.localizedDescription
      return .unresolved(error.localizedDescription)
    }

    return resolution
  }

  /// Refreshes catalog rows and pending outbox display state.
  func refresh() async {
    do {
      try reloadCatalog()
      if let selectedVault,
        let updated = vaults.first(where: { $0.vaultID == selectedVault.vaultID })
      {
        selectedVault.updateDescriptor(updated)
      }
      refreshSelectedVaultPendingMutationCount()
      lastMessage = "Vault runtime refreshed."
      if case .failed = state {
        state = .ready
      }
    } catch {
      lastMessage = error.localizedDescription
    }
  }

  /// Reconciles local state after a Shortcuts or Share extension process may
  /// have committed cards while the app was inactive.
  ///
  /// The rescan is intentionally app-lifecycle owned: extensions only create
  /// durable local outbox rows and never start a competing CKSyncEngine.
  func resumeAfterExternalCapture() async {
    await start()
    await syncEngine.rescanPendingChanges()
    await refresh()
  }

  /// Selects a vault and asks its instance to enter foreground sync interest.
  func selectVault(_ vaultID: VaultID) async {
    if selectedVault?.vaultID == vaultID, selectedVaultState == .active {
      return
    }

    guard let descriptor = vaults.first(where: { $0.vaultID == vaultID }) else {
      lastMessage = "Vault not found."
      return
    }

    await openSelectedVault(descriptor)
    refreshSelectedVaultPendingMutationCount()
  }

  /// Prepares the system CloudKit sharing UI for one owned vault.
  ///
  /// CloudKit share creation and reuse stay in `VaultSyncEngine`; this runtime
  /// only refreshes catalog-facing state after the sync boundary saves the
  /// zone-wide share.
  func prepareShare(for vaultID: VaultID) async throws -> VaultSharePreparation {
    let preparation = try await syncEngine.prepareShare(for: vaultID)
    try reloadCatalog()
    refreshSelectedVaultDescriptor()
    lastMessage = "Prepared vault invite."
    return preparation
  }

  /// Accepts a CloudKit vault invite and refreshes local runtime state.
  ///
  /// UIKit delivers the invite metadata, but the app runtime keeps acceptance
  /// behind `VaultSyncEngine` so SwiftUI never performs CloudKit transport work.
  func acceptShare(metadata: CKShare.Metadata) async throws {
    await start()
    let acceptance = try await syncEngine.acceptShare(metadata: metadata)
    try reloadCatalog()
    refreshSelectedVaultDescriptor()
    refreshSelectedVaultPendingMutationCount()

    if let vaultID = acceptance.vaultID,
      let descriptor = vaults.first(where: { $0.vaultID == vaultID }),
      descriptor.title.isEmpty == false
    {
      lastMessage = "Accepted invite to \(descriptor.title)."
    } else {
      lastMessage = "Accepted vault invite."
    }

    if case .failed = state {
      state = .ready
    }
  }

  /// Clears local share summary after the system sharing UI stops sharing.
  func noteSharingStopped(for vaultID: VaultID) async {
    do {
      try catalogStore.applyShareInfo(
        vaultID: vaultID,
        isShared: false,
        shareURL: nil,
        shareRecordName: nil,
        participantCount: 1,
        permission: .owner
      )
      try reloadCatalog()
      lastMessage = "Stopped sharing vault."
    } catch {
      lastMessage = error.localizedDescription
    }
  }

  /// Creates a new owned local vault, refreshes the catalog, and opens it.
  ///
  /// The title is trimmed here so every UI entry point shares the same
  /// user-input boundary. Empty titles are rejected before any vault directory
  /// or catalog rows are created.
  @discardableResult
  func createVault(title rawTitle: String, icon: VaultIcon = .default) async -> VaultID? {
    let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    guard title.isEmpty == false else {
      lastMessage = "Vault title is required."
      return nil
    }

    do {
      let vaultID = try catalogStore.createVault(title: title, icon: icon, using: registry)
      try reloadCatalog()

      guard let descriptor = vaults.first(where: { $0.vaultID == vaultID }) else {
        selectedVault = nil
        selectedVaultState = .failed("Created vault was not found.")
        lastMessage = "Created vault was not found."
        return nil
      }

      await openSelectedVault(descriptor)
      refreshSelectedVaultPendingMutationCount()

      guard selectedVault?.vaultID == vaultID,
        selectedVaultState == .active
      else {
        lastMessage = selectedVaultState.displayDetail ?? "Created vault could not be opened."
        return nil
      }

      lastMessage = "Created \(title)."
      return vaultID
    } catch {
      lastMessage = error.localizedDescription
      return nil
    }
  }

  /// Updates a writable vault's shared icon and refreshes dependent UI state.
  func updateVaultIcon(vaultID: VaultID, icon: VaultIcon) async -> Bool {
    guard let descriptor = vaults.first(where: { $0.vaultID == vaultID }) else {
      lastMessage = "Vault not found."
      return false
    }

    guard descriptor.permission != .readOnly else {
      lastMessage = "This vault is read-only."
      return false
    }

    do {
      let store = try registry.store(for: vaultID)
      try store.updateVaultIcon(icon, title: descriptor.title)
      try catalogStore.updateVaultIcon(vaultID: vaultID, icon: icon)
      try reloadCatalog()
      refreshSelectedVaultDescriptor()
      refreshSelectedVaultPendingMutationCount()
      WidgetCenter.shared.reloadTimelines(ofKind: JournalWidgetKind.latestNote)
      lastMessage = "Updated vault icon."
      return true
    } catch {
      lastMessage = error.localizedDescription
      return false
    }
  }

  /// Renames a writable vault and refreshes all title-bearing UI surfaces.
  ///
  /// The vault store write updates the sync-visible `VaultInfo` row; the catalog
  /// write mirrors that title into the lightweight picker/widget metadata.
  func renameVault(vaultID: VaultID, title rawTitle: String) async -> Bool {
    let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
    guard title.isEmpty == false else {
      lastMessage = "Vault title is required."
      return false
    }

    guard let descriptor = vaults.first(where: { $0.vaultID == vaultID }) else {
      lastMessage = "Vault not found."
      return false
    }

    guard descriptor.permission != .readOnly else {
      lastMessage = "This vault is read-only."
      return false
    }

    do {
      let store = try registry.store(for: vaultID)
      try store.renameVault(title: title)
      try catalogStore.renameVault(vaultID: vaultID, title: title)
      try reloadCatalog()
      refreshSelectedVaultDescriptor()
      refreshSelectedVaultPendingMutationCount()
      WidgetCenter.shared.reloadTimelines(ofKind: JournalWidgetKind.latestNote)
      lastMessage = "Renamed vault."
      return true
    } catch {
      lastMessage = error.localizedDescription
      return false
    }
  }

  /// Deletes a vault after the sync boundary has removed its CloudKit zone.
  ///
  /// The remote delete runs first so a transient CloudKit failure doesn't leave
  /// only local state removed; otherwise launch recovery could discover the
  /// still-existing zone and bring the vault back.
  @discardableResult
  func deleteVault(_ descriptor: VaultDescriptor) async -> Bool {
    let isDeletingSelectedVault = selectedVault?.vaultID == descriptor.vaultID
    let deletedVaultIndex = vaults.firstIndex { $0.vaultID == descriptor.vaultID }

    do {
      try await syncEngine.deleteVault(descriptor)

      instanceRegistry.discardInstance(for: descriptor.vaultID)
      registry.discardStore(for: descriptor.vaultID)
      try catalogStore.layout.removeVaultDirectory(for: descriptor.vaultID)
      try catalogStore.deleteVault(vaultID: descriptor.vaultID)
      try reloadCatalog()

      if isDeletingSelectedVault {
        selectedVault = nil
        selectedVaultState = .inactive

        if let fallbackDescriptor = deletionFallbackDescriptor(
          deletedVaultIndex: deletedVaultIndex
        ) {
          await openSelectedVault(fallbackDescriptor)
        }
      }

      WidgetCenter.shared.reloadTimelines(ofKind: JournalWidgetKind.latestNote)
      if case .failed = selectedVaultState {
        // Preserve the fallback-open error so the Home recovery state can show it.
      } else {
        lastMessage = "Deleted \(descriptor.title)."
      }
      if case .failed = state {
        state = .ready
      }
      return true
    } catch {
      lastMessage = error.localizedDescription
      return false
    }
  }

  /// Estimates Journal's CloudKit payload across all locally known vaults.
  ///
  /// This opens each vault's local content store and reads only SwiftData rows;
  /// it doesn't query CloudKit because CloudKit doesn't expose account usage
  /// totals to client apps.
  func cloudStorageEstimate() throws -> JournalCloudStorageEstimate {
    try reloadCatalog()
    let vaultEstimates = try vaults.map { descriptor in
      let store = try registry.store(for: descriptor.vaultID)
      return JournalVaultCloudStorageEstimate(
        descriptor: descriptor,
        estimate: try store.cloudStorageEstimate()
      )
    }
    return JournalCloudStorageEstimate(generatedAt: Date(), vaults: vaultEstimates)
  }

  #if DEBUG
    /// Writes one text card into the selected vault.
    ///
    /// This is a debug-only probe for the vault runtime milestone: it proves a
    /// local write reaches `VaultContentStore`, creates `PendingMutation` rows, and
    /// wakes the sync engine through `VaultStoreRegistry`.
    func createDebugTextCard() async {
      guard let vault = selectedVault else {
        lastMessage = "Open a vault before writing a debug entry."
        return
      }

      do {
        let timestamp = Date().formatted(date: .abbreviated, time: .standard)
        try vault.createThread(cards: [
          VaultContentStore.CardDraft(
            kind: .text,
            text: "Vault runtime debug entry\n\(timestamp)"
          )
        ])
        await vault.activateForeground()
        refreshSelectedVaultPendingMutationCount()
        lastMessage = "Wrote a debug entry to \(vault.title)."
      } catch {
        lastMessage = error.localizedDescription
      }
    }
  #endif

  private func openSelectedVault(_ descriptor: VaultDescriptor) async {
    let previousVault = selectedVault
    let wasPreviouslyActive = previousVault != nil && selectedVaultState == .active

    if wasPreviouslyActive == false {
      selectedVaultState = .opening
    }

    do {
      let instance = try instanceRegistry.instance(for: descriptor)
      await instance.activateForeground()
      selectedVault = instance
      selectedVaultState = .active
    } catch {
      lastMessage = error.localizedDescription

      if wasPreviouslyActive, let previousVault {
        selectedVault = previousVault
        selectedVaultState = .active
      } else {
        selectedVault = nil
        selectedVaultState = .failed(error.localizedDescription)
      }
    }
  }

  /// Chooses the row that replaces a deleted active vault.
  ///
  /// The row that followed the deleted vault keeps its index; deleting the last
  /// row falls back to the new last row. An empty catalog intentionally returns
  /// `nil`, which is the Home screen's `noVault` state.
  private func deletionFallbackDescriptor(deletedVaultIndex: Int?) -> VaultDescriptor? {
    guard vaults.isEmpty == false else { return nil }

    let preferredIndex = min(deletedVaultIndex ?? 0, vaults.index(before: vaults.endIndex))
    return vaults[preferredIndex]
  }

  private func reloadCatalog() throws {
    vaults = try catalogStore.vaultDescriptors()
    lastRefreshedAt = Date()
  }

  private func refreshSelectedVaultDescriptor() {
    if let selectedVault,
      let updated = vaults.first(where: { $0.vaultID == selectedVault.vaultID })
    {
      selectedVault.updateDescriptor(updated)
    }
  }

  private func refreshSelectedVaultPendingMutationCount() {
    selectedVault?.refreshPendingMutationCount()
  }
}

/// Process-local owner of `VaultInstance` identity.
///
/// A vault has one local database and therefore one `VaultContentStore` /
/// `ModelContainer` in this process. The registry preserves that identity while
/// also attaching the UI-facing domain object that carries sync and permission
/// state for the same vault.
@MainActor
final class VaultInstanceRegistry {

  private let storeRegistry: VaultStoreRegistry
  private let syncEngine: any VaultSyncEngine
  private var instances: [VaultID: VaultInstance] = [:]

  init(storeRegistry: VaultStoreRegistry, syncEngine: any VaultSyncEngine) {
    self.storeRegistry = storeRegistry
    self.syncEngine = syncEngine
  }

  /// Returns the stable instance for a vault, opening its local database on first
  /// access and refreshing catalog metadata on later calls.
  func instance(for descriptor: VaultDescriptor) throws -> VaultInstance {
    if let instance = instances[descriptor.vaultID] {
      instance.updateDescriptor(descriptor)
      return instance
    }

    let instance = VaultInstance(
      descriptor: descriptor,
      contentStore: try storeRegistry.store(for: descriptor.vaultID),
      syncEngine: syncEngine
    )
    instances[descriptor.vaultID] = instance
    return instance
  }

  /// Releases the UI-facing object for a vault that was deleted.
  func discardInstance(for vaultID: VaultID) {
    _ = instances.removeValue(forKey: vaultID)
  }
}

/// UI-facing domain object for one vault.
///
/// `VaultInstance` is the object app screens are allowed to use directly. It
/// exposes the local SwiftData store and vault-scoped actions, while CloudKit
/// transport details stay behind the app-lifetime sync engine.
@MainActor
@Observable
final class VaultInstance {

  /// Latest catalog metadata for this vault.
  private(set) var descriptor: VaultDescriptor

  /// Number of unsent outbox rows in this vault's local database.
  private(set) var pendingMutationCount: Int?

  /// Local content database for the vault. Views observe SwiftData rows from
  /// this store; CloudKit is never read directly from SwiftUI.
  let contentStore: VaultContentStore

  @ObservationIgnored private let syncEngine: any VaultSyncEngine

  init(
    descriptor: VaultDescriptor,
    contentStore: VaultContentStore,
    syncEngine: any VaultSyncEngine
  ) {
    self.descriptor = descriptor
    self.contentStore = contentStore
    self.syncEngine = syncEngine
  }

  /// Stable vault identity.
  var vaultID: VaultID { descriptor.vaultID }

  /// User-facing vault title.
  var title: String { descriptor.title }

  /// User-facing vault icon.
  var icon: VaultIcon { descriptor.icon }

  /// Whether this device owns the CloudKit zone or participates in someone
  /// else's shared zone.
  var ownership: VaultOwnership { descriptor.ownership }

  /// Updates catalog metadata without reopening the local database.
  func updateDescriptor(_ descriptor: VaultDescriptor) {
    guard descriptor.vaultID == vaultID else { return }
    self.descriptor = descriptor
  }

  /// Declares foreground interest in this vault and refreshes its outbox count.
  func activateForeground() async {
    await syncEngine.activate(vaultID)
    refreshPendingMutationCount()
  }

  /// Saves a newly authored thread into this vault.
  @discardableResult
  func createThread(cards drafts: [VaultContentStore.CardDraft]) throws -> [CardEdge] {
    let edges = try contentStore.createThread(cards: drafts)
    refreshPendingMutationCount()
    return edges
  }

  /// Refreshes the cached outbox count used by debug and status surfaces.
  func refreshPendingMutationCount() {
    let context = ModelContext(contentStore.container)
    pendingMutationCount = try? context.fetchCount(FetchDescriptor<PendingMutation>())
  }
}

/// App-facing storage report for every vault Journal knows about locally.
///
/// The report deliberately says "estimate": CloudKit quota totals, exact server
/// overhead, and other apps' iCloud usage are outside the public CloudKit API.
struct JournalCloudStorageEstimate: Equatable {
  var generatedAt: Date
  var vaults: [JournalVaultCloudStorageEstimate]

  var estimatedPayloadBytes: Int {
    vaults.reduce(0) { $0 + $1.estimate.estimatedPayloadBytes }
  }

  var ownedEstimatedPayloadBytes: Int {
    vaults
      .filter { $0.descriptor.ownership == .owned }
      .reduce(0) { $0 + $1.estimate.estimatedPayloadBytes }
  }

  var participantEstimatedPayloadBytes: Int {
    vaults
      .filter { $0.descriptor.ownership == .participant }
      .reduce(0) { $0 + $1.estimate.estimatedPayloadBytes }
  }

  var mediaBytes: Int {
    vaults.reduce(0) { $0 + $1.estimate.mediaBytes }
  }

  var inlinePayloadBytes: Int {
    vaults.reduce(0) { $0 + $1.estimate.inlinePayloadBytes }
  }

  var cardBodyBytes: Int {
    vaults.reduce(0) { $0 + $1.estimate.cardBodyBytes }
  }

  var thumbnailBytes: Int {
    vaults.reduce(0) { $0 + $1.estimate.thumbnailBytes }
  }

  var recordCount: Int {
    vaults.reduce(0) { $0 + $1.estimate.recordCount }
  }

  var mediaBreakdowns: [VaultCloudStorageEstimate.MediaBreakdown] {
    var valuesByKind: [JournalVault.Attachment.Kind: (count: Int, byteSize: Int)] = [:]
    for vault in vaults {
      for breakdown in vault.estimate.mediaBreakdowns {
        let current = valuesByKind[breakdown.kind] ?? (count: 0, byteSize: 0)
        valuesByKind[breakdown.kind] = (
          count: current.count + breakdown.count,
          byteSize: current.byteSize + breakdown.byteSize
        )
      }
    }
    return JournalVault.Attachment.Kind.allCases.compactMap { kind in
      guard let value = valuesByKind[kind], value.count > 0 else { return nil }
      return VaultCloudStorageEstimate.MediaBreakdown(
        kind: kind,
        count: value.count,
        byteSize: value.byteSize
      )
    }
  }
}

/// One vault row inside a Journal-wide storage estimate.
struct JournalVaultCloudStorageEstimate: Identifiable, Equatable {
  var descriptor: VaultDescriptor
  var estimate: VaultCloudStorageEstimate

  var id: VaultID { descriptor.vaultID }
}

extension JournalVaultRuntime.State {

  /// Developer-facing label for the debug UI.
  var displayTitle: String {
    switch self {
    case .starting:
      "Starting"
    case .ready:
      "Ready"
    case .failed:
      "Failed"
    }
  }

  /// Developer-facing detail for the debug UI.
  var displayDetail: String? {
    switch self {
    case .starting, .ready:
      nil
    case .failed(let message):
      message
    }
  }
}

extension JournalVaultRuntime.SelectedVaultState {

  /// Developer-facing label for the debug UI.
  var displayTitle: String {
    switch self {
    case .inactive:
      "Inactive"
    case .opening:
      "Opening"
    case .active:
      "Active"
    case .failed:
      "Failed"
    }
  }

  /// Developer-facing detail for the debug UI.
  var displayDetail: String? {
    switch self {
    case .inactive, .opening, .active:
      nil
    case .failed(let message):
      message
    }
  }
}
