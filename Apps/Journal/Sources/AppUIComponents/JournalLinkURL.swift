import Foundation

/// A normalized web URL that can be persisted by a Link card.
///
/// The app accepts forgiving text such as `example.com`, normalizes it to an
/// HTTPS URL, and stores only the canonical absolute string. LinkPresentation
/// metadata remains a display concern and is not part of this value.
public struct JournalLinkURL: Hashable, Sendable, Codable {

  /// Supported schemes for rich link previews.
  private static let allowedSchemes: Set<String> = ["http", "https"]

  /// The validated URL used for LinkPresentation preview fetching.
  public let url: URL

  /// Canonical string written into `Card.body`.
  public var storageString: String {
    url.absoluteString
  }

  public init?(_ rawValue: String) {
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

  /// Creates a Link value only when the complete input is one detected web URL.
  ///
  /// URL normalization alone is intentionally permissive enough to support a
  /// bare domain. The data detector adds the authorship boundary needed by
  /// automatic import surfaces: prose containing a URL must remain Text rather
  /// than becoming a Link card.
  public init?(entireWebURL rawValue: String) {
    let candidate = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
    guard candidate.isEmpty == false,
      let detector = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue
      )
    else {
      return nil
    }

    let candidateRange = NSRange(candidate.startIndex..<candidate.endIndex, in: candidate)
    guard
      let match = detector.firstMatch(
        in: candidate,
        options: [],
        range: candidateRange
      ),
      match.range == candidateRange,
      let scheme = match.url?.scheme?.lowercased(),
      Self.allowedSchemes.contains(scheme),
      let normalizedURL = JournalLinkURL(candidate)
    else {
      return nil
    }

    self = normalizedURL
  }

  private static func valueWithDefaultScheme(_ value: String) -> String {
    guard value.contains("://") == false else {
      return value
    }

    return "https://\(value)"
  }
}
