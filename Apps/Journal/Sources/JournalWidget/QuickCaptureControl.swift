#if os(iOS)
import AppIntents
import JournalIntents
import SwiftUI
import WidgetKit

/// User-configurable control for Control Center, Lock Screen, and the iPhone
/// Action Button.
///
/// The control opens Journal's scene through `UISceneAppIntent`; it never tries
/// to capture private journal content while the device remains locked.
struct QuickCaptureControl: ControlWidget {
  private let kind = "app.muukii.journal.quick-capture-control"

  var body: some ControlWidgetConfiguration {
    AppIntentControlConfiguration(
      kind: kind,
      intent: QuickCaptureControlConfiguration.self
    ) { configuration in
      ControlWidgetButton(
        action: OpenJournalCaptureIntent(
          mode: configuration.mode ?? .text,
          vault: configuration.vault
        )
      ) {
        Label("Quick Capture", systemImage: "square.and.pencil")
      }
    }
    .displayName("Quick Capture")
    .description("Open Tinycurve in the capture mode and vault you choose.")
  }
}

/// Per-control configuration shown by iOS when a user adds or edits the control.
struct QuickCaptureControlConfiguration: ControlConfigurationIntent {
  static let title: LocalizedStringResource = "Quick Capture"
  static let description = IntentDescription(
    "Choose the capture mode and destination vault."
  )

  @Parameter(title: "Capture Mode")
  var mode: JournalCaptureMode?

  @Parameter(
    title: "Vault",
    description: "Leave empty to use the Quick Capture Vault from Journal Settings."
  )
  var vault: JournalWritableVaultEntity?

  static var parameterSummary: some ParameterSummary {
    Summary("Open \(\.$mode) in \(\.$vault)")
  }

  init() {
    mode = .text
    vault = nil
  }
}

/// Includes the framework-owned scene intent and Vault entities in the widget
/// extension's metadata package so the Control action resolves independently of
/// the background App Intents extension.
struct JournalWidgetIntentsPackage: AppIntentsPackage {
  nonisolated(unsafe) static let includedPackages: [any AppIntentsPackage.Type] = [
    JournalAppIntentsPackage.self,
  ]
}
#endif
