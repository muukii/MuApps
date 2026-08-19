import CloudKit
import Foundation

/// Stable IDs for the silent `CKSyncEngine` database subscriptions.
///
/// These IDs intentionally do not overlap with `VaultNotificationPulseSubscription`.
/// Giving each `CKSyncEngine` its own ID prevents automatic subscription discovery
/// from adopting the participant-visible Pulse subscription as a silent sync wake-up.
public nonisolated enum VaultSyncEngineSubscription {

  /// Silent subscription for the owner's private CloudKit database.
  public static let privateDatabaseIdentifier = "tinycurve.vault-sync.private.v1"

  /// Silent subscription for participant Vaults in the shared CloudKit database.
  public static let sharedDatabaseIdentifier = "tinycurve.vault-sync.shared.v1"

  /// Returns the silent sync subscription ID for a database scope that Tinycurve
  /// synchronizes. The public database is intentionally outside the Vault sync
  /// contract and has no corresponding `CKSyncEngine` subscription.
  public static func identifier(for databaseScope: CKDatabase.Scope) -> CKSubscription.ID? {
    switch databaseScope {
    case .private:
      privateDatabaseIdentifier
    case .shared:
      sharedDatabaseIdentifier
    case .public:
      nil
    @unknown default:
      nil
    }
  }
}

/// The exact server-side shape of one participant-visible Pulse subscription.
///
/// A CloudKit subscription is scoped by the `CKDatabase` that saves it, rather
/// than by a field on the subscription itself. Keeping `databaseScope` in this
/// value makes that ownership explicit to the reconciliation caller and tests.
struct VaultNotificationPulseSubscriptionConfiguration: Equatable, Sendable {

  /// CloudKit's documented token for the system notification sound.
  static let defaultSoundName = "default"

  let databaseScope: CKDatabase.Scope
  let identifier: CKSubscription.ID
  let recordType: CKRecord.RecordType
  let titleLocalizationKey: String
  let bodyLocalizationKey: String

  /// Returns a supported private/shared configuration, or `nil` for a database
  /// scope that Tinycurve does not use for Vault synchronization.
  static func configuration(for databaseScope: CKDatabase.Scope) -> Self? {
    let identifier: CKSubscription.ID

    switch databaseScope {
    case .private:
      identifier = VaultNotificationPulseSubscription.privateDatabaseIdentifier
    case .shared:
      identifier = VaultNotificationPulseSubscription.sharedDatabaseIdentifier
    case .public:
      return nil
    @unknown default:
      return nil
    }

    return Self(
      databaseScope: databaseScope,
      identifier: identifier,
      recordType: VaultRecordType.notificationPulse.rawValue,
      titleLocalizationKey: VaultNotificationPulseSubscription.titleLocalizationKey,
      bodyLocalizationKey: VaultNotificationPulseSubscription.bodyLocalizationKey
    )
  }

  /// Builds the subscription record that CloudKit stores in one database scope.
  func makeSubscription() -> CKDatabaseSubscription {
    let subscription = CKDatabaseSubscription(subscriptionID: identifier)
    subscription.recordType = recordType

    let notificationInfo = CKSubscription.NotificationInfo()
    notificationInfo.titleLocalizationKey = titleLocalizationKey
    notificationInfo.alertLocalizationKey = bodyLocalizationKey
    notificationInfo.soundName = Self.defaultSoundName
    notificationInfo.shouldBadge = false
    notificationInfo.shouldSendContentAvailable = false
    subscription.notificationInfo = notificationInfo

    return subscription
  }

  /// Whether a server subscription already matches the required visible Pulse
  /// transport shape. Unrelated details are deliberately not compared: the
  /// reconciliation contract only owns the record filter and alert delivery
  /// fields declared by this configuration.
  func isEquivalent(to candidate: CKSubscription) -> Bool {
    guard
      candidate.subscriptionID == identifier,
      let candidate = candidate as? CKDatabaseSubscription,
      candidate.recordType == recordType,
      let notificationInfo = candidate.notificationInfo
    else {
      return false
    }

    return notificationInfo.titleLocalizationKey == titleLocalizationKey
      && notificationInfo.alertLocalizationKey == bodyLocalizationKey
      && notificationInfo.soundName == Self.defaultSoundName
      && notificationInfo.shouldBadge == false
      && notificationInfo.shouldSendContentAvailable == false
  }
}

/// The narrow database boundary used to test subscription reconciliation without
/// a signed iCloud account or mutable CloudKit server state.
protocol VaultNotificationPulseSubscriptionStore: Sendable {

  /// Returns only the subscription whose stable identifier Tinycurve owns.
  /// `nil` means that exact record is absent; callers never enumerate or delete
  /// unknown subscriptions.
  func subscription(withID subscriptionID: CKSubscription.ID) async throws -> CKSubscription?

  /// Creates or updates a subscription with a Tinycurve-owned stable ID.
  func save(subscription: CKSubscription) async throws
}

/// The observable result of reconciling one account-scoped database subscription.
enum VaultNotificationPulseSubscriptionReconciliationOutcome: String, Equatable, Sendable {
  case created
  case updated
  case unchanged
  case unsupportedScope
}

/// Idempotently owns only Tinycurve's visible Pulse subscription in one database.
///
/// The caller supplies an adapter bound to the current CloudKit account and
/// database scope. This keeps retries account-scoped and guarantees that a
/// mismatch under one of Tinycurve's IDs can be repaired without touching any
/// unknown legacy subscription.
struct VaultNotificationPulseSubscriptionReconciler<Store: VaultNotificationPulseSubscriptionStore>:
  Sendable
{

  let store: Store

  func reconcile(
    databaseScope: CKDatabase.Scope
  ) async throws -> VaultNotificationPulseSubscriptionReconciliationOutcome {
    guard
      let configuration = VaultNotificationPulseSubscriptionConfiguration.configuration(
        for: databaseScope
      )
    else {
      return .unsupportedScope
    }

    guard let existingSubscription = try await store.subscription(withID: configuration.identifier)
    else {
      try await store.save(subscription: configuration.makeSubscription())
      return .created
    }

    guard configuration.isEquivalent(to: existingSubscription) == false else {
      return .unchanged
    }

    try await store.save(subscription: configuration.makeSubscription())
    return .updated
  }
}

/// Production adapter for a single CloudKit database in the current account.
struct CloudKitDatabaseSubscriptionStore: VaultNotificationPulseSubscriptionStore {

  let database: CKDatabase

  func subscription(withID subscriptionID: CKSubscription.ID) async throws -> CKSubscription? {
    do {
      return try await database.subscription(for: subscriptionID)
    } catch let error as CKError where error.code == .unknownItem {
      return nil
    }
  }

  func save(subscription: CKSubscription) async throws {
    let result = try await database.modifySubscriptions(
      saving: [subscription],
      deleting: []
    )
    guard let saveResult = result.saveResults[subscription.subscriptionID] else {
      throw CloudKitDatabaseSubscriptionStoreError.missingSaveResult(subscription.subscriptionID)
    }
    _ = try saveResult.get()
  }
}

private enum CloudKitDatabaseSubscriptionStoreError: LocalizedError {
  case missingSaveResult(CKSubscription.ID)

  var errorDescription: String? {
    switch self {
    case .missingSaveResult(let subscriptionID):
      "CloudKit did not return a save result for subscription \(subscriptionID)."
    }
  }
}
