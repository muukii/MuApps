import ProjectDescription
import ProjectDescriptionHelpers

// MARK: - Info.plist

/// User-facing app name embedded in the archive and shown under the app icon.
/// Keep this aligned with the product name users should see on the Home Screen.
let journalBundleDisplayName: Plist.Value = "Tinycurve"

/// Short app bundle name used by `CFBundleName`.
/// Apple documents a 15-character limit for this value, and App Store Connect
/// validates it together with the display name during binary upload.
let journalBundleName: Plist.Value = "TinycurveJ"

/// User-facing name for the WidgetKit extension bundle.
let journalWidgetBundleDisplayName: Plist.Value = "Tinycurve Widget"

/// Short bundle name for the WidgetKit extension.
let journalWidgetBundleName: Plist.Value = "TinycurveWidget"

let journalVersionInfoPlistKeys: [String: Plist.Value] = [
  "CFBundleShortVersionString": "$(MARKETING_VERSION)",
  "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
]

let journalInfoPlist: InfoPlist = .extendingDefault(with: journalVersionInfoPlistKeys.merging([
  "CFBundleDisplayName": journalBundleDisplayName,
  "CFBundleName": journalBundleName,
  "ITSAppUsesNonExemptEncryption": false,
  "LSApplicationCategoryType": "public.app-category.lifestyle",
  // Required for CloudKit share URLs to launch the app and deliver
  // CKShare.Metadata to the scene delegate.
  "CKSharingSupported": true,
  // CloudKit pushes remote changes to the device; the explicit vault sync
  // layer consumes these notifications for per-vault zones.
  "UIBackgroundModes": .array(["remote-notification"]),
  "UILaunchScreen": .dictionary([:]),
  // Capture components. Camera and microphone require direct permission; Photos
  // import uses the system picker and receives only the media the user selects.
  "NSCameraUsageDescription": "Take a photo to attach to a journal entry.",
  "NSPhotoLibraryUsageDescription": "Choose a photo, Live Photo, or video to attach to a journal entry.",
  "NSMicrophoneUsageDescription": "Record the ambient sound around you to attach to a journal entry.",
  // Optional authored-card location: when the Journal setting is enabled, new
  // cards record where they were written (LocationManager → Card.location).
  "NSLocationWhenInUseUsageDescription": "Attach where you are to a journal entry.",
]) { _, new in new })

// MARK: - Journal-local frameworks

