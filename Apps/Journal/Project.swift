import ProjectDescription
import ProjectDescriptionHelpers

// MARK: - Info.plist

/// User-facing app name embedded in the archive and shown under the app icon.
/// Keep this aligned with the product name users should see on the Home Screen.
let journalBundleDisplayName: Plist.Value = "Tinycurve"

/// Short app bundle name used by `CFBundleName`.
/// Apple documents a 15-character limit for this value, and App Store Connect
/// validates it together with the display name during binary upload.
let journalBundleName: Plist.Value = "Tinycurve"

/// User-facing name for the WidgetKit extension bundle.
let journalWidgetBundleDisplayName: Plist.Value = "Tinycurve Widget"

/// Short bundle name for the WidgetKit extension.
let journalWidgetBundleName: Plist.Value = "TinycurveWidget"

/// User-facing name associated with Journal's background App Intents.
let journalAppIntentsBundleDisplayName: Plist.Value = "Tinycurve"

/// User-facing name shown by the system Share sheet.
let journalShareExtensionBundleDisplayName: Plist.Value = "Tinycurve"

/// Apple platforms that compile the shared SwiftUI Journal product.
///
/// The Mac destination is native macOS. Platform adapters keep AppKit and UIKit
/// at the UI boundary while JournalVault remains shared.
let journalDestinations: Destinations = [.iPhone, .iPad, .mac]

/// Minimum OS versions for Journal's native iOS and macOS products.
let journalDeploymentTargets: DeploymentTargets = .multiplatform(
  iOS: "26.1",
  macOS: "26.0"
)

