import SwiftData
import SwiftUI

@main
struct PolyReaderApp: App {
  let modelContainer: ModelContainer

  init() {
    let schema = Schema([
      ReadingText.self,
    ])

    do {
      modelContainer = try ModelContainer(for: schema)
    } catch {
      fatalError("Failed to create PolyReader model container: \(error)")
    }
  }

  var body: some Scene {
    WindowGroup {
      LibraryView()
    }
    .modelContainer(modelContainer)
  }
}
