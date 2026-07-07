// swift-tools-version: 6.0

import CompilerPluginSupport
import PackageDescription

let package = Package(
  name: "CloudKitSupport",
  platforms: [
    .iOS(.v17),
    .macOS(.v14),
  ],
  products: [
    .library(
      name: "CloudKitSupport",
      targets: ["CloudKitSupport"]
    ),
  ],
  dependencies: [
    .package(url: "https://github.com/apple/swift-syntax.git", "600.0.0"..<"603.0.0"),
  ],
  targets: [
    .macro(
      name: "CloudKitSupportMacros",
      dependencies: [
        .product(name: "SwiftSyntaxMacros", package: "swift-syntax"),
        .product(name: "SwiftCompilerPlugin", package: "swift-syntax"),
      ]
    ),
    .target(
      name: "CloudKitSupport",
      dependencies: ["CloudKitSupportMacros"]
    ),
    .testTarget(
      name: "CloudKitSupportMacrosTests",
      dependencies: [
        "CloudKitSupportMacros",
        .product(name: "SwiftSyntaxMacrosTestSupport", package: "swift-syntax"),
      ]
    ),
  ],
  swiftLanguageModes: [.v6]
)
