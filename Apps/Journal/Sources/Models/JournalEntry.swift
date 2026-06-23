import Foundation
import SwiftData

/// A single journal entry.
///
/// CloudKit mirroring (via SwiftData) imposes modeling constraints: every
/// stored property must be optional or carry a default value, no `.unique`
/// attributes are allowed, and relationships must be optional. This model is
/// kept deliberately minimal — the journaling UI is still being designed, so
/// fields will grow as the feature takes shape.
@Model
final class JournalEntry {

  /// Logical identifier. CloudKit mirroring cannot enforce uniqueness
  /// (`.unique` is forbidden), so the same logical entry created on two devices
  /// would produce duplicate rows — dedup is an app-level concern to handle if
  /// it ever matters.
  var id: UUID = UUID()
  var createdAt: Date = Date()
  var updatedAt: Date = Date()
  var title: String = ""
  var body: String = ""

  init(title: String = "", body: String = "") {
    self.id = UUID()
    self.createdAt = Date()
    self.updatedAt = Date()
    self.title = title
    self.body = body
  }
}
