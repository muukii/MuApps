import CloudKit
import Foundation
import OSLog
import SwiftData

/// Saved CloudKit share payload ready for `UICloudSharingController`.
///
/// The sync engine returns this only after the zone-wide `CKShare` has been
/// saved in CloudKit. UIKit owns the presentation details; app views receive
/// this prepared value and never create or save CloudKit shares themselves.
public struct VaultSharePreparation: @unchecked Sendable {
  public let share: CKShare
  public let container: CKContainer

  public init(share: CKShare, container: CKContainer) {
    self.share = share
    self.container = container
  }
}

/// Result of accepting a CloudKit vault share invitation.
///
/// The accepted `CKShare` is useful for diagnostics and future permission UI,
/// while `vaultID` is present only when the share's zone follows Journal's vault
/// zone naming scheme.
public struct VaultShareAcceptance: @unchecked Sendable {
  public let share: CKShare
  public let vaultID: VaultID?

  public init(share: CKShare, vaultID: VaultID?) {
    self.share = share
    self.vaultID = vaultID
  }
}

/// Result of resolving which vault state this installation should start from.
///
/// This is a launch-routing concern, not a "CloudKit is fully synced" signal.
/// The first app launch blocks on this resolution so a reinstall can discover
/// existing iCloud vaults. Later launches still start the sync engine, but the
/// UI can route from cached local state while CloudKit catches up.
public enum VaultInitialAvailabilityResolution: Equatable, Sendable {
  /// CloudKit was available and the engine performed the initial vault discovery pass.
  case resolvedWithCloudKit

  /// CloudKit cannot be used by this user or environment, so the app can begin
  /// from local-only state instead of blocking forever.
  case resolvedWithoutICloud(String)

  /// CloudKit might become available later, but the app should not keep
  /// blocking first-launch routing. Background sync can recover vaults later.
  case resolvedWithDeferredCloudKit(String)

  /// Local runtime setup failed before the app could start from any vault state.
  case unresolved(String)

  /// Whether the app may stop showing the blocking first-launch loading state.
  public var isResolved: Bool {
    switch self {
    case .resolvedWithCloudKit, .resolvedWithoutICloud, .resolvedWithDeferredCloudKit:
      true
    case .unresolved:
      false
    }
  }

  /// Whether iCloud discovery was intentionally deferred after launch routing.
  public var isCloudKitDeferred: Bool {
    if case .resolvedWithDeferredCloudKit = self { return true }
    return false
  }

  /// Developer-facing status title for diagnostics.
  public var displayTitle: String {
    switch self {
    case .resolvedWithCloudKit:
      "iCloud checked"
    case .resolvedWithoutICloud:
      "Local-only"
    case .resolvedWithDeferredCloudKit:
      "iCloud recovery deferred"
    case .unresolved:
      "Unresolved"
    }
  }

  /// Developer-facing reason text when the resolution carries one.
  public var displayDetail: String? {
    switch self {
    case .resolvedWithCloudKit:
      nil
    case .resolvedWithoutICloud(let reason),
      .resolvedWithDeferredCloudKit(let reason),
      .unresolved(let reason):
      reason
    }
  }

  /// Developer-facing summary for debug surfaces and runtime messages.
  public var displayMessage: String {
    switch self {
    case .resolvedWithCloudKit:
      "Resolved initial vault availability with iCloud."
    case .resolvedWithoutICloud(let reason):
      "Resolved initial vault availability without iCloud: \(reason)"
    case .resolvedWithDeferredCloudKit(let reason):
      "Resolved initial vault availability with deferred iCloud recovery: \(reason)"
    case .unresolved(let reason):
      "Initial vault availability unresolved: \(reason)"
    }
  }
}

/// User-facing failures for vault invite issuance.
public enum VaultSharePreparationError: Error, LocalizedError, Sendable {
  case unsupportedBySyncEngine
  case vaultNotFound(VaultID)
  case participantVault(VaultID)
  case shareRecordTypeMismatch

  public var errorDescription: String? {
    switch self {
    case .unsupportedBySyncEngine:
      "This sync engine does not support vault sharing."
    case .vaultNotFound:
      "The selected vault could not be found."
    case .participantVault:
      "Only vaults owned by you can issue invites."
    case .shareRecordTypeMismatch:
      "The existing CloudKit share record was not a zone-wide share."
    }
  }
}

