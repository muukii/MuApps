#if os(iOS)
import AppIntents
import Foundation
import JournalVault
import UIKit

/// Opens Journal directly into a selected capture flow.
///
/// `UISceneAppIntent` lets iOS connect or activate Tinycurve's scene without a
/// private URL scheme. `TinycurveSceneDelegate` must forward the received intent
/// to `performNavigation(forScene:)`; this method then emits a buffered request
/// for the SwiftUI presentation coordinator.
@available(iOS 26.0, *)
public struct OpenJournalCaptureIntent: UISceneAppIntent {
  public static let title: LocalizedStringResource = "Quick Capture"
  public static let description = IntentDescription(
    "Open Journal directly into a capture flow."
  )
  public static let supportedModes: IntentModes = .foreground(.immediate)
  public static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

  @Parameter(title: "Capture Mode")
  public var mode: JournalCaptureMode

  @Parameter(title: "Vault")
  public var vault: JournalWritableVaultEntity?

  public init() {
    mode = .text
    vault = nil
  }

  public init(
    mode: JournalCaptureMode,
    vault: JournalWritableVaultEntity? = nil
  ) {
    self.mode = mode
    self.vault = vault
  }

  public func performNavigation(forScene scene: UIScene) {
    let destinationVaultID: VaultID?
    if let vault {
      // A corrupt explicit selection is surfaced as an unconfigured request;
      // it must not redirect content to the remembered Share destination.
      destinationVaultID = vault.vaultID
    } else {
      destinationVaultID = try? JournalQuickCapturePreferences().selectedVaultID()
    }
    JournalCaptureRequestCenter.shared.submit(
      JournalCaptureRequest(
        vaultID: destinationVaultID,
        mode: mode
      )
    )
  }
}
#endif
