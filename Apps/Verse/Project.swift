import ProjectDescription
import ProjectDescriptionHelpers

// MARK: - Info.plist

let appInfoPlist: InfoPlist = .extendingDefault(with: [
  "CFBundleShortVersionString": "$(MARKETING_VERSION)",
  "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
  "ITSAppUsesNonExemptEncryption": false,
  "CFBundleDisplayName": "Verse",
  "LSApplicationCategoryType": "public.app-category.education",
  "BGTaskSchedulerPermittedIdentifiers": .array([
    "app.muukii.verse.download",
    "app.muukii.verse.download.*",
  ]),
  "NSMicrophoneUsageDescription":
    "This app uses the microphone for real-time speech transcription.",
  "NSSpeechRecognitionUsageDescription":
    "This app uses speech recognition to convert your voice to text.",
  "UIBackgroundModes": .array(["processing", "fetch"]),
  "UILaunchScreen": .dictionary([:]),
])

// MARK: - Project

let project = Project(
  name: "Verse",
  organizationName: AppConstants.organizationName,
  settings: .settings(
    base: .base,
    configurations: [
      .debug(name: "Debug"),
      .release(name: "Release"),
    ]
  ),
  targets: [
    // MARK: - Main App Target
    .target(
      name: "Verse",
      destinations: .app,
      product: .app,
      bundleId: AppConstants.appBundleId,
      deploymentTargets: .app,
      infoPlist: appInfoPlist,
      buildableFolders: ["Sources"],
      entitlements: .file(path: "Sources/YouTubeSubtitle.entitlements"),
      dependencies: [
        // Internal target
        .target(name: "Components"),

        // External SPM dependencies
        .external(name: "YouTubeKit"),
        .external(name: "ObjectEdge"),
        .external(name: "SwiftUIRingSlider"),
        .external(name: "TypedIdentifier"),
        .external(name: "AsyncMultiplexImage"),
        .external(name: "AsyncMultiplexImage-Nuke"),
        .external(name: "StateGraph"),
        .external(name: "Algorithms"),
      ],
      settings: .settings(
        base: .appTarget,
        configurations: [
          .debug(name: "Debug", xcconfig: "xcconfig/Version.xcconfig"),
          .release(name: "Release", xcconfig: "xcconfig/Version.xcconfig"),
        ]
      )
    ),

    // MARK: - Components Framework Target
    .target(
      name: "Components",
      destinations: .app,
      product: .staticFramework,
      bundleId: "app.muukii.Components",
      deploymentTargets: .app,
      infoPlist: .default,
      buildableFolders: ["Components"],
      dependencies: [],
      settings: .settings(
        base: .frameworkTarget,
        configurations: [
          .debug(name: "Debug"),
          .release(name: "Release"),
        ]
      )
    ),
  ]
)
