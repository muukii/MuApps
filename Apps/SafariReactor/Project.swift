import ProjectDescription
import ProjectDescriptionHelpers

let appBundleId = "app.muukii.safarireactor"

let appInfoPlist: InfoPlist = .extendingDefault(with: [
  "CFBundleDisplayName": "Safari Reactor",
  "CFBundleShortVersionString": "0.1.0",
  "CFBundleVersion": "1",
  "ITSAppUsesNonExemptEncryption": false,
  "LSApplicationCategoryType": "public.app-category.education",
  "UIApplicationSupportsIndirectInputEvents": true,
  "UILaunchScreen": .dictionary([:]),
])

let extensionInfoPlist: InfoPlist = .extendingDefault(with: [
  "CFBundleDisplayName": "Safari Reactor Extension",
  "CFBundleShortVersionString": "0.1.0",
  "CFBundleVersion": "1",
  "NSExtension": .dictionary([
    "NSExtensionPointIdentifier": "com.apple.Safari.web-extension",
    "NSExtensionPrincipalClass": "$(PRODUCT_MODULE_NAME).SafariWebExtensionHandler",
  ]),
])

let project = Project(
  name: "SafariReactor",
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
      name: "SafariReactor",
      destinations: .app,
      product: .app,
      bundleId: appBundleId,
      deploymentTargets: .app,
      infoPlist: appInfoPlist,
      buildableFolders: ["Sources/App"],
      dependencies: [
        .target(name: "SafariReactorExtension"),
        .project(target: "MuDesignSystem", path: "../../Shared"),
      ],
      settings: .settings(
        base: .appTarget.merging([
          "ASSETCATALOG_COMPILER_APPICON_NAME": "",
          "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "",
        ]),
        configurations: [
          .debug(name: "Debug"),
          .release(name: "Release"),
        ]
      )
    ),

    .target(
      name: "SafariReactorExtension",
      destinations: .app,
      product: .appExtension,
      bundleId: "\(appBundleId).Extension",
      deploymentTargets: .app,
      infoPlist: extensionInfoPlist,
      buildableFolders: ["Sources/Extension"],
      dependencies: [
        .sdk(name: "SafariServices", type: .framework),
      ],
      settings: .settings(
        base: .base.merging([
          "APPLICATION_EXTENSION_API_ONLY": "YES",
          "OTHER_LDFLAGS": "$(inherited) -framework SafariServices",
        ]),
        configurations: [
          .debug(name: "Debug"),
          .release(name: "Release"),
        ]
      )
    ),
  ]
)
