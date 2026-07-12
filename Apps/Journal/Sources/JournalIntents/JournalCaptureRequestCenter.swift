import Foundation
import JournalVault

/// One request to present an in-app Journal capture flow.
///
/// A `nil` `vaultID` means the Quick Capture Vault was not configured or could
/// not be read. The app must present setup or an error; it must not substitute
/// the currently selected or first catalog vault.
public struct JournalCaptureRequest: Identifiable, Hashable, Sendable {
  /// Unique identity used by UI coordinators to consume a request once.
  public let id: UUID

  /// Explicit destination resolved by the intent or shared preferences.
  public let vaultID: VaultID?

  /// Capture surface to present after destination validation.
  public let mode: JournalCaptureMode

  public init(
    id: UUID = UUID(),
    vaultID: VaultID?,
    mode: JournalCaptureMode
  ) {
    self.id = id
    self.vaultID = vaultID
    self.mode = mode
  }
}

/// Process-local bridge from `UISceneAppIntent` navigation into SwiftUI.
///
/// The stream buffers requests emitted before `RootView` begins observing, as
/// happens during a cold scene launch. Journal should install exactly one
/// consumer; `AsyncStream` distributes elements rather than broadcasting them
/// to multiple iterators.
public final class JournalCaptureRequestCenter: Sendable {
  public static let shared = JournalCaptureRequestCenter()

  private let stream: AsyncStream<JournalCaptureRequest>
  private let continuation: AsyncStream<JournalCaptureRequest>.Continuation

  public init() {
    let pair = AsyncStream.makeStream(
      of: JournalCaptureRequest.self,
      bufferingPolicy: .bufferingNewest(8)
    )
    stream = pair.stream
    continuation = pair.continuation
  }

  /// Stream consumed by the app's capture presentation coordinator.
  public func requests() -> AsyncStream<JournalCaptureRequest> {
    stream
  }

  /// Enqueues a navigation request without requiring SwiftUI to be initialized.
  public func submit(_ request: JournalCaptureRequest) {
    continuation.yield(request)
  }
}
