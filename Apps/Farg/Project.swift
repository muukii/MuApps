import ProjectDescription
import ProjectDescriptionHelpers

/// Property-list values owned by the Färg application target.
let appInfoPlist: InfoPlist = .extendingDefault(with: [
  "BGTaskSchedulerPermittedIdentifiers": .array([
    "app.muukii.farg.export.*",
  ]),
  "CFBundleDisplayName": "Färg",
  "CFBundleName": "Färg",
  "CFBundleShortVersionString": "1.0",
  "CFBundleVersion": "1",
  "ITSAppUsesNonExemptEncryption": false,
  "LSApplicationCategoryType": "public.app-category.photo-video",
  "NSPhotoLibraryAddUsageDescription":
    "Färg saves the exported video to your photo library.",
  "NSPhotoLibraryUsageDescription":
    "Färg reads videos and preview sample images you choose so you can evaluate a LUT and export.",
  "UILaunchScreen": .dictionary([:]),
  "UISupportedInterfaceOrientations": .array([
    "UIInterfaceOrientationPortrait",
  ]),
])

let project = Project(
  name: "Farg",
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
      name: "FargMotionBlur",
      destinations: [.iPhone],
      product: .framework,
      bundleId: "app.muukii.farg.MotionBlur",
      deploymentTargets: .app,
      infoPlist: .default,
      buildableFolders: ["MotionBlur/Sources"],
      dependencies: [
        .sdk(name: "AVFoundation", type: .framework),
        .sdk(name: "CoreImage", type: .framework),
        .sdk(name: "VideoToolbox", type: .framework),
      ],
      settings: .settings(
        base: .frameworkTarget,
        configurations: [
          .debug(name: "Debug"),
          .release(name: "Release"),
        ]
      )
    ),
    .target(
      name: "FargMotionBlurTests",
      destinations: [.iPhone],
      product: .unitTests,
      bundleId: "app.muukii.farg.MotionBlurTests",
      deploymentTargets: .app,
      infoPlist: .default,
      buildableFolders: ["MotionBlur/Tests"],
      dependencies: [
        .target(name: "FargMotionBlur"),
      ],
      settings: .settings(
        configurations: [
          .debug(name: "Debug"),
          .release(name: "Release"),
        ]
      )
    ),
    .target(
      name: "Farg",
      destinations: [.iPhone],
      product: .app,
      bundleId: "app.muukii.farg",
      deploymentTargets: .app,
      infoPlist: appInfoPlist,
      resources: [
        "Icon.icon",
        "Resources/**",
      ],
      buildableFolders: ["Sources"],
      entitlements: .dictionary([
        // Core Image rendering continues on the GPU while the export task is
        // running after the app leaves the foreground.
        "com.apple.developer.background-tasks.continued-processing.gpu": true,
      ]),
      dependencies: [
        .target(name: "FargMotionBlur"),
        .external(name: "BrightroomParametric"),
      ],
      settings: .settings(
        base: .appTarget.merging([
          "ASSETCATALOG_COMPILER_APPICON_NAME": "Icon",
        ]),
        configurations: [
          .debug(name: "Debug"),
          .release(name: "Release"),
        ]
      )
    ),
    .target(
      name: "FargTests",
      destinations: [.iPhone],
      product: .unitTests,
      bundleId: "app.muukii.farg.Tests",
      deploymentTargets: .app,
      infoPlist: .default,
      buildableFolders: ["Tests/FargTests"],
      dependencies: [
        .target(name: "Farg"),
        .target(name: "FargMotionBlur"),
        .external(name: "BrightroomParametric"),
      ],
      settings: .settings(
        configurations: [
          .debug(name: "Debug"),
          .release(name: "Release"),
        ]
      )
    ),
  ],
  schemes: [
    .scheme(
      name: "FargMotionBlurTests",
      shared: true,
      buildAction: .buildAction(targets: ["FargMotionBlurTests"]),
      testAction: .targets([
        .testableTarget(
          target: "FargMotionBlurTests",
          parallelization: .swiftTestingOnly
        ),
      ])
    ),
    .scheme(
      name: "FargTests",
      shared: true,
      buildAction: .buildAction(targets: ["FargTests"]),
      testAction: .targets([
        .testableTarget(
          target: "FargTests",
          parallelization: .swiftTestingOnly
        ),
      ])
    ),
  ]
)
