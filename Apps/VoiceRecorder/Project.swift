import ProjectDescription
import ProjectDescriptionHelpers

let recorderInfoPlist: InfoPlist = .extendingDefault(with: [
  "CFBundleDisplayName": "Voice Recorder",
  "ITSAppUsesNonExemptEncryption": false,
  "LSApplicationCategoryType": "public.app-category.utilities",
  "NSMicrophoneUsageDescription":
    "This app uses the microphone for live audio streaming and temporary live transcription.",
  "NSSpeechRecognitionUsageDescription":
    "This app uses speech recognition to show temporary live captions while streaming audio.",
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
