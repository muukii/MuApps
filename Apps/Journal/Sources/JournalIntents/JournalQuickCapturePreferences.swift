import Foundation
import JournalVault

/// App Group preferences for the user-selected Quick Capture destination.
///
/// Development and production catalog stores are independent, so the key is
/// scoped by `VaultCloudKitEnvironment`. Only a vault identifier is persisted;
/// its current title and permission are always resolved from the catalog.
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

  /// Returns the explicitly selected vault, or `nil` when setup is incomplete.
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

  /// Persists a writable-vault descriptor as the Quick Capture destination.
  public func setSelectedVault(
    _ vault: JournalWritableVault?,
    environment: VaultCloudKitEnvironment = .current
  ) throws {
    try setSelectedVaultID(vault?.id, environment: environment)
  }

  /// Persists a typed vault identifier as the Quick Capture destination.
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
  /// Returning `nil` for a stale or now-read-only selection lets Settings show
  /// that configuration is required without choosing a replacement.
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
  /// Failures reading or resolving the shared Quick Capture preference.
  public enum Error: Swift.Error, LocalizedError, Sendable {
    case appGroupPreferencesUnavailable
    case invalidStoredVaultIdentifier(String)

    public var errorDescription: String? {
      switch self {
      case .appGroupPreferencesUnavailable:
        return "Journal's shared Quick Capture settings are unavailable."
      case .invalidStoredVaultIdentifier:
        return "The configured Quick Capture Vault is invalid. Choose it again in Journal Settings."
      }
    }
  }
}
