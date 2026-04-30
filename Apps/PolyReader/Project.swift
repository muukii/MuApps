import ProjectDescription
import ProjectDescriptionHelpers

let appInfoPlist: InfoPlist = .extendingDefault(with: [
  "CFBundleDisplayName": "PolyReader",
  "ITSAppUsesNonExemptEncryption": false,
  "LSApplicationCategoryType": "public.app-category.education",
  "UILaunchScreen": .dictionary([:]),
])

let project = Project(
  name: "PolyReader",
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
      name: "PolyReader",
      destinations: .app,
      product: .app,
      bundleId: "app.muukii.polyreader",
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
