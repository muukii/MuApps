import ProjectDescription
import ProjectDescriptionHelpers

let appInfoPlist: InfoPlist = .extendingDefault(with: [
  "CFBundleDisplayName": "PeekLUT",
  "CFBundleShortVersionString": "1.0",
  "CFBundleVersion": "1",
  "ITSAppUsesNonExemptEncryption": false,
  "LSApplicationCategoryType": "public.app-category.photography",
  "NSPhotoLibraryUsageDescription": "Pick a photo or video to preview LUTs on.",
  "UILaunchScreen": .dictionary([:]),
  "UISupportedInterfaceOrientations": .array([
    "UIInterfaceOrientationPortrait",
    "UIInterfaceOrientationLandscapeLeft",
    "UIInterfaceOrientationLandscapeRight",
  ]),
])

let project = Project(
  name: "PeekLUT",
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
      name: "PeekLUT",
      destinations: .app,
      product: .app,
      bundleId: "app.muukii.peeklut",
      deploymentTargets: .app,
      infoPlist: appInfoPlist,
      buildableFolders: ["Sources"],
      dependencies: [
        .project(target: "MuDesignSystem", path: "../../Shared"),
      ],
      settings: .settings(
        base: .appTarget,
        configurations: [
          .debug(name: "Debug"),
          .release(name: "Release"),
        ]
      )
    )
  ]
)
