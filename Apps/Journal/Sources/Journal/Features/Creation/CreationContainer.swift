import MuColor
import SwiftUI

/// Presentation container for the Journal creation surface.
///
/// The container owns the bottom input bar and its standard SwiftUI `Menu`.
/// The caller continues to own draft mutation, capture presentation, and saving.
struct CreationContainer<Content: View, MenuContent: View>: View {

  private let canSave: Bool
  private let isSaving: Bool
  private let onComposeText: @MainActor @Sendable () -> Void
  private let onSave: @MainActor @Sendable () -> Void
  private let content: Content
  private let menuContent: MenuContent

  init(
    canSave: Bool,
    isSaving: Bool,
    onComposeText: @escaping @MainActor @Sendable () -> Void,
    onSave: @escaping @MainActor @Sendable () -> Void,
    @ViewBuilder content: () -> Content,
    @ViewBuilder menuContent: () -> MenuContent
  ) {
    self.canSave = canSave
    self.isSaving = isSaving
    self.onComposeText = onComposeText
    self.onSave = onSave
    self.content = content()
    self.menuContent = menuContent()
  }

  var body: some View {
    content
      .safeAreaInset(edge: .bottom) {
        CreationComposerInputBar(
          canSave: canSave,
          isSaving: isSaving,
          onComposeText: onComposeText,
          onSave: onSave
        ) {
          menuContent
        }
        .frame(maxWidth: CreationContainerMetrics.maximumComposerWidth)
        .frame(maxWidth: .infinity)
        .padding(.horizontal, CreationContainerMetrics.horizontalPadding)
        .padding(.bottom, 8)
      }
      .ignoresSafeArea(.keyboard)
  }
}

/// Visual constants for the creation composer bar.
private enum CreationContainerMetrics {

  /// Horizontal screen inset for the bottom composer.
  static let horizontalPadding: CGFloat = 22

  /// Keeps the pointer-driven Mac input surface within a readable line length.
  static let maximumComposerWidth: CGFloat = {
    #if os(macOS)
    720
    #else
    .infinity
    #endif
  }()
}

/// Bottom composer bar that keeps text entry and save close to the add affordance.
private struct CreationComposerInputBar<MenuContent: View>: View {

  let canSave: Bool
  let isSaving: Bool
  let onComposeText: @MainActor @Sendable () -> Void
  let onSave: @MainActor @Sendable () -> Void
  let menuContent: MenuContent

  init(
    canSave: Bool,
    isSaving: Bool,
    onComposeText: @escaping @MainActor @Sendable () -> Void,
    onSave: @escaping @MainActor @Sendable () -> Void,
    @ViewBuilder menuContent: () -> MenuContent
  ) {
    self.canSave = canSave
    self.isSaving = isSaving
    self.onComposeText = onComposeText
    self.onSave = onSave
    self.menuContent = menuContent()
  }

  var body: some View {
    HStack(spacing: 10) {
      Menu {
        menuContent
      } label: {
        Image(systemName: "plus")
          .font(.system(size: 24, weight: .regular))
          .frame(width: 38, height: 42)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .disabled(isSaving)
      .accessibilityLabel("Add Card")

      Button(action: onComposeText) {
        Text("Write a card")
          .font(.body)
          .foregroundStyle(.secondary)
          .frame(maxWidth: .infinity, minHeight: 42, alignment: .leading)
          .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .disabled(isSaving)
      .accessibilityLabel("Write Text Card")
      .keyboardShortcut("n", modifiers: [.command, .shift])

      Button(action: onSave) {
        Image(systemName: isSaving ? "hourglass" : "arrow.up")
          .font(.system(size: 20, weight: .semibold))
          .foregroundStyle(.appOnTint)
          .frame(width: 44, height: 44)
          .background(saveButtonBackground, in: Circle())
      }
      .buttonStyle(.plain)
      .disabled(canSave == false || isSaving)
      .accessibilityLabel("Post Thread")
      .keyboardShortcut(.return, modifiers: .command)
    }
    .padding(.leading, 6)
    .padding(.trailing, 6)
    .frame(minHeight: 58)
    .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 29, style: .continuous))
  }

  private var saveButtonBackground: Color {
    if canSave, isSaving == false {
      return .accentColor
    }

    return .secondary.opacity(0.26)
  }
}
