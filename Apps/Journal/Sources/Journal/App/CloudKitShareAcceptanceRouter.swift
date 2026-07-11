import CloudKit
#if canImport(UIKit)
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
final class JournalAppDelegate: UIResponder, UIApplicationDelegate {

  func application(
    _ application: UIApplication,
    configurationForConnecting connectingSceneSession: UISceneSession,
    options: UIScene.ConnectionOptions
  ) -> UISceneConfiguration {
    let configuration = UISceneConfiguration(
      name: nil,
      sessionRole: connectingSceneSession.role
    )
    configuration.delegateClass = JournalSceneDelegate.self
    return configuration
  }
}

/// Scene delegate entry point for CloudKit share invitations.
final class JournalSceneDelegate: UIResponder, UIWindowSceneDelegate {

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
}
#elseif canImport(AppKit)
final class JournalAppDelegate: NSObject, NSApplicationDelegate {
  func application(
    _ application: NSApplication,
    userDidAcceptCloudKitShareWith metadata: CKShare.Metadata
  ) {
    CloudKitShareAcceptanceRouter.shared.enqueue(metadata)
  }
}
#endif
