import JournalModel
import SwiftData
import SwiftUI
import MuColor

@main
struct JournalApp: App {

  let modelContainer: ModelContainer

  /// Syncs attachment *files* (CKAssets) in a custom zone, beside SwiftData's
  /// `.automatic` mirroring of the rows. App-process only — the widget never runs it.
  private let mediaSync = MediaSyncEngine()

  init() {
    do {
      // Shared App Group + CloudKit store, defined once in `JournalModel` so the
      // app and the `JournalWidget` extension open the identical database.
      modelContainer = try JournalStore.makeModelContainer()
    } catch {
      fatalError("Failed to create ModelContainer: \(error)")
    }
  }

  var body: some Scene {
    WindowGroup {
      RootView()
        .task { await mediaSync.start() }
        .task { SyncStatusMonitor.shared.start() }
    }
    .modelContainer(modelContainer)
  }
}

/// Reads the persisted theme and applies its palette to the whole app. Kept
/// separate from `JournalApp` so the `@AppStorage` reads live in a `View`, where
/// changes re-render the tree.
///
/// Also the first-run gate: until onboarding is completed it shows
/// `OnboardingView`, then cross-fades to the app. The completion flag is written
/// by the closure handed to `OnboardingView`, not by the onboarding view itself.
private struct RootView: View {

  @AppStorage(JournalDefaults.themeID) private var themeID: String = Theme.default.id
  @AppStorage(JournalDefaults.hasCompletedOnboarding) private var hasCompletedOnboarding: Bool = false
  @State private var notificationCenter = JournalNotificationCenter()

  var body: some View {
    PrimaryContainer(theme: Theme.with(id: themeID)) {
      JournalNotificationHost(center: notificationCenter) {
        if hasCompletedOnboarding {
          CreationView()
            .transition(.opacity)
        } else {
          OnboardingView(
            onComplete: {
              withAnimation(.smooth) { hasCompletedOnboarding = true }
            }
          )
          .transition(.opacity)
        }
      }
    }
  }
}

#Preview {
  RootView()
    .modelContainer(try! JournalStore.makeModelContainer())
}
