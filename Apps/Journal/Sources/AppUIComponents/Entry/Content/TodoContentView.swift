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

  /// Describes whether the completion affordance is static or actionable.
  enum Interaction {
    /// Displays the completion state without exposing a control.
    case readOnly

    /// Displays a control that sends the toggle intent to its owner.
    ///
    /// - Parameters:
    ///   - isEnabled: Whether the placement currently accepts a mutation.
    ///   - onToggle: Sends the requested state change to the owning feature.
    case interactive(
      isEnabled: Bool = true,
      onToggle: @MainActor () -> Void
    )
  }

  /// Visual treatment for a Todo in one authored-content placement.
  struct Style {
    let preset: EntryContentStyle

    init(_ preset: EntryContentStyle) {
      self.preset = preset
    }

    var font: Font {
      .headline.weight(.semibold)
    }

    var indicatorSize: CGFloat { 24 }

    var statusSlotSize: CGFloat { 44 }

    var spacing: CGFloat { 6 }

    var lineLimit: Int? {
      switch preset {
      case .composer:
        return 8
      case .cell:
        return nil
      }
    }

    var lineSpacing: CGFloat { 0 }

    var minimumScaleFactor: CGFloat { 1 }

    var minimumHeight: CGFloat? { nil }
  }

  let source: TodoContentSource
  let style: Style
  let interaction: Interaction

  var body: some View {
    HStack(alignment: .center, spacing: style.spacing) {
      TodoStatusControl(
        isCompleted: source.isCompleted,
        imageSize: style.indicatorSize,
        frameSize: style.statusSlotSize,
        interaction: interaction
      )

      Text(displayText)
        .font(style.font)
        .lineLimit(style.lineLimit)
        .lineSpacing(style.lineSpacing)
        .minimumScaleFactor(style.minimumScaleFactor)
        .strikethrough(source.isCompleted)
        .opacity(source.isCompleted ? 0.58 : 1)
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 6)
    .frame(maxWidth: .infinity, alignment: .leading)
    .background(.appSecondaryContainer)
  }

  private var displayText: String {
    guard source.text.isEmpty else { return source.text }
    return String(localized: "Todo", bundle: #bundle)
  }
}

/// Actionable completion affordance owned by Todo content.
private struct TodoCompletionButton: View {

  private let isCompleted: Bool
  private let imageSize: CGFloat
  private let frameSize: CGFloat
  private let onToggle: @MainActor () -> Void

  init(
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

  var body: some View {
    Button(action: onToggle) {
      TodoStatusIndicator(
        isCompleted: isCompleted,
        imageSize: imageSize,
        frameSize: frameSize
      )
    }
    .sensoryFeedback(
      trigger: isCompleted,
      { oldValue, newValue in
        if oldValue == false, newValue == true {
          return .success
        }
        return nil
      }
    )
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
  let interaction: TodoContentView.Interaction

  var body: some View {
    switch interaction {
    case .readOnly:
      TodoStatusIndicator(
        isCompleted: isCompleted,
        imageSize: imageSize,
        frameSize: frameSize
      )
      .accessibilityHidden(true)
    case .interactive(let isEnabled, let onToggle):
      TodoCompletionButton(
        isCompleted: isCompleted,
        imageSize: imageSize,
        frameSize: frameSize,
        onToggle: onToggle
      )
      .disabled(isEnabled == false)
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
        style: .init(.cell),
        interaction: .readOnly
      )

      TodoContentView(
        source: TodoContentSource(text: "Book the train", completedAt: .now),
        style: .init(.cell),
        interaction: .interactive {}
      )
    }
  }
}
