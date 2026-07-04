import Foundation

/// A normalized web URL that can be persisted by a Link card.
///
/// The app accepts forgiving text such as `example.com`, normalizes it to an
/// HTTPS URL, and stores only the canonical absolute string. LinkPresentation
/// metadata remains a display concern and is not part of this value.
struct JournalLinkURL: Hashable, Sendable, Codable {

  /// Supported schemes for rich link previews.
  private static let allowedSchemes: Set<String> = ["http", "https"]

  /// The validated URL used for LinkPresentation preview fetching.
  let url: URL

  /// Canonical string written into `Card.body`.
  var storageString: String {
    url.absoluteString
  }

  init?(_ rawValue: String) {
    let trimmedValue = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmedValue.isEmpty == false else { return nil }

    let candidateValue = Self.valueWithDefaultScheme(trimmedValue)
    guard var components = URLComponents(string: candidateValue) else { return nil }

    components.scheme = components.scheme?.lowercased()
    guard let scheme = components.scheme,
          Self.allowedSchemes.contains(scheme),
          let host = components.host,
          host.isEmpty == false,
          let url = components.url
    else {
      return nil
    }

    self.url = url
  }

  private static func valueWithDefaultScheme(_ value: String) -> String {
    guard value.contains("://") == false else {
      return value
    }

    return "https://\(value)"
  }
}
