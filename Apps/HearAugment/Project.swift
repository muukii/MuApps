import ProjectDescription
import ProjectDescriptionHelpers

let hearAugmentInfoPlist: InfoPlist = .extendingDefault(with: [
  "CFBundleDisplayName": "Hear Augment",
  "ITSAppUsesNonExemptEncryption": false,
  "LSApplicationCategoryType": "public.app-category.healthcare-fitness",
  "NSMicrophoneUsageDescription":
    "Hear Augment uses the microphone to process nearby sound in real time and play the filtered audio through headphones.",
  "UILaunchScreen": .dictionary([:]),
])

let project = Project(
  name: "HearAugment",
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
      name: "HearAugment",
      destinations: .app,
      product: .app,
      bundleId: "app.muukii.hearaugment",
      deploymentTargets: .app,
      infoPlist: hearAugmentInfoPlist,
      buildableFolders: ["Sources"],
      dependencies: [
        .project(target: "MuDesignSystem", path: "../../Shared"),
      ],
      settings: .settings(
        base: .appTarget.merging([
          "CLANG_CXX_LANGUAGE_STANDARD": "gnu++17",
          "SWIFT_OBJC_BRIDGING_HEADER": "Sources/HearAugment-Bridging-Header.h",
        ]),
        configurations: [
          .debug(name: "Debug"),
          .release(name: "Release"),
        ]
      )
    )
  ]
)
