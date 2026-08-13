import ProjectDescription
import ProjectDescriptionHelpers

let project = Project(
  name: "ColorPlayground",
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
      name: "ColorPlayground",
      destinations: .app,
      product: .app,
      bundleId: "app.muukii.colorplayground",
      deploymentTargets: .app,
      infoPlist: .extendingDefault(with: [
        "CFBundleDisplayName": "Color Playground",
        "ITSAppUsesNonExemptEncryption": false,
        "LSApplicationCategoryType": "public.app-category.developer-tools",
        "UILaunchScreen": .dictionary([:]),
      ]),
      buildableFolders: ["Sources"],
      dependencies: [],
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
