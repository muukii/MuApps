import CloudKit
import Foundation
import Testing

@testable import JournalVault

struct VaultNotificationPulseSubscriptionReconcilerTests {

  @Test
  func stableSubscriptionIDs_areUniqueAndScopeCorrect() throws {
    let identifiers = [
      VaultSyncEngineSubscription.privateDatabaseIdentifier,
      VaultSyncEngineSubscription.sharedDatabaseIdentifier,
      VaultNotificationPulseSubscription.privateDatabaseIdentifier,
      VaultNotificationPulseSubscription.sharedDatabaseIdentifier,
    ]
    let privateConfiguration = try #require(
      VaultNotificationPulseSubscriptionConfiguration.configuration(for: .private)
    )
    let sharedConfiguration = try #require(
      VaultNotificationPulseSubscriptionConfiguration.configuration(for: .shared)
    )

    #expect(Set(identifiers).count == identifiers.count)
    #expect(VaultSyncEngineSubscription.identifier(for: .private) == identifiers[0])
    #expect(VaultSyncEngineSubscription.identifier(for: .shared) == identifiers[1])
    #expect(VaultSyncEngineSubscription.identifier(for: .public) == nil)
    #expect(privateConfiguration.databaseScope == .private)
    #expect(privateConfiguration.identifier == identifiers[2])
    #expect(sharedConfiguration.databaseScope == .shared)
    #expect(sharedConfiguration.identifier == identifiers[3])
  }

  @Test(arguments: [CKDatabase.Scope.private, .shared])
  func subscriptionFactory_matchesPulseAlertContract(databaseScope: CKDatabase.Scope) throws {
    let configuration = try #require(
      VaultNotificationPulseSubscriptionConfiguration.configuration(for: databaseScope)
    )
    let subscription = configuration.makeSubscription()
    let notificationInfo = try #require(subscription.notificationInfo)

    #expect(subscription.subscriptionID == configuration.identifier)
    #expect(subscription.recordType == VaultRecordType.notificationPulse.rawValue)
    #expect(
      notificationInfo.titleLocalizationKey
        == VaultNotificationPulseSubscription.titleLocalizationKey)
    #expect(
      notificationInfo.alertLocalizationKey
        == VaultNotificationPulseSubscription.bodyLocalizationKey)
    #expect(notificationInfo.alertBody == nil)
    #expect(notificationInfo.title == nil)
    #expect(notificationInfo.soundName == "default")
    #expect(notificationInfo.shouldBadge == false)
    #expect(notificationInfo.shouldSendContentAvailable == false)
  }

  @Test
  func reconciler_createsMissingSubscriptionThenBecomesIdempotent() async throws {
    let store = TestSubscriptionStore()
    let reconciler = VaultNotificationPulseSubscriptionReconciler(store: store)

    #expect(try await reconciler.reconcile(databaseScope: .private) == .created)
    #expect(try await reconciler.reconcile(databaseScope: .private) == .unchanged)
    #expect(await store.saveCount() == 1)
  }

  @Test
  func reconciler_repairsMismatchedSubscriptionWithoutDeletingUnknownLegacySubscription()
    async throws
  {
    let configuration = try #require(
      VaultNotificationPulseSubscriptionConfiguration.configuration(for: .shared)
    )
    let mismatchedSubscription = CKDatabaseSubscription(subscriptionID: configuration.identifier)
    mismatchedSubscription.recordType = VaultRecordType.card.rawValue
    let mismatchedNotificationInfo = CKSubscription.NotificationInfo()
    mismatchedNotificationInfo.shouldBadge = true
    mismatchedSubscription.notificationInfo = mismatchedNotificationInfo
    let legacySubscription = CKDatabaseSubscription(subscriptionID: "legacy.subscription")
    let store = TestSubscriptionStore(
      subscriptions: [
        mismatchedSubscription.subscriptionID: mismatchedSubscription,
        legacySubscription.subscriptionID: legacySubscription,
      ]
    )
    let reconciler = VaultNotificationPulseSubscriptionReconciler(store: store)

    #expect(try await reconciler.reconcile(databaseScope: .shared) == .updated)
    let repairedSubscription = try #require(
      try await store.subscription(withID: configuration.identifier)
    )
    let preservedLegacySubscription = try #require(
      try await store.subscription(withID: legacySubscription.subscriptionID)
    )

    #expect(configuration.isEquivalent(to: repairedSubscription))
    #expect(preservedLegacySubscription.subscriptionID == legacySubscription.subscriptionID)
    #expect(await store.saveCount() == 1)
  }

  @Test
  func reconciliation_repeatsForFreshAccountScopedStores() async throws {
    let firstAccountPrivateStore = TestSubscriptionStore()
    let firstAccountSharedStore = TestSubscriptionStore()
    let secondAccountPrivateStore = TestSubscriptionStore()
    let secondAccountSharedStore = TestSubscriptionStore()

    #expect(
      try await VaultNotificationPulseSubscriptionReconciler(store: firstAccountPrivateStore)
        .reconcile(databaseScope: .private) == .created
    )
    #expect(
      try await VaultNotificationPulseSubscriptionReconciler(store: firstAccountSharedStore)
        .reconcile(databaseScope: .shared) == .created
    )
    #expect(
      try await VaultNotificationPulseSubscriptionReconciler(store: secondAccountPrivateStore)
        .reconcile(databaseScope: .private) == .created
    )
    #expect(
      try await VaultNotificationPulseSubscriptionReconciler(store: secondAccountSharedStore)
        .reconcile(databaseScope: .shared) == .created
    )

    #expect(await firstAccountPrivateStore.saveCount() == 1)
    #expect(await firstAccountSharedStore.saveCount() == 1)
    #expect(await secondAccountPrivateStore.saveCount() == 1)
    #expect(await secondAccountSharedStore.saveCount() == 1)
  }

  @Test(arguments: [CKDatabase.Scope.private, .shared])
  func reconciler_reportsMissingRecordTypeAsSchemaUnavailable(
    databaseScope: CKDatabase.Scope
  ) async throws {
    let store = TestSubscriptionStore(saveError: CKError(.unknownItem))
    let reconciler = VaultNotificationPulseSubscriptionReconciler(store: store)

    #expect(try await reconciler.reconcile(databaseScope: databaseScope) == .schemaUnavailable)
  }

  @Test
  func reconciler_reportsMissingRecordTypeInsidePartialFailureAsSchemaUnavailable() async throws {
    let partialFailure = CKError(
      .partialFailure,
      userInfo: [
        CKPartialErrorsByItemIDKey: [
          VaultNotificationPulseSubscription.privateDatabaseIdentifier:
            CKError(.unknownItem) as NSError
        ]
      ]
    )
    let store = TestSubscriptionStore(saveError: partialFailure)
    let reconciler = VaultNotificationPulseSubscriptionReconciler(store: store)

    #expect(try await reconciler.reconcile(databaseScope: .private) == .schemaUnavailable)
  }

  /// A transport failure must stay an error so the caller retries it, unlike the
  /// missing record type, which only a Pulse upload can resolve.
  @Test
  func reconciler_rethrowsUnrelatedSaveFailure() async throws {
    let store = TestSubscriptionStore(saveError: CKError(.networkUnavailable))
    let reconciler = VaultNotificationPulseSubscriptionReconciler(store: store)

    await #expect(throws: CKError.self) {
      try await reconciler.reconcile(databaseScope: .private)
    }
  }
}

/// In-memory account/database adapter that records only the exact subscription
/// IDs the reconciler saves. It intentionally has no delete API so tests prove
/// that unknown legacy subscription state cannot be removed by this boundary.
private actor TestSubscriptionStore: VaultNotificationPulseSubscriptionStore {

  private var subscriptions: [CKSubscription.ID: CKSubscription]
  private var savedSubscriptionIDs: [CKSubscription.ID] = []
  private let saveError: (any Error)?

  init(
    subscriptions: [CKSubscription.ID: CKSubscription] = [:],
    saveError: (any Error)? = nil
  ) {
    self.subscriptions = subscriptions
    self.saveError = saveError
  }

  func subscription(withID subscriptionID: CKSubscription.ID) -> CKSubscription? {
    subscriptions[subscriptionID]
  }

  func save(subscription: CKSubscription) throws {
    if let saveError {
      throw saveError
    }
    subscriptions[subscription.subscriptionID] = subscription
    savedSubscriptionIDs.append(subscription.subscriptionID)
  }

  func saveCount() -> Int {
    savedSubscriptionIDs.count
  }
}
