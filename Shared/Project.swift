import ProjectDescription
import ProjectDescriptionHelpers

// 共有モジュールをまとめて置く Project。
//
// モジュール追加手順:
//   1. Shared/<ModuleName>/ にディレクトリを作り Swift ソースを置く
//   2. 下の targets 配列に .target(...) を追加 (MuDesignSystem を参考に)
//   3. 使いたいアプリの Project.swift に依存を追加:
//        .project(target: "<ModuleName>", path: "../../Shared")
//   4. `tuist generate` で反映

let project = Project(
  name: "Shared",
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
      name: "MuDesignSystem",
      destinations: .app,
      product: .staticFramework,
      bundleId: "app.muukii.shared.designsystem",
      deploymentTargets: .app,
      infoPlist: .default,
      buildableFolders: ["MuDesignSystem"],
      dependencies: [],
      settings: .settings(
        base: .frameworkTarget,
        configurations: [
          .debug(name: "Debug"),
          .release(name: "Release"),
        ]
      )
    ),
  ]
)
