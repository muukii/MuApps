import ProjectDescription

// MARK: - Constants

public enum AppConstants {
  public static let developmentTeam = "KU2QEJ9K3Z"
  public static let organizationName = "muukii"
  public static let appBundleId = "app.muukii.verse"
}

// MARK: - Deployment Targets

public extension DeploymentTargets {
  static let app: DeploymentTargets = .multiplatform(
    iOS: "26.1"
  )

  static let nativeMacApp: DeploymentTargets = .multiplatform(
    iOS: "26.1",
    macOS: "26.1"
  )
}

// MARK: - Destinations

public extension Destinations {
  static let app: Destinations = [.iPhone, .iPad]
  static let nativeMacApp: Destinations = [.iPhone, .iPad, .mac]
}

// MARK: - Base Settings

public extension SettingsDictionary {
  static let base: SettingsDictionary = [
    "DEVELOPMENT_TEAM": .string(AppConstants.developmentTeam),
    "CODE_SIGN_STYLE": "Automatic",
    "SWIFT_VERSION": "6.0",
    "SWIFT_APPROACHABLE_CONCURRENCY": "YES",
    "SWIFT_UPCOMING_FEATURE_MEMBER_IMPORT_VISIBILITY": "YES",
    "SWIFT_UPCOMING_FEATURE_EXISTENTIAL_ANY": "YES",
  ]

  static let appTarget: SettingsDictionary = base.merging([
    "SWIFT_DEFAULT_ACTOR_ISOLATION": "MainActor",
    "ASSETCATALOG_COMPILER_APPICON_NAME": "Verse",
    "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "AccentColor",
    "ASSETCATALOG_COMPILER_GENERATE_SWIFT_ASSET_SYMBOL_EXTENSIONS": "YES",
    "ENABLE_APP_SANDBOX": "YES",
    "ENABLE_HARDENED_RUNTIME": "YES",
    "ENABLE_OUTGOING_NETWORK_CONNECTIONS": "YES",
    "ENABLE_USER_SELECTED_FILES": "readonly",
    "REGISTER_APP_GROUPS": "YES",
    "STRING_CATALOG_GENERATE_SYMBOLS": "YES",
    "TARGETED_DEVICE_FAMILY": "1,2",
    "SUPPORTS_MACCATALYST": "NO",
    // MARKETING_VERSION and CURRENT_PROJECT_VERSION are defined in Tuist/xcconfig/Version.xcconfig
    "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/Frameworks",
    "LD_RUNPATH_SEARCH_PATHS[sdk=macosx*]": "$(inherited) @executable_path/../Frameworks",
  ])

  static let nativeMacAppTarget: SettingsDictionary = appTarget.merging([
    "SUPPORTS_MACCATALYST": "NO",
  ])

  static let frameworkTarget: SettingsDictionary = base.merging([
    "BUILD_LIBRARY_FOR_DISTRIBUTION": "YES",
    "SKIP_INSTALL": "YES",
    "SWIFT_INSTALL_MODULE": "YES",
    "SWIFT_INSTALL_OBJC_HEADER": "NO",
    "ALLOW_TARGET_PLATFORM_SPECIALIZATION": "YES",
    "STRING_CATALOG_GENERATE_SYMBOLS": "YES",
    "TARGETED_DEVICE_FAMILY": "1,2,7",
  ])

  static let nativeMacFrameworkTarget: SettingsDictionary = frameworkTarget.merging([
    "SUPPORTS_MACCATALYST": "NO",
  ])
}

// MARK: - Feature Module Template (for future use)

public extension Target {
  /// Creates a feature module target
  /// Usage: .featureModule(name: "Home", dependencies: [...])
  static func featureModule(
    name: String,
    dependencies: [TargetDependency] = []
  ) -> Target {
    .target(
      name: "Feature\(name)",
      destinations: .app,
      product: .staticFramework,
      bundleId: "\(AppConstants.appBundleId).feature.\(name.lowercased())",
      deploymentTargets: .app,
      sources: ["Features/\(name)/**/*.swift"],
      dependencies: dependencies,
      settings: .settings(base: .frameworkTarget)
    )
  }
}
