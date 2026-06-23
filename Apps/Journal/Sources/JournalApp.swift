import SwiftData
import SwiftUI
import MuColor

@main
struct JournalApp: App {

  let modelContainer: ModelContainer

  init() {
    do {
      let schema = Schema([
        JournalEntry.self
      ])
      // `.automatic` enables CloudKit mirroring using the iCloud container
      // declared in the app's entitlements (iCloud.app.muukii.journal).
      let configuration = ModelConfiguration(
        schema: schema,
        cloudKitDatabase: .automatic
      )
      modelContainer = try ModelContainer(for: schema, configurations: configuration)
    } catch {
      fatalError("Failed to create ModelContainer: \(error)")
    }
  }

  var body: some Scene {
    WindowGroup {
      PaletteContainer(palette: .default) {         
        CaptureGalleryView()
      }
    }
    .modelContainer(modelContainer)
  }
}
