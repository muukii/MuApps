import ProjectDescription
import ProjectDescriptionHelpers

let recorderInfoPlist: InfoPlist = .extendingDefault(with: [
  "CFBundleDisplayName": "Voice Recorder",
  "ITSAppUsesNonExemptEncryption": false,
  "LSApplicationCategoryType": "public.app-category.utilities",
  "NSMicrophoneUsageDescription":
    "This app uses the microphone to record voice clips and provide delayed headphone monitoring.",
  "UILaunchScreen": .dictionary([:]),
])

let project = Project(
  name: "VoiceRecorder",
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
      name: "VoiceRecorder",
      destinations: .app,
      product: .app,
      bundleId: "app.muukii.voicerecorder",
      deploymentTargets: .app,
      infoPlist: recorderInfoPlist,
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
