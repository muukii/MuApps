//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//

import SwiftUI

extension View {

  /// Declares a blocking overlay that an ancestor
  /// `appBlockingOverlayTarget()` presents outside local clipping boundaries.
  ///
  /// The caller owns the complete visual content, including any scrim, progress
  /// presentation, message, and cancellation controls. Type erasure remains an
  /// implementation detail of the preference bridge.
  func appBlockingOverlay<Overlay: View>(
    isPresented: Bool,
    @ViewBuilder overlay: () -> Overlay
  ) -> some View {
    modifier(
      AppBlockingOverlaySourceModifier(
        isPresented: isPresented,
        overlay: overlay()
      )
    )
  }

  /// Establishes the unclipped presentation boundary for descendant blocking
  /// overlays.
  ///
  /// Place one target above navigation or other containers whose content may
  /// clip a locally attached overlay.
  func appBlockingOverlayTarget() -> some View {
    modifier(AppBlockingOverlayTargetModifier())
  }
}

/// A type-erased presentation transported through SwiftUI preferences.
private struct AppBlockingOverlayPresentation {

  let content: AnyView

  init<Content: View>(content: Content) {
    self.content = AnyView(content)
  }
}

/// Carries one active presentation from a descendant to its nearest target.
private struct AppBlockingOverlayPreferenceKey: PreferenceKey {

  static let defaultValue: AppBlockingOverlayPresentation? = nil

  static func reduce(
    value: inout AppBlockingOverlayPresentation?,
    nextValue: () -> AppBlockingOverlayPresentation?
  ) {
    guard let nextValue = nextValue() else { return }
    if value == nil {
      value = nextValue
    } else {
      assertionFailure(
        "Only one app blocking overlay may be active within a target."
      )
    }
  }
}

/// Aggregates active state separately so the target can hide background
/// accessibility without making the type-erased presentation equatable.
private struct AppBlockingOverlayActivityPreferenceKey: PreferenceKey {

  static let defaultValue = false

  static func reduce(value: inout Bool, nextValue: () -> Bool) {
    value = value || nextValue()
  }
}

/// Writes an optional arbitrary overlay into the preference hierarchy without
/// changing the source view's structural identity.
private struct AppBlockingOverlaySourceModifier<Overlay: View>: ViewModifier {

  let isPresented: Bool
  let overlay: Overlay

  func body(content: Content) -> some View {
    content
      .preference(
        key: AppBlockingOverlayPreferenceKey.self,
        value:
          isPresented
          ? AppBlockingOverlayPresentation(content: overlay)
          : nil
      )
      .preference(
        key: AppBlockingOverlayActivityPreferenceKey.self,
        value: isPresented
      )
  }
}

/// Renders the selected descendant overlay above the target's complete bounds.
private struct AppBlockingOverlayTargetModifier: ViewModifier {

  @State private var isOverlayPresented = false

  func body(content: Content) -> some View {
    content
      .accessibilityHidden(isOverlayPresented)
      .onPreferenceChange(
        AppBlockingOverlayActivityPreferenceKey.self
      ) { isPresented in
        isOverlayPresented = isPresented
      }
      .overlayPreferenceValue(
        AppBlockingOverlayPreferenceKey.self
      ) { presentation in
        AppBlockingOverlayHost(presentation: presentation)
      }
  }
}

/// Supplies the interaction-blocking surface beneath caller-provided content.
private struct AppBlockingOverlayHost: View {

  let presentation: AppBlockingOverlayPresentation?

  var body: some View {
    ZStack {
      if let presentation {
        ZStack {
          Color.clear
            .contentShape(Rectangle())
            .allowsHitTesting(true)
            .accessibilityHidden(true)

          presentation.content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .ignoresSafeArea()
        .transition(.opacity)
      }
    }
    .animation(.snappy, value: presentation != nil)
  }
}

#Preview("App Blocking Overlay") {
  @Previewable @State var isPresented = true

  NavigationStack {
    Button("Show Processing") {
      isPresented = true
    }
    .appBlockingOverlay(isPresented: isPresented) {
      VStack(spacing: 12) {
        ProgressView()
        Button("Cancel") {
          isPresented = false
        }
      }    
      .padding(24)
      .glassEffect(in: .rect(cornerRadius: 32))
    }
    .navigationTitle("Clipped Content")
  }
  .appBlockingOverlayTarget()
}
