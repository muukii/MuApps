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

    // State management and utilities
    .package(url: "https://github.com/VergeGroup/swift-typed-identifier", from: "2.0.4"),
    .package(url: "https://github.com/VergeGroup/swift-state-graph", from: "0.16.0"),

    // Media conversion
    .package(url: "https://github.com/awxkee/avif.swift", from: "1.0.0"),
  ]
)
