import Foundation

/// Stable identity of one vault — Journal's durable collaboration boundary.
///
/// A vault owns a separate SwiftData store, a media directory, and (once it
/// syncs) one CloudKit custom record zone. Everything that must stay
/// vault-scoped — reset, export, share acceptance, conflict repair — is keyed
/// by this value, so it is a dedicated type instead of a bare `UUID` passed
/// around.
public struct VaultID: Hashable, Sendable, Codable {

  public let rawValue: UUID

  public init(rawValue: UUID) {
    self.rawValue = rawValue
  }

  /// Creates a brand-new vault identity.
  public init() {
    self.init(rawValue: UUID())
  }

  public init?(uuidString: String) {
    guard let uuid = UUID(uuidString: uuidString) else { return nil }
    self.init(rawValue: uuid)
  }

  public var uuidString: String {
    rawValue.uuidString
  }
}

extension VaultID: CustomStringConvertible {

  public var description: String {
    rawValue.uuidString
  }
}
