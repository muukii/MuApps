import Foundation
import SwiftUI
import Testing

@testable import AppUIComponents

@Suite("Text URL link detection")
struct TextLinkDetectorTests {

  @Test("Only saved Cell text enables URL detection")
  func scopesDetectionToSavedCellPresentation() {
    #expect(TextContentView.Style(.cell).usesDetectedLinks)
    #expect(TextContentView.Style(.composer).usesDetectedLinks == false)
  }

  @Test("HTTP(S) and bare domains become native links")
  func detectsWebURLs() async {
    let source = AttributedString(
      "See http://example.net, https://example.com/docs, and www.example.org/about."
    )

    let result = await TextLinkDetector.process(source)
    let links = detectedLinks(in: result)

    #expect(
      links.map(\.text) == [
        "http://example.net",
        "https://example.com/docs",
        "www.example.org/about",
      ]
    )
    #expect(
      links.map(\.url.absoluteString) == [
        "http://example.net",
        "https://example.com/docs",
        "https://www.example.org/about",
      ]
    )
    #expect(links.allSatisfy { $0.isUnderlined })
  }

  @Test("Unicode before a URL keeps the detected range aligned")
  func preservesUnicodeRangeAlignment() async {
    let source = AttributedString("思い出🙂 https://example.com 次の文章")

    let result = await TextLinkDetector.process(source)

    #expect(String(result.characters) == String(source.characters))
    #expect(detectedLinks(in: result).map(\.text) == ["https://example.com"])
  }

  @Test("Email addresses and custom schemes remain plain text")
  func rejectsNonWebLinks() async {
    let source = AttributedString(
      "Mail hello@example.com or open tinycurve://entry/123."
    )

    let result = await TextLinkDetector.process(source)

    #expect(detectedLinks(in: result).isEmpty)
  }

  @Test("Existing attributed text presentation is preserved")
  func preservesExistingAttributes() async {
    var source = AttributedString("Read https://example.com")
    source.inlinePresentationIntent = .stronglyEmphasized

    let result = await TextLinkDetector.process(source)

    #expect(result.inlinePresentationIntent == .stronglyEmphasized)
    #expect(String(result.characters) == String(source.characters))
  }

  private func detectedLinks(
    in attributedText: AttributedString
  ) -> [DetectedLink] {
    attributedText.runs.compactMap { run in
      guard let url = run.link else { return nil }

      return DetectedLink(
        text: String(attributedText[run.range].characters),
        url: url,
        isUnderlined: run.underlineStyle != nil
      )
    }
  }

  /// A stable test projection of the attributes SwiftUI consumes.
  private struct DetectedLink: Equatable {
    let text: String
    let url: URL
    let isUnderlined: Bool
  }
}
