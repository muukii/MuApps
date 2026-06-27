import MuColor
import SwiftUI

/// App-wide overlay host for transient Journal notifications.
///
/// Place this once near the app root. It injects `JournalNotificationCenter`
/// into the environment for feature views, then renders the center's current
/// notification over that content without changing the content layout.
struct JournalNotificationHost<Content: View>: View {

  let center: JournalNotificationCenter
  private let content: Content

  init(
    center: JournalNotificationCenter,
    @ViewBuilder content: () -> Content
  ) {
    self.center = center
    self.content = content()
  }

  var body: some View {
    ZStack(alignment: .bottom) {
      content
        .environment(center)

      if let notification = center.current {
        JournalNotificationBar(
          notification: notification,
          onDismiss: {
            center.dismiss(id: notification.id)
          }
        )
        .frame(maxWidth: 420)
        .padding(.horizontal, 16)
        .padding(.bottom, 18)
        .transition(.journalNotificationFadeBlur)
        .zIndex(1)
      }
    }
    .animation(.bouncy(duration: 0.42, extraBounce: 0.12), value: center.current?.id)
  }
}

/// Transition state for the bottom notification capsule.
private struct JournalNotificationFadeBlurScaleModifier: ViewModifier {

  let opacity: Double
  let blurRadius: CGFloat
  let scale: CGFloat

  func body(content: Content) -> some View {
    content
      .opacity(opacity)
      .blur(radius: blurRadius)
      .scaleEffect(scale, anchor: .bottom)
  }
}

private extension AnyTransition {

  static var journalNotificationFadeBlur: AnyTransition {
    .modifier(
      active: JournalNotificationFadeBlurScaleModifier(
        opacity: 0,
        blurRadius: 10,
        scale: 0.94
      ),
      identity: JournalNotificationFadeBlurScaleModifier(
        opacity: 1,
        blurRadius: 0,
        scale: 1
      )
    )
  }
}

/// The compact bar shown by `JournalNotificationHost`.
private struct JournalNotificationBar: View {

  @Environment(\.appPalette) private var palette

  let notification: JournalNotification
  let onDismiss: @MainActor @Sendable () -> Void

  var body: some View {
    HStack(alignment: .center, spacing: 12) {
      Image(systemName: notification.systemImage)
        .font(.headline.weight(.semibold))
        .foregroundStyle(iconStyle)
        .frame(width: 24, height: 24)

      VStack(alignment: .leading, spacing: 3) {
        Text(notification.title)
          .font(.subheadline.weight(.semibold))
          .foregroundStyle(.appOnSecondaryContainer)

        if let message = notification.message {
          Text(message)
            .font(.caption)
            .foregroundStyle(.appOnSecondaryContainer.opacity(0.62))
            .fixedSize(horizontal: false, vertical: true)
        }
      }
      .frame(maxWidth: .infinity, alignment: .leading)

      Button(action: onDismiss) {
        Image(systemName: "xmark")
          .font(.caption.weight(.bold))
          .foregroundStyle(.appOnSecondaryContainer.opacity(0.58))
          .frame(width: 28, height: 28)
          .contentShape(Circle())
      }
      .buttonStyle(.plain)
      .accessibilityLabel("Dismiss notification")
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 12)
    .background(.appSecondaryContainer, in: Capsule(style: .continuous))
    .overlay {
      Capsule(style: .continuous)
        .strokeBorder(palette.outline)
    }
    .shadow(color: palette.onSecondaryContainer.opacity(0.12), radius: 18, y: 8)
    .accessibilityElement(children: .combine)
  }

  private var iconStyle: AnyShapeStyle {
    switch notification.semantics {
    case .info:
      AnyShapeStyle(.appOnSecondaryContainer.opacity(0.72))
    case .success:
      AnyShapeStyle(.tint)
    case .warning:
      AnyShapeStyle(.tint)
    case .failure:
      AnyShapeStyle(.appOnSecondaryContainer)
    }
  }
}

#Preview {
  @Previewable @State var center = JournalNotificationCenter()

  PrimaryContainer(theme: .default) {
    JournalNotificationHost(center: center) {
      Color.clear
        .background(.background)
        .task {
          center.post(.threadSaveFailed)
        }
    }
  }
}
