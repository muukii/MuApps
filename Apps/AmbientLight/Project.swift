import ProjectDescription
import ProjectDescriptionHelpers

let ambientLightInfoPlist: InfoPlist = .extendingDefault(with: [
  "CFBundleDisplayName": "Calm Light",
  "CFBundleShortVersionString": "1.0",
  "CFBundleVersion": "1",
  "ITSAppUsesNonExemptEncryption": false,
  "LSApplicationCategoryType": "public.app-category.lifestyle",
  "UIApplicationSupportsIndirectInputEvents": true,
  "UILaunchScreen": .dictionary([:]),
  "UIStatusBarHidden": true,
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
  "UIUserInterfaceStyle": "Dark",
])

let project = Project(
  name: "AmbientLight",
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
      name: "AmbientLight",
      destinations: .app,
      product: .app,
      bundleId: "app.muukii.ambientlight",
      deploymentTargets: .app,
      infoPlist: ambientLightInfoPlist,
      buildableFolders: ["Sources"],
      dependencies: [],
      settings: .settings(
        base: .appTarget.merging([
          "ASSETCATALOG_COMPILER_APPICON_NAME": "AmbientLight",
          "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "AccentColor",
          "MTL_FAST_MATH": "YES",
        ]),
        configurations: [
          .debug(name: "Debug"),
          .release(name: "Release"),
        ]
      )
    ),
  ]
)
