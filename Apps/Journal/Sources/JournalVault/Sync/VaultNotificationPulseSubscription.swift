import Foundation

/// Stable CloudKit database-subscription identities for visible Vault Pulse
/// notifications.
///
/// These subscriptions are deliberately separate from the silent
/// `CKSyncEngine` subscriptions. The app process uses the same identifiers to
/// recognize the direct CloudKit push that may be shown while Tinycurve is in
/// the foreground. Subscription creation remains owned by the sync layer.
public nonisolated enum VaultNotificationPulseSubscription {

  /// Visible Pulse subscription for the owner's private CloudKit database.
  public static let privateDatabaseIdentifier = "tinycurve.vault-pulse.private.v1"

  /// Visible Pulse subscription for participant Vaults in the shared database.
  public static let sharedDatabaseIdentifier = "tinycurve.vault-pulse.shared.v1"

  /// Stable String Catalog key for a visible Pulse notification's title.
  ///
  /// The subscription factory uses this key in its `CKNotificationInfo`; the
  /// app target's String Catalog supplies its English and Japanese values.
  public static let titleLocalizationKey = "VAULT_ACTIVITY_NOTIFICATION_TITLE"

  /// Stable String Catalog key for a visible Pulse notification's body.
  ///
  /// This stays beside the subscription identifiers so CloudKit payload setup
  /// cannot silently drift from the foreground-presentation contract.
  public static let bodyLocalizationKey = "VAULT_ACTIVITY_NOTIFICATION_BODY"

  /// Whether a CloudKit database notification belongs to one of Tinycurve's
  /// visible Pulse subscriptions.
  ///
  /// A `nil` or unfamiliar identifier is intentionally not treated as a
  /// Pulse. This keeps silent sync subscriptions and future CloudKit
  /// infrastructure outside the user-visible-notification path.
  public static func isVisibleNotificationSubscription(_ subscriptionID: String?) -> Bool {
    switch subscriptionID {
    case privateDatabaseIdentifier, sharedDatabaseIdentifier:
      true
    case nil, _:
      false
    }
  }
}
