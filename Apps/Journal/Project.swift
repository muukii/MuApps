import ProjectDescription
import ProjectDescriptionHelpers

// MARK: - Info.plist

let journalInfoPlist: InfoPlist = .extendingDefault(with: [
  "CFBundleDisplayName": "Journal",
  "ITSAppUsesNonExemptEncryption": false,
  "LSApplicationCategoryType": "public.app-category.lifestyle",
  // CloudKit pushes remote changes to the device; this lets SwiftData's
  // CloudKit mirroring pull updates while the app is in the background.
  "UIBackgroundModes": .array(["remote-notification"]),
  "UILaunchScreen": .dictionary([:]),
  // Capture components. Both the camera (CapturePhoto/Capturer) and the
  // microphone (CaptureAudio) require usage descriptions to function.
  "NSCameraUsageDescription": "Take a photo to attach to a journal entry.",
  "NSMicrophoneUsageDescription": "Record the ambient sound around you to attach to a journal entry.",
  // Optional per-card location: when enabled while composing, the card records
  // where it was written (LocationManager → Card.location).
  "NSLocationWhenInUseUsageDescription": "Attach where you are to a journal entry.",
])

// MARK: - Journal-local frameworks

/// A Journal-scoped static framework. Used for the capture components (each an
/// isolated modality, developed/run on its own) and for shared foundations like
/// `MuColor`. Kept inside the Journal app rather than `Shared/` since these are
/// app-scoped, not cross-app.
func journalFramework(name: String, dependencies: [TargetDependency] = []) -> Target {
  .target(
    name: name,
    destinations: .app,
    product: .staticFramework,
    bundleId: "app.muukii.journal.\(name)",
    deploymentTargets: .app,
    infoPlist: .default,
    buildableFolders: [BuildableFolder(stringLiteral: name)],
    dependencies: dependencies,
    settings: .settings(
      base: .frameworkTarget,
      configurations: [
        .debug(name: "Debug"),
        .release(name: "Release"),
      ]
    )
  )
}

// MARK: - Project

