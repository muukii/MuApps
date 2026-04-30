import Foundation
import SwiftData

@Model
final class ReadingText {
  var id: UUID
  var title: String
  var body: String
  var createdAt: Date
  var updatedAt: Date
  var currentSentenceIndex: Int

  init(
    title: String,
    body: String,
    currentSentenceIndex: Int = 0
  ) {
    let now = Date()

    self.id = UUID()
    self.title = title
    self.body = body
    self.createdAt = now
    self.updatedAt = now
    self.currentSentenceIndex = currentSentenceIndex
  }
}
