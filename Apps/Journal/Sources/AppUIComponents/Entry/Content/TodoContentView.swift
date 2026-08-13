import MuColor
import SwiftUI

/// Authored values needed to render one Todo without exposing persistence rows.
public struct TodoContentSource: Equatable, Hashable, Sendable {

  /// The actionable text written by the user.
  public let text: String

  /// When the Todo was completed, or `nil` while it remains open.
  public let completedAt: Date?

  public init(text: String, completedAt: Date? = nil) {
    self.text = text
    self.completedAt = completedAt
  }

  /// Completion derived from the timestamp that is synced with the card.
  public var isCompleted: Bool {
    completedAt != nil
  }
}

/// Content-owned rendering for a Todo entry.
struct TodoContentView: View {

  /// Visual treatment for a Todo in one authored-content placement.
  struct Style {
    let preset: EntryContentStyle

    init(_ preset: EntryContentStyle) {
      self.preset = preset
    }

    var font: Font {
      switch preset {
      case .composer, .overview, .detail:
        return .headline.weight(.semibold)
      case .share:
        return .system(size: 64, weight: .bold)
      }
    }

    var indicatorSize: CGFloat {
      preset == .share ? 52 : 24
    }

    var statusSlotSize: CGFloat {
      preset == .share ? 72 : 44
    }

    var spacing: CGFloat {
      preset == .share ? 28 : 8
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

    var lineSpacing: CGFloat {
      preset == .share ? 8 : 0
    }

    var minimumScaleFactor: CGFloat {
      preset == .share ? 0.62 : 1
    }

    var fillsAvailableSpace: Bool {
      preset == .share
    }

    var minimumHeight: CGFloat? { nil }
  }

  let source: TodoContentSource
  let style: Style
  let showsCompletionIndicator: Bool
  let onToggleCompletion: (@MainActor () -> Void)?

  var body: some View {
    HStack(alignment: .center, spacing: style.spacing) {
      if showsCompletionIndicator {
        TodoStatusControl(
          isCompleted: source.isCompleted,
          imageSize: style.indicatorSize,
          frameSize: style.statusSlotSize,
          onToggleCompletion: onToggleCompletion
        )
      }

      Text(displayText)
        .font(style.font)
        .lineLimit(style.lineLimit)
        .lineSpacing(style.lineSpacing)
        .minimumScaleFactor(style.minimumScaleFactor)
        .strikethrough(source.isCompleted)
        .opacity(source.isCompleted ? 0.58 : 1)
        .frame(
          maxWidth: style.fillsAvailableSpace ? .infinity : nil,
          maxHeight: style.fillsAvailableSpace ? .infinity : nil,
          alignment: .leading
        )
    }
    .padding(16)
    .frame(
      maxWidth: .infinity,
      maxHeight: style.fillsAvailableSpace ? .infinity : nil,
      alignment: .leading
    )
    .background(.appSecondaryContainer)
  }

  private var displayText: String {
    guard source.text.isEmpty else { return source.text }
    switch style.preset {
    case .share:
      return String(localized: "Untitled Todo", bundle: #bundle)
    case .composer, .overview, .detail:
      return String(localized: "Todo", bundle: #bundle)
    }
  }
}

/// Completion affordance shared by Todo content and navigation-row overlays.
public struct TodoCompletionButton: View {

  private let isCompleted: Bool
  private let imageSize: CGFloat
  private let frameSize: CGFloat
  private let onToggle: @MainActor () -> Void

  public init(
    isCompleted: Bool,
    imageSize: CGFloat = 24,
    frameSize: CGFloat = 44,
    onToggle: @escaping @MainActor () -> Void
  ) {
    self.isCompleted = isCompleted
    self.imageSize = imageSize
    self.frameSize = frameSize
    self.onToggle = onToggle
  }

  public var body: some View {
    Button(action: onToggle) {
      TodoStatusIndicator(
        isCompleted: isCompleted,
        imageSize: imageSize,
        frameSize: frameSize
      )
    }
    .buttonStyle(.plain)
    .accessibilityLabel(
      isCompleted
        ? Text(
          "Reopen Todo",
          bundle: #bundle,
          comment: "Button that changes a completed Todo back to incomplete."
        )
        : Text(
          "Mark Todo Complete",
          bundle: #bundle,
          comment: "Button that marks an incomplete Todo as completed."
        )
    )
    .accessibilityValue(
      isCompleted
        ? Text("Completed", bundle: #bundle)
        : Text("Incomplete", bundle: #bundle)
    )
  }
}

private struct TodoStatusControl: View {

  let isCompleted: Bool
  let imageSize: CGFloat
  let frameSize: CGFloat
  let onToggleCompletion: (@MainActor () -> Void)?

  var body: some View {
    if let onToggleCompletion {
      TodoCompletionButton(
        isCompleted: isCompleted,
        imageSize: imageSize,
        frameSize: frameSize,
        onToggle: onToggleCompletion
      )
    } else {
      TodoStatusIndicator(
        isCompleted: isCompleted,
        imageSize: imageSize,
        frameSize: frameSize
      )
      .accessibilityHidden(true)
    }
  }
}

private struct TodoStatusIndicator: View {

  let isCompleted: Bool
  let imageSize: CGFloat
  let frameSize: CGFloat

  var body: some View {
    Image(systemName: isCompleted ? "checkmark.circle.fill" : "circle")
      .font(.system(size: imageSize, weight: .semibold))
      .foregroundStyle(isCompleted ? Color.accentColor : Color.secondary)
      .frame(width: frameSize, height: frameSize)
      .contentShape(Circle())
  }
}

#Preview("Todo Content") {
  EntryContentPreviewCanvas {
    VStack(spacing: 20) {
      TodoContentView(
        source: TodoContentSource(text: "Pick up flowers before dinner"),
        style: .init(.detail),
        showsCompletionIndicator: true,
        onToggleCompletion: nil
      )

      TodoContentView(
        source: TodoContentSource(text: "Book the train", completedAt: .now),
        style: .init(.detail),
        showsCompletionIndicator: true,
        onToggleCompletion: {}
      )
    }
  }
}
