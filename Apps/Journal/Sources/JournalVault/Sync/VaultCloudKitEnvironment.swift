import Foundation

/// CloudKit server environment selected by the app's current build.
///
/// CloudKit keeps development and production as independent server databases.
/// Journal uses this value to keep local catalog, vault stores, media files, and
/// sync-engine state scoped to the same environment as the CloudKit container.
public enum VaultCloudKitEnvironment: String, CaseIterable, Sendable {
  /// Development CloudKit database, used by Debug builds.
  case development

  /// Production CloudKit database, used by Release, TestFlight, and App Store builds.
  case production

  /// Info.plist key expanded from `$(APS_ENVIRONMENT)` by the Journal targets.
  public static let infoPlistKey = "JournalCloudKitEnvironment"

  /// Environment for the current app or extension process.
  ///
  /// The Info.plist value is preferred so the app and widget read the same build
  /// setting. The compile-configuration fallback keeps previews and tests usable
  /// when no app bundle plist is present.
  public static var current: VaultCloudKitEnvironment {
    if let environment = VaultCloudKitEnvironment(
      infoPlistValue: Bundle.main.object(forInfoDictionaryKey: infoPlistKey) as? String
    ) {
      return environment
    }

    #if DEBUG
    return .development
    #else
    return .production
    #endif
  }

  /// Creates an environment from an Info.plist or build-setting value.
  public init?(infoPlistValue: String?) {
    guard let value = infoPlistValue?.trimmingCharacters(in: .whitespacesAndNewlines)
      .lowercased()
    else {
      return nil
    }
    self.init(rawValue: value)
  }

  /// Directory name used below the App Group's `Journal/` storage root.
  public var storageDirectoryName: String { rawValue }
}
