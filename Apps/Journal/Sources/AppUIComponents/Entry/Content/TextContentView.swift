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
      switch preset {
      case .composer, .overview, .detail:
        return .headline.weight(.semibold)
      case .share:
        return .system(size: 64, weight: .bold)
      }
    }

    var lineLimit: Int? {
      switch preset {
      case .composer, .overview:
        return 8
      case .detail:
        return nil
      case .share:
        return 10
      }
    }

    private static func defaultEmptyTitle(
      for preset: EntryContentStyle
    ) -> LocalizedStringResource {
      switch preset {
      case .composer:
        return "Text"
      case .overview, .detail:
        return "Empty text"
      case .share:
        return "Untitled"
      }
    }

    var lineSpacing: CGFloat {
      preset == .share ? 8 : 0
    }

    var minimumScaleFactor: CGFloat {
      preset == .share ? 0.62 : 1
    }

    var usesComposerForeground: Bool {
      preset == .composer
    }

    var fillsAvailableSpace: Bool {
      preset == .share
    }

    var minimumHeight: CGFloat? { nil }
  }

  let text: String
  let style: Style

  var body: some View {
    if text.isEmpty {
      if style.usesComposerForeground {
        Text(style.emptyTitle)
          .font(style.font)
          .lineLimit(style.lineLimit)
          .foregroundStyle(.secondary)
      } else {
        Text(style.emptyTitle)
          .font(style.font)
          .lineLimit(style.lineLimit)
          .lineSpacing(style.lineSpacing)
          .minimumScaleFactor(style.minimumScaleFactor)
          .frame(
            maxWidth: style.fillsAvailableSpace ? .infinity : nil,
            maxHeight: style.fillsAvailableSpace ? .infinity : nil,
            alignment: .topLeading
          )
      }
    } else {
      if style.usesComposerForeground {
        Text(text)
          .font(style.font)
          .lineLimit(style.lineLimit)
          .foregroundStyle(.primary)
      } else {
        Text(text)
          .font(style.font)
          .lineLimit(style.lineLimit)
          .lineSpacing(style.lineSpacing)
          .minimumScaleFactor(style.minimumScaleFactor)
          .frame(
            maxWidth: style.fillsAvailableSpace ? .infinity : nil,
            maxHeight: style.fillsAvailableSpace ? .infinity : nil,
            alignment: .topLeading
          )
      }
    }
  }
}
