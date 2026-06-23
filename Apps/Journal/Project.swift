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
      entitlements: .dictionary([
        "com.apple.developer.icloud-container-identifiers": ["iCloud.app.muukii.journal"],
        "com.apple.developer.icloud-services": ["CloudKit"],
        "aps-environment": "$(APS_ENVIRONMENT)",
      ]),
      dependencies: [
        .sdk(name: "CloudKit", type: .framework),
        .target(name: "MuColor"),
        .target(name: "CaptureText"),
        .target(name: "CapturePhoto"),
        .target(name: "CaptureDoodle"),
        .target(name: "CaptureAudio"),
      ],
      settings: .settings(
        base: .appTarget,
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
    journalFramework(name: "CaptureText"),
    journalFramework(
      name: "CapturePhoto",
      dependencies: [
        .external(name: "Capturer"),
      ]
    ),
    journalFramework(
      name: "CaptureDoodle",
      dependencies: [
        .sdk(name: "Metal", type: .framework),
        .sdk(name: "MetalKit", type: .framework),
      ]
    ),
    journalFramework(
      name: "CaptureAudio",
      dependencies: [
        .sdk(name: "AVFoundation", type: .framework),
      ]
    ),
  ]
)
