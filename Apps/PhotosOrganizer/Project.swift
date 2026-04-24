import ProjectDescription
import ProjectDescriptionHelpers

let appInfoPlist: InfoPlist = .extendingDefault(with: [
  "CFBundleDisplayName": "PhotosOrganizer",
  "CFBundleShortVersionString": "1.0",
  "CFBundleVersion": "1",
  "ITSAppUsesNonExemptEncryption": false,
  "LSApplicationCategoryType": "public.app-category.utilities",
  "NSPhotoLibraryAddUsageDescription": "Save converted images to your photo library",
  "NSPhotoLibraryUsageDescription": "Access your photos to find large files and optimize storage",
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
  name: "PhotosOrganizer",
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
      name: "PhotosOrganizer",
      destinations: .app,
      product: .app,
      bundleId: "app.muukii.PhotosOrganizer",
      deploymentTargets: .multiplatform(iOS: "26.2"),
      infoPlist: appInfoPlist,
      buildableFolders: ["Sources"],
      dependencies: [
        .external(name: "avif"),
      ],
      settings: .settings(
        base: .appTarget.merging([
          "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
        ]),
        configurations: [
          .debug(name: "Debug"),
          .release(name: "Release"),
        ]
      )
    ),
  ]
)