/// A Journal-scoped framework. Used for the capture components (each an
/// isolated modality, developed/run on its own) and for shared foundations like
/// `MuColor`. Sources live under `Sources/<TargetName>` so the app directory
/// stays compact while keeping these modules app-scoped instead of `Shared/`.
func journalFramework(
  name: String,
  product: Product = .staticFramework,
  resources: ResourceFileElements? = nil,
  dependencies: [TargetDependency] = []
) -> Target {
  .target(
    name: name,
    destinations: .app,
    product: product,
    bundleId: "app.muukii.journal.\(name)",
    deploymentTargets: .app,
    infoPlist: .default,
    resources: resources,
    buildableFolders: [BuildableFolder(stringLiteral: "Sources/\(name)")],
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
      resources: [
        "Resources/Journal/**",
      ],
      buildableFolders: ["Sources/Journal"],
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
      // `com.apple.security.application-groups` is shared with `JournalWidget`
      // and the vault store layout. The app writes vault stores here; the widget
      // reads configured vault stores from the same App Group.
      entitlements: .dictionary([
        "com.apple.developer.icloud-container-identifiers": ["iCloud.app.muukii.journal"],
        "com.apple.developer.icloud-services": ["CloudKit"],
        "com.apple.security.application-groups": ["group.app.muukii.journal"],
        "aps-environment": "$(APS_ENVIRONMENT)",
        "com.apple.developer.journal.allow": ["suggestions"],
      ]),
      dependencies: [
        .sdk(name: "AVFoundation", type: .framework),
        .sdk(name: "CloudKit", type: .framework),
        .sdk(name: "LinkPresentation", type: .framework),
        .sdk(name: "Photos", type: .framework),
        .sdk(name: "PhotosUI", type: .framework),
        .sdk(name: "SharedWithYou", type: .framework),
        .external(name: "ScrollEdgeEffect"),
        .external(name: "Algorithms"),
        .target(name: "AppUIComponents"),
        .target(name: "JournalVault"),
        // Embeds the widget extension into the app bundle.
        .target(name: "JournalWidget"),
        .target(name: "MuColor"),
        .target(name: "MuHaptics"),
        .target(name: "CaptureText"),
        .target(name: "CapturePhoto"),
        .target(name: "MediaProcessing"),
        .target(name: "CaptureDoodle"),
        .target(name: "CaptureBauhaus"),
        .target(name: "CaptureAudio"),
        .target(name: "CaptureSuggestions"),
      ],
      settings: .settings(
        base: .appTarget.merging([
          "ASSETCATALOG_COMPILER_APPICON_NAME": "Icon",
        ]),
        configurations: [
          .debug(
            name: "Debug",
            settings: ["APS_ENVIRONMENT": "development"],
            xcconfig: "xcconfig/Version.xcconfig"
          ),
          .release(
            name: "Release",
            settings: ["APS_ENVIRONMENT": "production"],
            xcconfig: "xcconfig/Version.xcconfig"
          ),
        ]
      )
    ),

    // MARK: - Vault data layer (target architecture)

    // The vault persistence + sync foundation from `docs/VAULT_SYNC_DESIGN.md`:
    // a small catalog store plus per-vault SwiftData stores with CloudKit
    // mirroring *disabled*, and the explicit sync layer (`VaultSyncEngine`,
    // CKSyncEngine-backed) that owns CloudKit zones/records/assets. A dynamic
    // dynamic framework so the widget extension can link the vault reader while
    // the app shell opens the runtime, lets the user choose a vault, and uses
    // the selected VaultInstance for save/list UI.
    .target(
      name: "JournalVault",
      destinations: .app,
      product: .framework,
      bundleId: "app.muukii.journal.JournalVault",
      deploymentTargets: .app,
      infoPlist: .default,
      buildableFolders: ["Sources/JournalVault"],
      dependencies: [
        .sdk(name: "CloudKit", type: .framework),
      ],
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

    .target(
      name: "JournalVaultTests",
      destinations: .app,
      product: .unitTests,
      bundleId: "app.muukii.journal.JournalVaultTests",
      deploymentTargets: .app,
      infoPlist: .default,
      buildableFolders: ["Tests/JournalVaultTests"],
      dependencies: [
        .target(name: "JournalVault"),
      ],
      settings: .settings(
        base: [:],
        configurations: [
          .debug(name: "Debug"),
          .release(name: "Release"),
        ]
      )
    ),

    // MARK: - Widget extension

    // Reads the vault catalog and the configured vault content store from the
    // App Group via `JournalVault`. It carries the same App Group and iCloud
    // entitlements as the app; the `aps-environment` value is expanded per
    // configuration like the app's.
    .target(
      name: "JournalWidget",
      destinations: .app,
      product: .appExtension,
      bundleId: "app.muukii.journal.JournalWidget",
      deploymentTargets: .app,
      infoPlist: .dictionary([
        "CFBundleDisplayName": journalWidgetBundleDisplayName,
        "CFBundleExecutable": "$(EXECUTABLE_NAME)",
        "CFBundleIdentifier": "$(PRODUCT_BUNDLE_IDENTIFIER)",
        "CFBundleName": journalWidgetBundleName,
        "CFBundleShortVersionString": "$(MARKETING_VERSION)",
        "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
        "NSExtension": .dictionary([
          "NSExtensionPointIdentifier": "com.apple.widgetkit-extension",
        ]),
      ]),
      resources: [
        "Resources/JournalWidget/**",
      ],
      buildableFolders: ["Sources/JournalWidget"],
      entitlements: .dictionary([
        "com.apple.developer.icloud-container-identifiers": ["iCloud.app.muukii.journal"],
        "com.apple.developer.icloud-services": ["CloudKit"],
        "com.apple.security.application-groups": ["group.app.muukii.journal"],
        "aps-environment": "$(APS_ENVIRONMENT)",
      ]),
      dependencies: [
        .target(name: "CaptureBauhaus"),
        .target(name: "CaptureDoodle"),
        .target(name: "JournalVault"),
      ],
      settings: .settings(
        base: .base.merging([
          "APPLICATION_EXTENSION_API_ONLY": "YES",
        ]),
        configurations: [
          .debug(
            name: "Debug",
            settings: ["APS_ENVIRONMENT": "development"],
            xcconfig: "xcconfig/Version.xcconfig"
          ),
          .release(
            name: "Release",
            settings: ["APS_ENVIRONMENT": "production"],
            xcconfig: "xcconfig/Version.xcconfig"
          ),
        ]
      )
    ),

    journalFramework(
      name: "MuColor",
      product: .framework,
      resources: [
        "Resources/MuColor/Assets.xcassets",
      ]
    ),
    journalFramework(
      name: "AppUIComponents",
      product: .framework,
      dependencies: [
        .sdk(name: "AVFoundation", type: .framework),
        .sdk(name: "CloudKit", type: .framework),
        .sdk(name: "LinkPresentation", type: .framework),
        .sdk(name: "SharedWithYou", type: .framework),
        .external(name: "SwiftUIIntrospect"),
        .target(name: "CaptureBauhaus"),
        .target(name: "CaptureDoodle"),
        .target(name: "JournalVault"),
        .target(name: "MuColor"),
      ]
    ),
    journalFramework(name: "MuHaptics"),
    journalFramework(name: "CaptureText"),
    journalFramework(name: "CapturePhoto"),
    // Save-time raster derivatives for large media such as photos and videos.
    journalFramework(
      name: "MediaProcessing",
      dependencies: [
        .sdk(name: "AVFoundation", type: .framework),
        .sdk(name: "ImageIO", type: .framework),
        .sdk(name: "UniformTypeIdentifiers", type: .framework),
      ]
    ),
    // Pure SwiftUI vector canvas (Canvas/Path) with drawing-time haptics.
    journalFramework(
      name: "CaptureDoodle",
      product: .framework,
      dependencies: [
        .sdk(name: "CoreHaptics", type: .framework),
      ]
    ),
    // Pure SwiftUI grid composer for Bauhaus-style geometric journal artwork.
    journalFramework(name: "CaptureBauhaus", product: .framework),
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
      buildableFolders: ["Tests/JournalUITests"],
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