/// User-facing failures for accepting vault share invitations.
public enum VaultShareAcceptanceError: Error, LocalizedError, Sendable {
  case unsupportedBySyncEngine
  case missingAcceptedShareResult
  case sharedSyncEngineUnavailable
  case acceptFailed(String)

  public var errorDescription: String? {
    switch self {
    case .unsupportedBySyncEngine:
      "This sync engine does not support accepting vault invites."
    case .missingAcceptedShareResult:
      "CloudKit did not return an accepted share for the invite."
    case .sharedSyncEngineUnavailable:
      "The shared CloudKit sync engine is not available."
    case .acceptFailed(let message):
      "Could not accept the vault invite: \(message)"
    }
  }
}

/// The explicit sync boundary that owns CloudKit for vault stores.
///
/// Screens never read CloudKit; they observe SwiftData. Implementations import
/// remote changes into vault content stores and drain the stores'
/// `PendingMutation` outboxes to CloudKit. Local mutations reach the engine
/// through `VaultStoreRegistry.localMutations()`, not through this protocol —
/// stores don't know the engine exists.
public protocol VaultSyncEngine: Sendable {

  /// Brings the engine up as an app-lifetime service. Idempotent.
  func start() async

  /// Resolves whether this installation should start from recovered iCloud
  /// vaults or local-only state.
  ///
  /// This is the only sync operation that may block first-launch routing. It
  /// should not mean that all records or assets are up to date.
  func resolveInitialVaultAvailability() async -> VaultInitialAvailabilityResolution

  /// Declares foreground interest in one vault (its screen was opened): kick a
  /// fetch for its zone and push any pending changes it still holds.
  func activate(_ vaultID: VaultID) async

  /// Creates or reuses the saved zone-wide share for an owned vault.
  func prepareShare(for vaultID: VaultID) async throws -> VaultSharePreparation

  /// Accepts a zone-wide CloudKit vault share and imports its shared database
  /// changes into the local vault stores.
  func acceptShare(metadata: CKShare.Metadata) async throws -> VaultShareAcceptance
}

/// Network-less stand-in for the CloudKit engine: logs what the real
/// implementation would do. Useful in previews and tests, and for verifying
/// that local writes land in the `PendingMutation` outbox before any transport
/// exists (the Phase 1 milestone of the vault design).
public actor LoggingVaultSyncEngine: VaultSyncEngine {

  private let registry: VaultStoreRegistry
  private let log = Logger(subsystem: "app.muukii.journal", category: "VaultSync")
  private var observationTask: Task<Void, Never>?

  public init(registry: VaultStoreRegistry) {
    self.registry = registry
  }

  public func start() async {
    guard observationTask == nil else { return }
    log.info("start — logging stub, no CloudKit transport")
    observationTask = Task { [registry, log] in
      for await vaultID in registry.localMutations() {
        let depth = (try? Self.pendingMutationCount(in: registry, vaultID: vaultID)) ?? 0
        log.info(
          "local mutation in vault \(vaultID.uuidString, privacy: .public); outbox depth \(depth)"
        )
      }
    }
  }

  public func resolveInitialVaultAvailability() async -> VaultInitialAvailabilityResolution {
    await start()
    return .resolvedWithoutICloud("CloudKit transport is not configured for this runtime.")
  }

  public func activate(_ vaultID: VaultID) async {
    log.info("activate vault \(vaultID.uuidString, privacy: .public) — no transport to kick")
  }

  public func prepareShare(for vaultID: VaultID) async throws -> VaultSharePreparation {
    throw VaultSharePreparationError.unsupportedBySyncEngine
  }

  public func acceptShare(metadata: CKShare.Metadata) async throws -> VaultShareAcceptance {
    throw VaultShareAcceptanceError.unsupportedBySyncEngine
  }

  private static func pendingMutationCount(
    in registry: VaultStoreRegistry,
    vaultID: VaultID
  ) throws -> Int {
    let store = try registry.store(for: vaultID)
    let context = ModelContext(store.container)
    return try context.fetchCount(FetchDescriptor<PendingMutation>())
  }
}