let project = Project(
  name: "Journal",
  organizationName: AppConstants.organizationName,
  settings: .settings(
    base: .base,
    configurations: [
      .debug(name: "Debug"),
      .release(name: "Release"),
    ]
  ),
  targets: [
    .target(
      name: "Journal",
      destinations: .app,
      product: .app,
      bundleId: "app.muukii.journal",
      deploymentTargets: .app,
      infoPlist: journalInfoPlist,
      buildableFolders: ["Sources"],
      // iCloud + CloudKit for SwiftData cross-device sync. The container id is
      // the single source of truth read by `ModelConfiguration(cloudKitDatabase:)`.
      // `aps-environment` enables the push channel CloudKit uses for live sync;
      // its value is expanded from $(APS_ENVIRONMENT) per configuration below so
      // Release builds get `production` (otherwise shipped builds never receive
      // CloudKit's silent pushes and background sync silently no-ops).
      // `com.apple.developer.journal.allow` lets `CaptureSuggestions` present the
      // system Journaling Suggestions picker (inert without it; device-only). Its
      // value is the string array `["suggestions"]`, NOT a boolean — it must match
      // exactly what the App ID's Journaling Suggestions capability writes into the
      // provisioning profile, or signing fails with an entitlement-mismatch error.
      // `com.apple.security.application-groups` is shared with `JournalWidget`: the
      // SwiftData store lives in this App Group container so both processes read
      // the same database (see `JournalStore` in the `JournalModel` framework).
      entitlements: .dictionary([
        "com.apple.developer.icloud-container-identifiers": ["iCloud.app.muukii.journal"],
        "com.apple.developer.icloud-services": ["CloudKit"],
        "com.apple.security.application-groups": ["group.app.muukii.journal"],
        "aps-environment": "$(APS_ENVIRONMENT)",
        "com.apple.developer.journal.allow": ["suggestions"],
      ]),
      dependencies: [
        .sdk(name: "CloudKit", type: .framework),
        .external(name: "SwiftUIIntrospect"),
        .external(name: "ScrollEdgeEffect"),
        .external(name: "Algorithms"),
        .target(name: "JournalModel"),
        // Embeds the widget extension into the app bundle.
        .target(name: "JournalWidget"),
        .target(name: "MuColor"),
        .target(name: "MuHaptics"),
        .target(name: "CaptureText"),
        .target(name: "CapturePhoto"),
        .target(name: "CaptureDoodle"),
        .target(name: "CaptureBlob"),
        .target(name: "CaptureAudio"),
        .target(name: "CaptureSuggestions"),
      ],
      settings: .settings(
        base: .appTarget,
        configurations: [
          .debug(name: "Debug", settings: ["APS_ENVIRONMENT": "development"]),
          .release(name: "Release", settings: ["APS_ENVIRONMENT": "production"]),
        ]
      )
    ),

    // MARK: - Shared data layer

    // The SwiftData models (`Card`, `Tag`, `Attachment`, `CardRelationship`,
    // `Coordinate`) and the shared store factory (`JournalStore`). A *dynamic*
    // framework — unlike the capture
    // components (static, app-only), this is linked by both the app and the
    // `JournalWidget` extension, so a dynamic framework embeds it once and lets
    // the extension reference it. `APPLICATION_EXTENSION_API_ONLY` keeps it safe
    // to link into the extension.
    .target(
      name: "JournalModel",
      destinations: .app,
      product: .framework,
      bundleId: "app.muukii.journal.JournalModel",
      deploymentTargets: .app,
      infoPlist: .default,
      buildableFolders: ["JournalModel"],
      dependencies: [],
      settings: .settings(
        base: .frameworkTarget.merging([
          "APPLICATION_EXTENSION_API_ONLY": "YES",
        ]),
        configurations: [
          .debug(name: "Debug"),
          .release(name: "Release"),
        ]
      )
    ),

    // MARK: - Widget extension

    // Reads the shared SwiftData store (via `JournalModel`/`JournalStore`) to
    // render recent cards. It carries the same App Group and iCloud entitlements
    // as the app so it can open the identical CloudKit-mirrored store; the
    // `aps-environment` value is expanded per configuration like the app's.
    .target(
      name: "JournalWidget",
      destinations: .app,
      product: .appExtension,
      bundleId: "app.muukii.journal.JournalWidget",
      deploymentTargets: .app,
      infoPlist: .dictionary([
        "CFBundleDisplayName": "Journal",
        "CFBundleExecutable": "$(EXECUTABLE_NAME)",
        "CFBundleIdentifier": "$(PRODUCT_BUNDLE_IDENTIFIER)",
        "CFBundleName": "$(PRODUCT_NAME)",
        "CFBundleShortVersionString": "1.0",
        "CFBundleVersion": "1",
        "NSExtension": .dictionary([
          "NSExtensionPointIdentifier": "com.apple.widgetkit-extension",
        ]),
      ]),
      buildableFolders: ["JournalWidget"],
      entitlements: .dictionary([
        "com.apple.developer.icloud-container-identifiers": ["iCloud.app.muukii.journal"],
        "com.apple.developer.icloud-services": ["CloudKit"],
        "com.apple.security.application-groups": ["group.app.muukii.journal"],
        "aps-environment": "$(APS_ENVIRONMENT)",
      ]),
      dependencies: [
        .target(name: "JournalModel"),
      ],
      settings: .settings(
        base: .base.merging([
          "APPLICATION_EXTENSION_API_ONLY": "YES",
        ]),
        configurations: [
          .debug(name: "Debug", settings: ["APS_ENVIRONMENT": "development"]),
          .release(name: "Release", settings: ["APS_ENVIRONMENT": "production"]),
        ]
      )
    ),

    journalFramework(
      name: "MuColor",
      dependencies: [
        .external(name: "HexColorMacro"),
      ]
    ),
    journalFramework(name: "MuHaptics"),
    journalFramework(name: "CaptureText"),
    journalFramework(
      name: "CapturePhoto",
      dependencies: [
        .external(name: "Capturer"),
      ]
    ),
    // Pure SwiftUI vector canvas (Canvas/Path) with drawing-time haptics.
    journalFramework(
      name: "CaptureDoodle",
      dependencies: [
        .sdk(name: "CoreHaptics", type: .framework),
      ]
    ),
    // Filled gradient shape-painting experiment, kept separate from Doodle's
    // centerline ink model.
    journalFramework(name: "CaptureBlob"),
    journalFramework(
      name: "CaptureAudio",
      dependencies: [
        .sdk(name: "AVFoundation", type: .framework),
      ]
    ),
    // `JournalingSuggestions` (and `HealthKit`, used to read workout quantities)
    // ship only in the device SDK — they are absent from the Simulator SDK, so an
    // explicit `.sdk` link would break Simulator builds. The framework instead
    // `import`s them behind `#if canImport(...)` and relies on Swift autolinking,
    // keeping the target buildable for both device and Simulator.
    journalFramework(name: "CaptureSuggestions"),

    // MARK: - UI Tests (temporary, for Settings UI verification)
    .target(
      name: "JournalUITests",
      destinations: .app,
      product: .uiTests,
      bundleId: "app.muukii.journal.UITests",
      deploymentTargets: .app,
      infoPlist: .default,
      buildableFolders: ["JournalUITests"],
      dependencies: [
        .target(name: "Journal"),
      ],
      settings: .settings(
        base: [:],
        configurations: [
          .debug(name: "Debug"),
          .release(name: "Release"),
        ]
      )
    ),
  ]
)
