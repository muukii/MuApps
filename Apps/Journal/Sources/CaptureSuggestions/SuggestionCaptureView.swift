import SwiftUI

#if canImport(JournalingSuggestions)
@_weakLinked import JournalingSuggestions
#endif

// MARK: - Capture View

/// A customizable button entry point to Apple's Journaling Suggestions picker.
///
/// The system framework owns the actual picker presentation. This wrapper only
/// lets the host app supply a label that visually fits its capture surface while
/// keeping the same value-type `CapturedSuggestion` handoff as
/// `SuggestionCaptureView`.
public struct SuggestionCaptureButton<Label: View>: View {

  private let label: @MainActor @Sendable () -> Label
  private let onCommit: @MainActor @Sendable (CapturedSuggestion) -> Void

  public init(
    @ViewBuilder label: @escaping @MainActor @Sendable () -> Label,
    onCommit: @escaping @MainActor @Sendable (CapturedSuggestion) -> Void
  ) {
    self.label = label
    self.onCommit = onCommit
  }

  public var body: some View {
    #if canImport(JournalingSuggestions)
    // `JournalingSuggestions` is weak-linked for the Designed-for-iPad runtime.
    // Guard on `isiOSAppOnMac` so its symbols are never touched by an iPad app
    // running directly on Apple silicon. Native macOS compiles the unavailable
    // fallback below because this framework is absent from the macOS SDK.
    if ProcessInfo.processInfo.isiOSAppOnMac {
      UnavailableSuggestionButton(label: label)
    } else {
      AnyView(picker)
    }
    #else
    UnavailableSuggestionButton(label: label)
    #endif
  }

  #if canImport(JournalingSuggestions)
  private var picker: some View {
    JournalingSuggestionsPicker(
      label: label,
      onCompletion: { suggestion in
        let captured = await CapturedSuggestion.resolve(from: suggestion)
        onCommit(captured)
      }
    )
  }
  #endif
}

/// A self-contained entry point to Apple's Journaling Suggestions.
///
/// `JournalingSuggestionsPicker` renders a system-owned button that presents the
/// suggestion sheet; the app never sees the underlying signals (photos, workouts,
/// places, music…), only the single suggestion the user explicitly hands back. We
/// resolve that suggestion into a value-type `CapturedSuggestion` and emit it
/// through `onCommit`. This view owns no persistence and knows nothing about
/// `Card`.
///
/// Runtime requirements (the picker is otherwise inert):
/// - The `com.apple.developer.journal.allow` entitlement on the host app.
/// - A physical iPhone/iPad. `JournalingSuggestions` ships only in the device SDK,
///   so the Simulator falls back to a placeholder at compile time, and the Mac
///   (Designed for iPad) runtime — which lacks the framework entirely — falls back
///   at runtime (see `body`).
/// - Journaling Suggestions enabled in Settings › Privacy & Security, in a
///   supported region.
public struct SuggestionCaptureView: View {

  private let label: String
  private let onCommit: @MainActor @Sendable (CapturedSuggestion) -> Void

  public init(
    label: String = "Choose a Suggestion",
    onCommit: @escaping @MainActor @Sendable (CapturedSuggestion) -> Void
  ) {
    self.label = label
    self.onCommit = onCommit
  }

  public var body: some View {
    SuggestionCaptureButton {
      Label(label, systemImage: "sparkles")
        .font(.headline)
        .padding(.vertical, 4)
    } onCommit: { suggestion in
      onCommit(suggestion)
    }
    .buttonStyle(.borderedProminent)
    .buttonBorderShape(.capsule)
  }
}

// MARK: - Programmatic Presentation

/// Bridges an external presentation binding to Apple's system-owned Journaling
/// Suggestions picker.
///
/// Action Button and App Shortcut navigation cannot synthesize a tap on
/// `JournalingSuggestionsPicker`, so app-level capture routing applies this
/// modifier to an existing surface and toggles the binding instead. The output
/// remains the same persistence-agnostic `CapturedSuggestion` value used by the
/// button entry point.
public extension View {

  func journalSuggestionCapturePresenter(
    isPresented: Binding<Bool>,
    onCommit: @escaping @MainActor @Sendable (CapturedSuggestion) -> Void
  ) -> some View {
    modifier(
      JournalSuggestionCapturePresenterModifier(
        isPresented: isPresented,
        onCommit: onCommit
      )
    )
  }
}

private struct JournalSuggestionCapturePresenterModifier: ViewModifier {

  @Binding var isPresented: Bool
  let onCommit: @MainActor @Sendable (CapturedSuggestion) -> Void

  func body(content: Content) -> some View {
    #if canImport(JournalingSuggestions)
    // Keep the weak-linked modifier entirely behind the same runtime guard used
    // by the button wrapper. The framework is absent when an iPad build runs on
    // Apple silicon Mac hardware.
    if ProcessInfo.processInfo.isiOSAppOnMac {
      AnyView(unavailableContent(content))
    } else {
      AnyView(
        content.journalingSuggestionsPicker(
          isPresented: $isPresented,
          onCompletion: { suggestion in
            let captured = await CapturedSuggestion.resolve(from: suggestion)
            onCommit(captured)
          }
        )
      )
    }
    #else
    unavailableContent(content)
    #endif
  }

  private func unavailableContent(_ content: Content) -> some View {
    content.onChange(of: isPresented) { _, shouldPresent in
      guard shouldPresent else { return }
      isPresented = false
    }
  }
}

// MARK: - Fileprivate Views

/// Disabled placeholder shown wherever the picker can't run: the Simulator (no
/// module) or the Mac Designed-for-iPad runtime (module absent). Native macOS
/// compiles this fallback because the module cannot be imported there.
private struct UnavailableSuggestionButton<Label: View>: View {
  let label: @MainActor @Sendable () -> Label

  var body: some View {
    Button(action: {}) {
      label()
    }
    .disabled(true)
  }
}

#Preview {
  SuggestionCaptureView { captured in
    print("captured:", captured.title, captured.elements.count)
  }
}
