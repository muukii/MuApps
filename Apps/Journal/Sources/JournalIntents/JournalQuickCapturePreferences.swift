import Foundation
import JournalVault

/// App Group preferences for the most recent successful Share destination.
///
/// Development and production catalog stores are independent, so the key is
/// scoped by `VaultCloudKitEnvironment`. Only a vault identifier is persisted;
/// its current title and permission are always resolved from the catalog. Other
/// system capture entry points may use this destination only when they do not
/// carry an explicit Vault selection of their own.
public struct JournalQuickCapturePreferences: Sendable {
  private let injectedSuiteName: String?

  public init() {
    injectedSuiteName = nil
  }

  /// Creates preferences backed by isolated defaults in unit tests.
  ///
  /// Production callers intentionally cannot supply a different suite; every
  /// app and extension process must use Journal's App Group container.
  init(suiteName: String) {
    injectedSuiteName = suiteName
  }

  /// Returns the remembered destination, or `nil` before a Share post succeeds.
  ///
  /// A malformed stored identifier is reported instead of being replaced with
  /// another vault. System entry points must never silently post elsewhere.
  public func selectedVaultID(
    environment: VaultCloudKitEnvironment = .current
  ) throws -> VaultID? {
    let defaults = try appGroupDefaults()
    guard let value = defaults.string(forKey: key(for: environment)) else {
      return nil
    }
    guard let vaultID = VaultID(uuidString: value) else {
      throw Error.invalidStoredVaultIdentifier(value)
    }
    return vaultID
  }

  /// Persists a writable-vault descriptor as the successful Share destination.
  public func setSelectedVault(
    _ vault: JournalWritableVault?,
    environment: VaultCloudKitEnvironment = .current
  ) throws {
    try setSelectedVaultID(vault?.id, environment: environment)
  }

  /// Persists a typed vault identifier as the successful Share destination.
  ///
  /// Callers accepting arbitrary ids should validate them with
  /// `JournalPostingService.writableVaults()` before storing the selection.
  public func setSelectedVaultID(
    _ vaultID: VaultID?,
    environment: VaultCloudKitEnvironment = .current
  ) throws {
    let defaults = try appGroupDefaults()
    let key = key(for: environment)
    if let vaultID {
      defaults.set(vaultID.uuidString, forKey: key)
    } else {
      defaults.removeObject(forKey: key)
    }
  }

  /// Resolves the stored id against an already-validated writable vault list.
  ///
  /// Returning `nil` for a stale or now-read-only selection leaves the Share
  /// destination unselected without choosing a replacement.
  public func selectedVault(
    from writableVaults: [JournalWritableVault],
    environment: VaultCloudKitEnvironment = .current
  ) throws -> JournalWritableVault? {
    guard let selectedVaultID = try selectedVaultID(environment: environment) else {
      return nil
    }
    return writableVaults.first { $0.id == selectedVaultID }
  }

  private func appGroupDefaults() throws -> UserDefaults {
    let suiteName = injectedSuiteName ?? VaultStoreLayout.appGroupIdentifier
    guard let defaults = UserDefaults(suiteName: suiteName) else {
      throw Error.appGroupPreferencesUnavailable
    }
    return defaults
  }

  private func key(for environment: VaultCloudKitEnvironment) -> String {
    "Journal.QuickCapture.selectedVaultID.\(environment.rawValue)"
  }
}

extension JournalQuickCapturePreferences {
  /// Failures reading or resolving the shared Share-destination preference.
  public enum Error: Swift.Error, LocalizedError, Sendable {
    case appGroupPreferencesUnavailable
    case invalidStoredVaultIdentifier(String)

    public var errorDescription: String? {
      switch self {
      case .appGroupPreferencesUnavailable:
        return "Journal's shared destination history is unavailable."
      case .invalidStoredVaultIdentifier:
        return "The remembered Share destination is invalid. Choose a Vault in the Share sheet."
      }
    }
  }
}
