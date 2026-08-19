import AppIntents
import JournalIntents

/// Publishes `JournalIntents`' App Intents metadata under the app bundle.
///
/// `OpenJournalCaptureIntent` is a `UISceneAppIntent`, so iOS resolves it
/// against this process to connect or activate a scene. Framework metadata is
/// only registered for a bundle that includes the framework's package, and the
/// widget and App Intents extensions each declare their own. Without this
/// declaration the app bundle ships no `Metadata.appintents`, and a Control
/// Center or Action Button tap has no app-side definition to launch into.
struct TinycurveAppIntentsPackage: AppIntentsPackage {
  nonisolated(unsafe) static let includedPackages: [any AppIntentsPackage.Type] = [
    JournalAppIntentsPackage.self,
  ]
}
