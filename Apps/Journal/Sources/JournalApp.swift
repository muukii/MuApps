import JournalModel
import SwiftData
import SwiftUI
import MuColor

@main
struct JournalApp: App {

  let modelContainer: ModelContainer

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
    }
    .modelContainer(modelContainer)
  }
}

/// Reads the persisted theme and applies its palette to the whole app. Kept
/// separate from `JournalApp` so the `@AppStorage` read lives in a `View`, where
/// changes re-render the tree.
private struct RootView: View {

  @AppStorage(JournalDefaults.themeID) private var themeID: String = Theme.default.id

  var body: some View {
    PrimaryContainer(theme: Theme.with(id: themeID)) {
      CreationView()
    }
  }
}

#Preview {
  RootView()
    .modelContainer(try! JournalStore.makeModelContainer())
}
