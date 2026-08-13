import ProjectDescription
import ProjectDescriptionHelpers

let project = Project(
  name: "TabLab",
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
      name: "TabLab",
      destinations: .app,
      product: .app,
      bundleId: "app.muukii.tablab",
      deploymentTargets: .app,
      infoPlist: .extendingDefault(with: [
        "CFBundleDisplayName": "TabLab",
        "ITSAppUsesNonExemptEncryption": false,
        "LSApplicationCategoryType": "public.app-category.developer-tools",
        "UILaunchScreen": .dictionary([:]),
      ]),
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
