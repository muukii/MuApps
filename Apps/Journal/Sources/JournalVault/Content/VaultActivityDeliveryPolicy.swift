import Foundation

/// Explicit participant-notification eligibility snapshot supplied at a vault
/// content-write boundary.
///
/// `VaultContentStore` owns only one vault's SwiftData database and must not
/// read `VaultCatalogStore` or live share state during its transaction. The app
/// and extension therefore derive this value from the `VaultDescriptor` they
/// already validated, then pass it to every newly authored content action.
public enum VaultActivityDeliveryPolicy: Equatable, Sendable {

  /// Record durable Activity, but do not touch participant-only delivery
  /// state. Personal and owner-only Activity must never become a retroactive
  /// Shared with You notice merely because the vault is shared later.
  case historyOnly

  /// Record durable Activity and the local Shared with You intent, then re-arm
  /// the vault's singleton Pulse for another current participant.
  case notifyParticipants
}

extension VaultDescriptor {

  /// Delivery policy snapshot for a content action written through this
  /// descriptor.
  ///
  /// A participant vault always has another actor. An owned vault becomes
  /// eligible only after the share has more than its owner. `isShared` is not
  /// sufficient because preparing (then cancelling) a sharing UI can create a
  /// one-person `CKShare` before any participant exists.
  public var activityDeliveryPolicy: VaultActivityDeliveryPolicy {
    switch ownership {
    case .participant:
      .notifyParticipants
    case .owned:
      participantCount > 1 ? .notifyParticipants : .historyOnly
    }
  }
}
