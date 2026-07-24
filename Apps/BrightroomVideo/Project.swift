import ProjectDescription
import ProjectDescriptionHelpers

/// Property-list values owned by the BrightroomVideo application target.
let appInfoPlist: InfoPlist = .extendingDefault(with: [
  "BGTaskSchedulerPermittedIdentifiers": .array([
    "app.muukii.brightroom.BrightroomVideo.export",
  ]),
  "CFBundleDisplayName": "Brightroom Video",
  "CFBundleShortVersionString": "1.0",
  "CFBundleVersion": "1",
  "ITSAppUsesNonExemptEncryption": false,
  "LSApplicationCategoryType": "public.app-category.photo-video",
  "NSPhotoLibraryAddUsageDescription":
    "Brightroom Video saves the exported video to your photo library.",
  "NSPhotoLibraryUsageDescription":
    "Brightroom Video reads videos you choose so you can apply a LUT and export.",
  "UILaunchScreen": .dictionary([:]),
  "UISupportedInterfaceOrientations": .array([
    "UIInterfaceOrientationPortrait",
    "UIInterfaceOrientationLandscapeLeft",
    "UIInterfaceOrientationLandscapeRight",
  ]),
  "UISupportedInterfaceOrientations~ipad": .array([
    "UIInterfaceOrientationPortrait",
    "UIInterfaceOrientationPortraitUpsideDown",
    "UIInterfaceOrientationLandscapeLeft",
    "UIInterfaceOrientationLandscapeRight",
  ]),
])

let project = Project(
  name: "BrightroomVideo",
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
      name: "BrightroomVideo",
      destinations: .app,
      product: .app,
      bundleId: "app.muukii.brightroom.BrightroomVideo",
      deploymentTargets: .app,
      infoPlist: appInfoPlist,
      buildableFolders: ["Sources"],
      entitlements: .dictionary([
        // Core Image rendering continues on the GPU while the export task is
        // running after the app leaves the foreground.
        "com.apple.developer.background-tasks.continued-processing.gpu": true,
      ]),
      dependencies: [
        .external(name: "BrightroomParametric"),
      ],
      settings: .settings(
        base: .appTarget.merging([
          // The migrated prototype has no production icon asset yet.
          "ASSETCATALOG_COMPILER_APPICON_NAME": "",
        ]),
        configurations: [
          .debug(name: "Debug"),
          .release(name: "Release"),
        ]
      )
    ),
  ]
)
