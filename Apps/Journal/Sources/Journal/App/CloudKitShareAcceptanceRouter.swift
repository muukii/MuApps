import CloudKit
#if canImport(UIKit)
import AppIntents
import JournalIntents
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// App-lifecycle bridge for CloudKit share invitation metadata.
///
/// UIKit delivers `CKShare.Metadata` through scene delegates, while the Journal
/// app state lives in SwiftUI. This router buffers metadata until `RootView`
/// starts consuming it and then hands the value to `JournalVaultRuntime`.
@MainActor
final class CloudKitShareAcceptanceRouter {

  static let shared = CloudKitShareAcceptanceRouter()

  private var pendingMetadata: [CKShare.Metadata] = []
  private var continuation: AsyncStream<CKShare.Metadata>.Continuation?
  private var consumerID: UUID?

  private init() {}

  /// Returns a stream of accepted CloudKit share metadata.
  ///
  /// The first consumer receives any metadata that arrived during cold launch
  /// before SwiftUI installed its root view. Only one process-wide consumer is
  /// kept so multi-window scenes do not accept the same invite more than once.
  func metadataStream() -> AsyncStream<CKShare.Metadata> {
    let id = UUID()
    return AsyncStream { continuation in
      self.continuation?.finish()
      self.continuation = continuation
      self.consumerID = id

      for metadata in pendingMetadata {
        continuation.yield(metadata)
      }
      pendingMetadata.removeAll()

      continuation.onTermination = { [weak self] _ in
        Task { @MainActor in
          guard self?.consumerID == id else { return }
          self?.continuation = nil
          self?.consumerID = nil
        }
      }
    }
  }

  /// Enqueues share metadata delivered by UIKit.
  func enqueue(_ metadata: CKShare.Metadata) {
    guard let continuation else {
      pendingMetadata.append(metadata)
      return
    }

    continuation.yield(metadata)
  }
}

/// Platform app delegate that forwards CloudKit invitation metadata.
#if canImport(UIKit)
@MainActor
final class TinycurveAppDelegate: UIResponder, UIApplicationDelegate {

  func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // UserNotifications asks its delegate about foreground presentation. This
    // must be installed before launch finishes or an early visible CloudKit
    // Pulse can be suppressed while the process is already active.
    SystemNotificationAuthorization.shared.installDelegate()
    // APNs registration is also required for CloudKit's silent sync transport,
    // so it is deliberately independent of the user's alert authorization.
    SystemNotificationAuthorization.shared.registerForRemoteNotifications()
    return true
  }

  /// Leaves retry ownership with the app-scoped authorization controller. A
  /// later active scene refreshes the system settings and re-registers with
  /// APNs without changing the user's visible-alert choice.
  func application(
    _ application: UIApplication,
    didFailToRegisterForRemoteNotificationsWithError error: any Error
  ) {
    SystemNotificationAuthorization.shared.noteRemoteRegistrationFailure(error)
  }

  func application(
    _ application: UIApplication,
    configurationForConnecting connectingSceneSession: UISceneSession,
    options: UIScene.ConnectionOptions
  ) -> UISceneConfiguration {
    let configuration = UISceneConfiguration(
      name: nil,
      sessionRole: connectingSceneSession.role
    )
    configuration.delegateClass = TinycurveSceneDelegate.self
    return configuration
  }
}

/// Scene delegate entry point for CloudKit invitations and App Intent-driven
/// capture navigation.
final class TinycurveSceneDelegate: UIResponder, UIWindowSceneDelegate, AppIntentSceneDelegate {

  func scene(
    _ scene: UIScene,
    willConnectTo session: UISceneSession,
    options connectionOptions: UIScene.ConnectionOptions
  ) {
    if let metadata = connectionOptions.cloudKitShareMetadata {
      CloudKitShareAcceptanceRouter.shared.enqueue(metadata)
    }
  }

  func windowScene(
    _ windowScene: UIWindowScene,
    userDidAcceptCloudKitShareWith cloudKitShareMetadata: CKShare.Metadata
  ) {
    CloudKitShareAcceptanceRouter.shared.enqueue(cloudKitShareMetadata)
  }

  /// Lets a `UISceneAppIntent` enqueue its typed navigation request after iOS
  /// connects or activates the Journal scene.
  func scene(
    _ scene: UIScene,
    willPerformAppIntent appIntent: any UISceneAppIntent
  ) {
    appIntent.performNavigation(forScene: scene)
  }
}
#elseif canImport(AppKit)
@MainActor
final class TinycurveAppDelegate: NSObject, NSApplicationDelegate {

  func applicationDidFinishLaunching(_ notification: Notification) {
    // Native macOS uses the same UserNotifications delegate as iOS. Install it
    // before launch completes so foreground visible Pulse pushes retain system
    // banner, list, and sound presentation.
    SystemNotificationAuthorization.shared.installDelegate()
    // Keep silent CloudKit synchronization registered even if the user turns
    // off system alert presentation.
    SystemNotificationAuthorization.shared.registerForRemoteNotifications()
  }

  /// The next active-state settings refresh retries the APNs registration. No
  /// device token is persisted or sent to a Tinycurve-operated server.
  func application(
    _ application: NSApplication,
    didFailToRegisterForRemoteNotificationsWithError error: any Error
  ) {
    SystemNotificationAuthorization.shared.noteRemoteRegistrationFailure(error)
  }

  func application(
    _ application: NSApplication,
    userDidAcceptCloudKitShareWith metadata: CKShare.Metadata
  ) {
    CloudKitShareAcceptanceRouter.shared.enqueue(metadata)
  }
}
#endif
