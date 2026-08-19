import Foundation

/// Runtime transport selected for the Tinycurve application process.
///
/// Hosted unit tests instantiate the app target to exercise SwiftUI and
/// `@testable` code. They must not start a real `CKSyncEngine`, reconcile
/// subscriptions, or mutate a signed-in developer's CloudKit account merely
/// because the test host created `TinycurveApp`.
enum TinycurveRuntimeLaunchMode: Equatable {
  /// Normal application launch uses the production CloudKit transport owner.
  case cloudKit

  /// XCTest-hosted launch uses the network-less logging transport owner.
  case logging
}

/// Determines the runtime transport before Tinycurve creates its app-lifetime
/// vault owner.
enum TinycurveRuntimeLaunchPolicy {

  /// Returns the safe transport mode for a process environment.
  ///
  /// Xcode supplies `XCTestConfigurationFilePath` for hosted tests. The bundle
  /// path fallback covers runners that omit that first key while still loading
  /// XCTest into the app process. Production app launches set neither key.
  static func runtimeMode(environment: [String: String]) -> TinycurveRuntimeLaunchMode {
    let isHostedTest = [
      environment["XCTestConfigurationFilePath"],
      environment["XCTestBundlePath"],
    ].contains { value in
      guard let value else { return false }
      return value.isEmpty == false
    }

    return isHostedTest ? .logging : .cloudKit
  }

  /// Creates the app-lifetime vault runtime for the detected process mode.
  static func makeVaultRuntime(
    environment: [String: String] = ProcessInfo.processInfo.environment
  ) throws -> JournalVaultRuntime {
    switch runtimeMode(environment: environment) {
    case .cloudKit:
      try JournalVaultRuntime.appGroupCloudKitRuntime()
    case .logging:
      try JournalVaultRuntime.appGroupLoggingRuntime()
    }
  }
}
