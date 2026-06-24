import Foundation
import SwiftData

/// The shared persistence layer for the Journal app and its extensions.
///
/// The SwiftData store lives in the **App Group** container so the app process
/// and the Widget process read the same database; CloudKit mirroring keeps it
/// in sync across devices. Both the app target and every extension that needs
/// journal data must declare `appGroupIdentifier` in their entitlements, or the
/// shared container is inaccessible and `makeModelContainer()` throws.
///
/// This is the single source of truth for the schema and store location — never
/// build a `ModelContainer` for journal data anywhere else.
///
/// - Tag: JournalStore
public enum JournalStore {

  /// App Group backing the shared store. Listed under
  /// `com.apple.security.application-groups` in both the app and widget
  /// entitlements (see `Project.swift`).
  public static let appGroupIdentifier = "group.app.muukii.journal"

  /// The SwiftData schema. Every `@Model` type the store persists is registered
  /// here; the app and the widget must use the identical schema.
  public static let schema = Schema([
    Card.self,
    Tag.self,
  ])

  /// Builds the shared `ModelContainer`. Called by the app at launch and by the
  /// widget's timeline provider.
  ///
  /// `groupContainer: .identifier(...)` places the store inside the App Group
  /// container so both processes see the same file; `cloudKitDatabase:
  /// .automatic` mirrors it through the iCloud container declared in
  /// entitlements (`iCloud.app.muukii.journal`).
  public static func makeModelContainer() throws -> ModelContainer {
    let configuration = ModelConfiguration(
      schema: schema,
      groupContainer: .identifier(appGroupIdentifier),
      cloudKitDatabase: .automatic
    )
    return try ModelContainer(for: schema, configurations: configuration)
  }
}
