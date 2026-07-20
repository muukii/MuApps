import SwiftUI

extension View {
  /// Uses iOS's inline navigation title while preserving the native macOS
  /// toolbar/title presentation, where this UIKit-specific mode is unavailable.
  @ViewBuilder
  func appInlineNavigationTitle() -> some View {
    #if os(iOS)
    navigationBarTitleDisplayMode(.inline)
    #else
    self
    #endif
  }

  /// Uses a full-screen modal on iOS and a native resizable sheet on macOS.
  func appFullScreenCover<Content: View>(
    isPresented: Binding<Bool>,
    @ViewBuilder content: @escaping () -> Content
  ) -> some View {
    #if os(iOS)
    fullScreenCover(isPresented: isPresented, content: content)
    #else
    sheet(isPresented: isPresented, content: content)
    #endif
  }

  /// Identifiable-item variant of the app's platform-adaptive modal.
  func appFullScreenCover<Item: Identifiable, Content: View>(
    item: Binding<Item?>,
    @ViewBuilder content: @escaping (Item) -> Content
  ) -> some View {
    #if os(iOS)
    fullScreenCover(item: item, content: content)
    #else
    sheet(item: item, content: content)
    #endif
  }

  /// Keeps iOS's zoom navigation transition and uses native macOS navigation.
  func appZoomNavigationTransition<ID: Hashable>(
    sourceID: ID,
    in namespace: Namespace.ID
  ) -> some View {
    #if os(iOS)
    navigationTransition(.zoom(sourceID: sourceID, in: namespace))
    #else
    self
    #endif
  }

  /// Marks the iOS zoom source without imposing a UIKit transition on macOS.
  func appMatchedTransitionSource<ID: Hashable>(
    id: ID,
    in namespace: Namespace.ID
  ) -> some View {
    #if os(iOS)
    matchedTransitionSource(id: id, in: namespace)
    #else
    self
    #endif
  }

  /// Uses the closest native grouped list treatment on each platform.
  func appInsetGroupedListStyle() -> some View {
    #if os(iOS)
    listStyle(.insetGrouped)
    #else
    listStyle(.inset)
    #endif
  }

  /// Applies the platform-native presentation contract for the Vault picker.
  ///
  /// iPhone and iPad use interactive sheet detents. On macOS, SwiftUI's
  /// automatic presentation sizing fits vertically to the content, which can
  /// collapse a `List`, so the picker instead uses a bounded form-sized sheet.
  func appVaultSelectionPresentation(
    selection: Binding<PresentationDetent>
  ) -> some View {
    #if os(iOS)
      presentationDetents(
        [.medium, .large],
        selection: selection
      )
      .presentationDragIndicator(.visible)
      .presentationBackground(.background)
    #else
      presentationSizing(.form)
        .frame(
          minWidth: 480,
          idealWidth: 560,
          maxWidth: 640,
          minHeight: 360,
          idealHeight: 440,
          maxHeight: 600
        )
        .presentationBackground(.background)
    #endif
  }
}

extension ToolbarItemPlacement {
  /// Trailing navigation action on iOS and the primary window action on macOS.
  static var appTrailingAction: ToolbarItemPlacement {
    #if os(iOS)
    .topBarTrailing
    #else
    .primaryAction
    #endif
  }

  /// Leading navigation action on iOS and cancellation position on macOS.
  static var appLeadingAction: ToolbarItemPlacement {
    #if os(iOS)
    .navigationBarLeading
    #else
    .cancellationAction
    #endif
  }
}
