import ProjectDescription

// MARK: - Constants

public enum AppConstants {
  public static let developmentTeam = "KU2QEJ9K3Z"
  public static let organizationName = "muukii"
}

// MARK: - Deployment Targets

public extension DeploymentTargets {
  static let app: DeploymentTargets = .multiplatform(
    iOS: "26.1"
  )
}

// MARK: - Destinations

public extension Destinations {
  static let app: Destinations = [.iPhone, .iPad]
}

// MARK: - Base Settings

public extension SettingsDictionary {
  static let base: SettingsDictionary = [
    "DEVELOPMENT_TEAM": .string(AppConstants.developmentTeam),
    "CODE_SIGN_STYLE": "Automatic",
    // Enable Xcode 26's reusable compilation cache across all generated projects and targets.
    "COMPILATION_CACHE_ENABLE_CACHING": "YES",
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
    // TARGETED_DEVICE_FAMILY is derived from each target's `destinations`; do not hardcode it here.
    "SUPPORTS_MACCATALYST": "NO",
    // MARKETING_VERSION and CURRENT_PROJECT_VERSION are defined in Tuist/xcconfig/Version.xcconfig
    "LD_RUNPATH_SEARCH_PATHS": "$(inherited) @executable_path/Frameworks",
    "LD_RUNPATH_SEARCH_PATHS[sdk=macosx*]": "$(inherited) @executable_path/../Frameworks",
  ])

  static let frameworkTarget: SettingsDictionary = base.merging([
    // First-party app modules are rebuilt with their clients by default. Opt
    // individual targets into library evolution only when distributing them as
    // binary artifacts.
    "BUILD_LIBRARY_FOR_DISTRIBUTION": "NO",
    "SKIP_INSTALL": "YES",
    "SWIFT_INSTALL_MODULE": "YES",
    "SWIFT_INSTALL_OBJC_HEADER": "NO",
    "ALLOW_TARGET_PLATFORM_SPECIALIZATION": "YES",
    "STRING_CATALOG_GENERATE_SYMBOLS": "YES",
    // TARGETED_DEVICE_FAMILY is derived from each target's `destinations`; do not hardcode it here.
  ])
}
