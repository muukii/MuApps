
nonisolated struct YouTubeContentID: Codable, Identifiable, Hashable, Sendable {

  var id: String {
    return rawValue
  }

  var rawValue: String

  init(rawValue: String) {
    self.rawValue = rawValue
  }

}

// MARK: - Convenience initializer
extension YouTubeContentID {
  init(_ rawValue: String) {
    self.rawValue = rawValue
  }
}

// MARK: - String literal support for tests/previews
extension YouTubeContentID: ExpressibleByStringLiteral {
  init(stringLiteral value: String) {
    self.rawValue = value
  }
}

// MARK: - Enable direct string interpolation
extension YouTubeContentID: CustomStringConvertible {
  var description: String { rawValue }
}
