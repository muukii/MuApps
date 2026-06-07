import ProjectDescription
import ProjectDescriptionHelpers

let project = Project(
  name: "CodexPet",
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
      name: "CodexPet",
      destinations: .app,
      product: .app,
      bundleId: "app.muukii.codexpet",
      deploymentTargets: .app,
      infoPlist: .extendingDefault(with: [
        "CFBundleDisplayName": "Codex Pet",
        "ITSAppUsesNonExemptEncryption": false,
        "LSApplicationCategoryType": "public.app-category.entertainment",
        "UIApplicationSupportsIndirectInputEvents": true,
        "UILaunchScreen": .dictionary([:]),
        "UIUserInterfaceStyle": "Light",
      ]),
      resources: [
        "Sources/Assets.xcassets",
      ],
      buildableFolders: [
        "Sources/App",
        "Sources/Shared",
      ],
      dependencies: [
        .target(name: "CodexPetWidget"),
      ],
      settings: .settings(
        base: .appTarget.merging([
          "ASSETCATALOG_COMPILER_APPICON_NAME": "",
          "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "AccentColor",
        ]),
        configurations: [
          .debug(name: "Debug"),
          .release(name: "Release"),
        ]
      )
    ),

    .target(
      name: "CodexPetWidget",
      destinations: .app,
      product: .appExtension,
      bundleId: "app.muukii.codexpet.Widget",
      deploymentTargets: .app,
      infoPlist: .dictionary([
        "CFBundleDisplayName": "Codex Pet Widget",
        "CFBundleExecutable": "$(EXECUTABLE_NAME)",
        "CFBundleIdentifier": "$(PRODUCT_BUNDLE_IDENTIFIER)",
        "CFBundleName": "$(PRODUCT_NAME)",
        "CFBundleShortVersionString": "1.0",
        "CFBundleVersion": "1",
        "NSExtension": .dictionary([
          "NSExtensionPointIdentifier": "com.apple.widgetkit-extension",
        ]),
      ]),
      resources: [
        "Sources/Assets.xcassets",
      ],
      buildableFolders: [
        "Sources/Widget",
        "Sources/Shared",
      ],
      dependencies: [],
      settings: .settings(
        base: .base.merging([
          "APPLICATION_EXTENSION_API_ONLY": "YES",
          "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME": "AccentColor",
        ]),
        configurations: [
          .debug(name: "Debug"),
          .release(name: "Release"),
        ]
      )
    ),
  ]
)
