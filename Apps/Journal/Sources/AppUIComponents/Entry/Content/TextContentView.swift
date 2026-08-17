import Foundation
import MuColor
import SwiftUI

/// Renders written entry content using placement-specific typography.
struct TextContentView: View {

  /// Visual treatment owned by written content.
  struct Style {
    let preset: EntryContentStyle
    let emptyTitle: LocalizedStringResource

    init(
      _ preset: EntryContentStyle,
      emptyTitle: LocalizedStringResource? = nil
    ) {
      self.preset = preset
      self.emptyTitle = emptyTitle ?? Self.defaultEmptyTitle(for: preset)
    }

    var font: Font {
      .headline.weight(.semibold)
    }

    var lineLimit: Int? {
      switch preset {
      case .composer:
        return 8
      case .cell:
        return nil
      }
    }

    private static func defaultEmptyTitle(
      for preset: EntryContentStyle
    ) -> LocalizedStringResource {
      switch preset {
      case .composer:
        return "Text"
      case .cell:
        return "Empty text"
      }
    }

    var lineSpacing: CGFloat { 0 }

    var minimumScaleFactor: CGFloat { 1 }

    var usesComposerForeground: Bool {
      switch preset {
      case .composer:
        return true
      case .cell:
        return false
      }
    }

    var usesDetectedLinks: Bool {
      switch preset {
      case .cell:
        return true
      case .composer:
        return false
      }
    }

    var minimumHeight: CGFloat? { nil }
  }

  let text: String
  let style: Style

  var body: some View {
    ZStack {
      if style.usesComposerForeground {
        Text(text)
          .font(style.font)
          .lineLimit(style.lineLimit)
          .foregroundStyle(.primary)
      } else {
        renderedText
          .font(style.font)
          .lineLimit(style.lineLimit)
          .lineSpacing(style.lineSpacing)
          .minimumScaleFactor(style.minimumScaleFactor)
      }
    }
    .padding(16)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.appSecondaryContainer)

  }

  @ViewBuilder
  private var renderedText: some View {
    if style.usesDetectedLinks {
      LinkDetectionText(attributedText: AttributedString(text))
    } else {
      Text(text)
    }
  }
}

// MARK: - Private Views

/// Renders asynchronously detected web URLs as native SwiftUI links.
///
/// The processed value remains associated with its exact source so view reuse
/// cannot briefly display link ranges calculated for an older entry body.
private struct LinkDetectionText: View {

  let attributedText: AttributedString

  @State private var detectionResult: DetectionResult?

  var body: some View {
    Text(displayedText)
      .task(id: attributedText) {
        let processedText = await TextLinkDetector.process(attributedText)
        guard Task.isCancelled == false else { return }

        detectionResult = DetectionResult(
          source: attributedText,
          processedText: processedText
        )
      }
  }

  private var displayedText: AttributedString {
    guard let detectionResult,
      detectionResult.source == attributedText
    else {
      return attributedText
    }

    return detectionResult.processedText
  }

  /// A processed value paired with the source whose ranges it describes.
  private struct DetectionResult {
    let source: AttributedString
    let processedText: AttributedString
  }
}

// MARK: - Link Detection

/// Adds native link attributes to HTTP(S) ranges without changing authored text.
///
/// Email addresses and custom schemes are deliberately excluded because Text
/// entries should only hand ordinary web URLs to the system URL action.
enum TextLinkDetector {

  @concurrent
  nonisolated static func process(
    _ attributedText: AttributedString
  ) async -> AttributedString {
    guard Task.isCancelled == false,
      let detector = try? NSDataDetector(
        types: NSTextCheckingResult.CheckingType.link.rawValue
      )
    else {
      return attributedText
    }

    let text = String(attributedText.characters)
    var processedText = attributedText

    for match in detector.matches(
      in: text,
      options: [],
      range: NSRange(text.startIndex..<text.endIndex, in: text)
    ) {
      guard Task.isCancelled == false else { return attributedText }
      guard
        let detectedURL = match.url,
        let scheme = detectedURL.scheme?.lowercased(),
        scheme == "http" || scheme == "https",
        let textRange = Range(match.range, in: text),
        let attributedRange = Range(match.range, in: attributedText),
        let linkURL = JournalLinkURL(String(text[textRange]))
      else {
        continue
      }

      processedText[attributedRange].link = linkURL.url
      processedText[attributedRange].underlineStyle = .single
    }

    return processedText
  }
}

#Preview("Text Content") {
  EntryContentPreviewCanvas {
    TextContentView(
      text:
        "A single-column journal leaves room for each entry to keep its own rhythm.",
      style: .init(.cell)
    )
  }
}

#Preview {
  Rectangle()
    .foregroundStyle(.background.secondary)
    .backgroundStyle(.white)
}
