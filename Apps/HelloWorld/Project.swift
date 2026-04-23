import ProjectDescription
import ProjectDescriptionHelpers

let project = Project(
  name: "HelloWorld",
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
      name: "HelloWorld",
      destinations: .app,
      product: .app,
      bundleId: "app.muukii.helloworld",
      deploymentTargets: .app,
      infoPlist: .extendingDefault(with: [
        "CFBundleDisplayName": "HelloWorld",
        "ITSAppUsesNonExemptEncryption": false,
        "LSApplicationCategoryType": "public.app-category.utilities",
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