/// Runtime key used by `JournalVault` to scope local stores to the active
/// CloudKit server environment.
let journalCloudKitEnvironmentInfoPlistKey = "JournalCloudKitEnvironment"

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
  journalCloudKitEnvironmentInfoPlistKey: "$(APS_ENVIRONMENT)",
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
    destinations: journalDestinations,
    product: product,
    bundleId: "app.muukii.journal.\(name)",
    deploymentTargets: journalDeploymentTargets,
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
  name: "Tinycurve",
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
      name: "Tinycurve",
      destinations: journalDestinations,
      product: .app,
      bundleId: "app.muukii.journal",
      deploymentTargets: journalDeploymentTargets,
      infoPlist: journalInfoPlist,
      resources: [
        "Resources/Journal/**",
      ],
      buildableFolders: ["Sources/Journal"],
      // iCloud + CloudKit for JournalVault's explicit vault sync. The container
      // id is the transport boundary used by `CloudKitVaultSyncEngine`.
      // `aps-environment` enables the push channel CloudKit uses for live sync;
      // its value is expanded from $(APS_ENVIRONMENT) per configuration below so
      // Release builds get `production` (otherwise shipped builds never receive
      // CloudKit's silent pushes and background sync silently no-ops).
      // The Info.plist mirrors that value for runtime storage scoping:
      // development and production keep separate local catalogs, vault stores,
      // media files, and CKSyncEngine state.
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
        .sdk(name: "MapKit", type: .framework),
        .sdk(name: "Photos", type: .framework),
        .sdk(name: "PhotosUI", type: .framework),
        .sdk(name: "SharedWithYou", type: .framework),
        .external(name: "ScrollEdgeEffect"),
        // The package's gesture bridge is UIKit-only. Native macOS uses the
        // local AppKit/SwiftUI compatibility modifier in the Tinycurve target.
        .external(
          name: "SwiftUISnapDraggingModifier",
          condition: .when([.ios])
        ),
        .external(
          name: "NextGrowingTextViewSwiftUI",
          condition: .when([.ios])
        ),
        .external(name: "Algorithms"),
        .target(name: "AppUIComponents"),
        .target(name: "JournalIntents"),
        .target(name: "JournalVault"),
        // Embeds the widget extension into the app bundle.
        .target(name: "JournalWidget"),
        // iOS-only entry points used by Shortcuts, the Action Button, and the
        // system Share sheet. Native macOS keeps the shared app/framework path.
        .target(name: "JournalAppIntentsExtension", condition: .when([.ios])),
        .target(name: "JournalShareExtension", condition: .when([.ios])),
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
          // CloudKit and App Group entitlements cannot run under ad-hoc signing.
          "CODE_SIGN_IDENTITY[sdk=macosx*]": "Apple Development",
          "CODE_SIGN_ENTITLEMENTS[sdk=macosx*]": "Support/Tinycurve-macOS.entitlements",
          // Native Mac sandbox capabilities used by the same capture features
          // that request privacy permission through Info.plist on iOS.
          "ENABLE_RESOURCE_ACCESS_AUDIO_INPUT[sdk=macosx*]": "YES",
          "ENABLE_RESOURCE_ACCESS_CAMERA[sdk=macosx*]": "YES",
          "ENABLE_RESOURCE_ACCESS_LOCATION[sdk=macosx*]": "YES",
          "ENABLE_RESOURCE_ACCESS_PHOTO_LIBRARY[sdk=macosx*]": "YES",
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
      destinations: journalDestinations,
      product: .framework,
      bundleId: "app.muukii.journal.JournalVault",
      deploymentTargets: journalDeploymentTargets,
      infoPlist: .default,
      buildableFolders: ["Sources/JournalVault"],
      dependencies: [
        .sdk(name: "CloudKit", type: .framework),
        .external(name: "CloudKitSupport"),
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
      destinations: journalDestinations,
      product: .unitTests,
      bundleId: "app.muukii.journal.JournalVaultTests",
      deploymentTargets: journalDeploymentTargets,
      infoPlist: .default,
      buildableFolders: ["Tests/JournalVaultTests"],
      dependencies: [
        .external(name: "CloudKitSupport"),
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

    // MARK: - System capture foundations

    // Extension-safe App Intents entities, Quick Capture preferences, app
    // navigation requests, and the single local-post transaction boundary used
    // by both Shortcuts and the Share extension.
    .target(
      name: "JournalIntents",
      destinations: journalDestinations,
      product: .framework,
      bundleId: "app.muukii.journal.JournalIntents",
      deploymentTargets: journalDeploymentTargets,
      infoPlist: .default,
      buildableFolders: ["Sources/JournalIntents"],
      dependencies: [
        .sdk(name: "AppIntents", type: .framework),
        .sdk(name: "WidgetKit", type: .framework),
        .target(name: "JournalVault"),
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

    // Runs text-only posts without launching the containing app. It commits to
    // the App Group vault and durable outbox; CloudKit transport stays app-owned.
    .target(
      name: "JournalAppIntentsExtension",
      destinations: [.iPhone, .iPad],
      product: .extensionKitExtension,
      bundleId: "app.muukii.journal.AppIntentsExtension",
      deploymentTargets: .iOS("26.1"),
      infoPlist: .extendingDefault(with: journalVersionInfoPlistKeys.merging([
        "CFBundleDisplayName": journalAppIntentsBundleDisplayName,
        "CFBundleExecutable": "$(EXECUTABLE_NAME)",
        "CFBundleIdentifier": "$(PRODUCT_BUNDLE_IDENTIFIER)",
        "CFBundleName": "TinycurveAct",
        journalCloudKitEnvironmentInfoPlistKey: "$(APS_ENVIRONMENT)",
        "EXAppExtensionAttributes": .dictionary([
          "EXExtensionPointIdentifier": "com.apple.appintents-extension",
        ]),
      ]) { _, new in new }),
      buildableFolders: ["Sources/JournalAppIntentsExtension"],
      entitlements: .dictionary([
        "com.apple.security.application-groups": ["group.app.muukii.journal"],
      ]),
      dependencies: [
        .sdk(name: "AppIntents", type: .framework),
        .sdk(name: "ExtensionFoundation", type: .framework),
        .target(name: "JournalIntents"),
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

    // Custom SwiftUI Share sheet for text, links, media, and files. Like the
    // App Intents extension, it receives only App Group access and never starts
    // CloudKit transport in its short-lived process.
    .target(
      name: "JournalShareExtension",
      destinations: [.iPhone, .iPad],
      product: .appExtension,
      bundleId: "app.muukii.journal.ShareExtension",
      deploymentTargets: .iOS("26.1"),
      infoPlist: .extendingDefault(with: journalVersionInfoPlistKeys.merging([
        "CFBundleDisplayName": journalShareExtensionBundleDisplayName,
        "CFBundleExecutable": "$(EXECUTABLE_NAME)",
        "CFBundleIdentifier": "$(PRODUCT_BUNDLE_IDENTIFIER)",
        "CFBundleName": "TinycurveShare",
        journalCloudKitEnvironmentInfoPlistKey: "$(APS_ENVIRONMENT)",
        "NSExtension": .dictionary([
          "NSExtensionAttributes": .dictionary([
            "NSExtensionActivationRule": .dictionary([
              "NSExtensionActivationDictionaryVersion": 2,
              "NSExtensionActivationUsesStrictMatching": true,
              "NSExtensionActivationSupportsText": true,
              "NSExtensionActivationSupportsWebURLWithMaxCount": 1,
              "NSExtensionActivationSupportsImageWithMaxCount": 10,
              "NSExtensionActivationSupportsMovieWithMaxCount": 10,
              "NSExtensionActivationSupportsFileWithMaxCount": 10,
            ]),
          ]),
          "NSExtensionPointIdentifier": "com.apple.share-services",
          "NSExtensionPrincipalClass": "$(PRODUCT_MODULE_NAME).ShareViewController",
        ]),
      ]) { _, new in new }),
      buildableFolders: ["Sources/JournalShareExtension"],
      entitlements: .dictionary([
        "com.apple.security.application-groups": ["group.app.muukii.journal"],
      ]),
      dependencies: [
        .sdk(name: "AVFoundation", type: .framework),
        .sdk(name: "UniformTypeIdentifiers", type: .framework),
        .target(name: "JournalIntents"),
        .target(name: "JournalVault"),
        .target(name: "MediaProcessing"),
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

    .target(
      name: "JournalIntentsTests",
      destinations: journalDestinations,
      product: .unitTests,
      bundleId: "app.muukii.journal.JournalIntentsTests",
      deploymentTargets: journalDeploymentTargets,
      infoPlist: .default,
      buildableFolders: ["Tests/JournalIntentsTests"],
      dependencies: [
        .target(name: "JournalIntents"),
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
      destinations: journalDestinations,
      product: .appExtension,
      bundleId: "app.muukii.journal.JournalWidget",
      deploymentTargets: journalDeploymentTargets,
      infoPlist: .dictionary([
        "CFBundleDisplayName": journalWidgetBundleDisplayName,
        "CFBundleExecutable": "$(EXECUTABLE_NAME)",
        "CFBundleIdentifier": "$(PRODUCT_BUNDLE_IDENTIFIER)",
        "CFBundleName": journalWidgetBundleName,
        "CFBundleShortVersionString": "$(MARKETING_VERSION)",
        "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
        journalCloudKitEnvironmentInfoPlistKey: "$(APS_ENVIRONMENT)",
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
        .target(name: "JournalIntents"),
        .target(name: "JournalVault"),
      ],
      settings: .settings(
        base: .base.merging([
          "APPLICATION_EXTENSION_API_ONLY": "YES",
          "CODE_SIGN_IDENTITY[sdk=macosx*]": "Apple Development",
          "CODE_SIGN_ENTITLEMENTS[sdk=macosx*]": "Support/JournalWidget-macOS.entitlements",
          "ENABLE_APP_SANDBOX[sdk=macosx*]": "YES",
          "ENABLE_HARDENED_RUNTIME[sdk=macosx*]": "YES",
          "ENABLE_OUTGOING_NETWORK_CONNECTIONS[sdk=macosx*]": "YES",
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
        .sdk(name: "MapKit", type: .framework),
        .sdk(name: "SharedWithYou", type: .framework),
        .external(name: "SwiftUIIntrospect"),
        .target(name: "CaptureBauhaus"),
        .target(name: "CaptureDoodle"),
        .target(name: "JournalVault"),
        .target(name: "MuColor"),
        .external(name: "GaussianLinearGradient")
      ]
    ),
    journalFramework(name: "MuHaptics"),
    journalFramework(
      name: "CaptureText",
      dependencies: [
        .external(
          name: "NextGrowingTextViewSwiftUI",
          condition: .when([.ios])
        ),
      ]
    ),
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
      name: "TinycurveUITests",
      destinations: journalDestinations,
      product: .uiTests,
      bundleId: "app.muukii.journal.UITests",
      deploymentTargets: journalDeploymentTargets,
      infoPlist: .default,
      buildableFolders: ["Tests/JournalUITests"],
      dependencies: [
        .target(name: "Tinycurve"),
      ],
      settings: .settings(
        base: [:],
        configurations: [
          .debug(name: "Debug"),
          .release(name: "Release"),
        ]
      )
    ),
  ],
  schemes: [
    .scheme(
      name: "JournalIntentsTests",
      buildAction: .buildAction(targets: ["JournalIntentsTests"]),
      testAction: .targets([
        .testableTarget(
          target: "JournalIntentsTests",
          parallelization: .swiftTestingOnly
        ),
      ])
    ),
  ]
)
