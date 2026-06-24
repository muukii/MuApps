import SwiftUI

#if canImport(JournalingSuggestions)
@_weakLinked import JournalingSuggestions
#endif

// MARK: - Capture View

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
    #if canImport(JournalingSuggestions)
    // `JournalingSuggestions` is weak-linked and absent from the Mac (Designed for
    // iPad) runtime. Guard on `isiOSAppOnMac` so its symbols are never touched
    // there, and erase the picker through `AnyView` so the composed view type
    // doesn't force the picker's (missing) type metadata to instantiate on Mac.
    if ProcessInfo.processInfo.isiOSAppOnMac {
      UnavailablePlaceholder(text: "Available on iPhone & iPad only")
    } else {
      AnyView(picker)
    }
    #else
    UnavailablePlaceholder(text: "Available on device only")
    #endif
  }

  #if canImport(JournalingSuggestions)
  private var picker: some View {
    JournalingSuggestionsPicker(
      label: {
        Label(label, systemImage: "sparkles")
          .font(.headline)
          .padding(.vertical, 4)
      },
      onCompletion: { suggestion in
        let captured = await CapturedSuggestion.resolve(from: suggestion)
        onCommit(captured)
      }
    )
    .buttonStyle(.borderedProminent)
    .buttonBorderShape(.capsule)
  }
  #endif
}

// MARK: - Fileprivate Views

/// Shown wherever the picker can't run: the Simulator (no module) or the Mac
/// Designed-for-iPad runtime (module absent).
private struct UnavailablePlaceholder: View {
  let text: String

  var body: some View {
    Label(text, systemImage: "iphone.gen3.slash")
      .font(.subheadline)
      .foregroundStyle(.secondary)
      .padding()
      .frame(maxWidth: .infinity)
      .background(.quaternary.opacity(0.5), in: Capsule())
  }
}

#Preview {
  SuggestionCaptureView { captured in
    print("captured:", captured.title, captured.elements.count)
  }
}
