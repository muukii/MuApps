// swift-tools-version: 6.0
@preconcurrency import PackageDescription

#if TUIST
@preconcurrency import ProjectDescription

let avifDependencyHeaderSearchPaths: ProjectDescription.SettingValue = .array([
  "$(inherited)",
  "$(SRCROOT)/Sources/avifc",
  "$(SRCROOT)/Sources/avifc/include",
  "$(SRCROOT)/Sources/libavif/include",
  "$(SRCROOT)/../libaom.swift/Sources/libaom/libaom.xcframework/ios-arm64/Headers",
  "$(SRCROOT)/../libaom.swift/Sources/libaom/libaom.xcframework/ios-arm64_x86_64-simulator/Headers",
  "$(SRCROOT)/../libdav1d.swift/Sources/libdav1d.xcframework/ios-arm64/Headers",
  "$(SRCROOT)/../libdav1d.swift/Sources/libdav1d.xcframework/ios-arm64_x86_64-simulator/Headers",
  "$(SRCROOT)/../libsvtav1enc.swift/Sources/libSvtAv1Enc.xcframework/ios-arm64/Headers",
  "$(SRCROOT)/../libsvtav1enc.swift/Sources/libSvtAv1Enc.xcframework/ios-arm64_x86_64-simulator/Headers",
  "$(SRCROOT)/../libwebp-ios/Sources/libsharpyuv.xcframework/ios-arm64/Headers",
  "$(SRCROOT)/../libwebp-ios/Sources/libsharpyuv.xcframework/ios-arm64_x86_64-simulator/Headers",
  "$(SRCROOT)/../libwebp-ios/Sources/libwebp.xcframework/ios-arm64/Headers",
  "$(SRCROOT)/../libwebp-ios/Sources/libwebp.xcframework/ios-arm64_x86_64-simulator/Headers",
  "$(SRCROOT)/../libyuv.swift/Sources/libyuv.xcframework/ios-arm64/Headers",
  "$(SRCROOT)/../libyuv.swift/Sources/libyuv.xcframework/ios-arm64_x86_64-simulator/Headers",
])

let packageSettings = PackageSettings(
  productTypes: [:],
  targetSettings: [
    "ObjectEdge": .settings(base: [
      "MACOSX_DEPLOYMENT_TARGET": "14.0",
    ]),
    "avifc": .settings(base: [
      "HEADER_SEARCH_PATHS": avifDependencyHeaderSearchPaths,
    ]),
    "libavif": .settings(base: [
      "HEADER_SEARCH_PATHS": avifDependencyHeaderSearchPaths,
    ]),
  ]
)
#endif

let package = Package(
  name: "MuApps",
  dependencies: [
    // YouTube related
    .package(url: "https://github.com/alexeichhorn/YouTubeKit", from: "0.4.8"),
    .package(url: "https://github.com/apple/swift-algorithms", from: "1.2.1"),

    // UI components
    .package(url: "https://github.com/FluidGroup/swiftui-object-edge", from: "1.0.0"),
    .package(url: "https://github.com/FluidGroup/swiftui-ring-slider", from: "0.2.0"),
    .package(url: "https://github.com/FluidGroup/swiftui-async-multiplex-image", from: "1.0.0"),
    .package(url: "https://github.com/FluidGroup/swiftui-support.git", from: "0.13.0"),
    .package(url: "https://github.com/FluidGroup/swiftui-persistent-control.git", revision: "093554c7a02642acb306b8e8482fd3b8322314f3"),
    .package(url: "https://github.com/FluidGroup/swift-dynamic-list", revision: "0c1fd1dcc0eb7283818166905c5536028edbbe9d"),
    .package(url: "https://github.com/siteline/swiftui-introspect", "1.3.0"..<"27.0.0"),
    .package(url: "https://github.com/dmrschmidt/DSWaveformImage", from: "14.2.2"),
    .package(url: "https://github.com/muukii/swift-macro-hex-color", from: "0.1.1"),

    // State management and utilities
    .package(url: "https://github.com/VergeGroup/swift-typed-identifier", from: "2.0.4"),
    .package(url: "https://github.com/VergeGroup/swift-state-graph", revision: "f6290206f05d4bb13f75518ef7406167331513f6"),
    .package(url: "https://github.com/VergeGroup/Wrap", from: "4.0.0"),
    .package(url: "https://github.com/VergeGroup/swift-concurrency-task-manager", from: "2.1.4"),
    .package(url: "https://github.com/dagronf/SwiftSubtitles", from: "0.5.0"),
    .package(url: "https://github.com/Alamofire/Alamofire.git", from: "5.10.2"),

    // Media conversion
    .package(url: "https://github.com/awxkee/avif.swift", from: "1.0.0"),
  ]
)
