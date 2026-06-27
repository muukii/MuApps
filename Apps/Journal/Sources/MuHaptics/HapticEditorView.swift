import SwiftUI
import UIKit

/// A simple on-device editor for building and playing arbitrary haptic patterns.
///
/// Binding layer: owns the one hard-to-construct dependency (`HapticEngine`) and
/// the pattern being edited, then hands the content view only cheap values and
/// callbacks — so `HapticEditorContent` stays previewable with literals.
public struct HapticEditorView: View {

  @State private var pattern: HapticPattern
  @State private var engine = HapticEngine()
  @State private var errorMessage: String?

  public init(pattern: HapticPattern = .singleTap) {
    self._pattern = State(initialValue: pattern)
  }

  public var body: some View {
    HapticEditorContent(
      pattern: $pattern,
      isSupported: HapticEngine.isSupported,
      errorMessage: errorMessage,
      onPlay: { play() }
    )
  }

  private func play() {
    do {
      try engine.play(pattern)
      errorMessage = nil
    } catch {
      errorMessage = String(describing: error)
    }
  }
}

// MARK: - Content

/// Stateless editor body: every input is a cheap value or a `@Binding`, so this
/// view is fully exercisable in previews without a real haptic engine.
fileprivate struct HapticEditorContent: View {

  @Binding var pattern: HapticPattern
  let isSupported: Bool
  let errorMessage: String?
  let onPlay: @MainActor @Sendable () -> Void

  var body: some View {
    List {
      Section {
        HapticTrackView(events: pattern.events)
          .frame(height: 80)
          .listRowInsets(EdgeInsets())
          .listRowBackground(Color.clear)
      }

      Section("Pattern") {
        TextField("Name", text: $pattern.name)
        Button {
          onPlay()
        } label: {
          Label("Play", systemImage: "play.fill")
        }
        .disabled(!isSupported || pattern.events.isEmpty)

        if !isSupported {
          Label("Haptics unavailable on this device", systemImage: "exclamationmark.triangle")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        if let errorMessage {
          Text(errorMessage)
            .font(.caption)
            .foregroundStyle(.red)
        }
      }

      ForEach($pattern.events) { $event in
        Section {
          EventEditor(event: $event)
        } header: {
          HStack {
            Text(event.kind.title)
            Spacer()
            Button(role: .destructive) {
              pattern.events.removeAll { $0.id == event.id }
            } label: {
              Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
          }
        }
      }

      Section {
        Button {
          appendEvent(kind: .transient)
        } label: {
          Label("Add Tap", systemImage: "plus.circle")
        }
        Button {
          appendEvent(kind: .continuous)
        } label: {
          Label("Add Continuous", systemImage: "plus.circle")
        }
      }

      Section("Presets") {
        ForEach(HapticPattern.presets) { preset in
          Button(preset.name) {
            pattern = preset
          }
        }
      }

      Section {
        let code = pattern.swiftSourceCode
        Text(code)
          .font(.system(.caption, design: .monospaced))
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)

        Button {
          UIPasteboard.general.string = code
        } label: {
          Label("Copy Swift Code", systemImage: "doc.on.doc")
        }

        ShareLink(item: code) {
          Label("Share", systemImage: "square.and.arrow.up")
        }
      } header: {
        Text("Export")
      } footer: {
        Text("Paste this into your app to recreate the pattern, then play it with HapticEngine.")
      }
    }
    .navigationTitle("Haptics")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Button {
          onPlay()
        } label: {
          Image(systemName: "play.fill")
        }
        .disabled(!isSupported || pattern.events.isEmpty)
      }
    }
  }

  /// New events start just after the current timeline so they don't overlap.
  private func appendEvent(kind: HapticPattern.Event.Kind) {
    pattern.events.append(
      .init(kind: kind, time: pattern.duration)
    )
  }
}

// MARK: - Event editor

fileprivate struct EventEditor: View {

  @Binding var event: HapticPattern.Event

  var body: some View {
    Picker("Type", selection: $event.kind) {
      ForEach(HapticPattern.Event.Kind.allCases, id: \.self) { kind in
        Text(kind.title).tag(kind)
      }
    }
    .pickerStyle(.segmented)

    LabeledSlider(label: "Time", value: $event.time, range: 0...3, unit: "s")

    switch event.kind {
    case .transient:
      EmptyView()
    case .continuous:
      LabeledSlider(label: "Duration", value: $event.duration, range: 0.05...3, unit: "s")
    }

    LabeledSlider(label: "Intensity", value: $event.intensity, range: 0...1)
    LabeledSlider(label: "Sharpness", value: $event.sharpness, range: 0...1)
  }
}

/// A slider with a leading label and a trailing value readout. `Double`/`Float`
/// agnostic via `BinaryFloatingPoint` so it drives both the time fields and the
/// 0–1 parameter fields without duplication.
fileprivate struct LabeledSlider<Value: BinaryFloatingPoint>: View where Value.Stride: BinaryFloatingPoint {

  let label: String
  @Binding var value: Value
  let range: ClosedRange<Value>
  var unit: String = ""

  var body: some View {
    VStack(alignment: .leading, spacing: 2) {
      HStack {
        Text(label)
        Spacer()
        Text(formatted)
          .foregroundStyle(.secondary)
          .monospacedDigit()
      }
      .font(.caption)
      Slider(value: $value, in: range)
        // Keep the thumb away from the screen edges so dragging near the start
        // of the track doesn't fight the navigation pop (back-swipe) gesture.
        .padding(.horizontal, 16)
    }
  }

  private var formatted: String {
    String(format: "%.2f%@", Double(value), unit)
  }
}

// MARK: - Timeline track

/// A lightweight timeline preview: each event is a bar positioned by start time,
/// its height encoding intensity. Continuous events stretch by duration; taps
/// render as a thin marker. Read-only — purely a visual aid for the editor.
fileprivate struct HapticTrackView: View {

  let events: [HapticPattern.Event]

  var body: some View {
    GeometryReader { geometry in
      let span = max(totalDuration, 0.01)
      ZStack(alignment: .leading) {
        RoundedRectangle(cornerRadius: 8)
          .fill(.quaternary)

        ForEach(events) { event in
          bar(for: event, in: geometry.size, span: span)
        }
      }
    }
    .padding(.horizontal)
    .padding(.vertical, 12)
  }

  private var totalDuration: TimeInterval {
    events.map(\.endTime).max() ?? 0
  }

  private func bar(for event: HapticPattern.Event, in size: CGSize, span: TimeInterval) -> some View {
    let width: CGFloat = {
      switch event.kind {
      case .transient: return 3
      case .continuous: return max(3, size.width * event.duration / span)
      }
    }()
    let height = max(6, size.height * CGFloat(event.intensity))
    let x = size.width * event.time / span

    return RoundedRectangle(cornerRadius: 2)
      .fill(.tint)
      .frame(width: width, height: height)
      .offset(x: x, y: (size.height - height) / 2)
  }
}

// MARK: - Kind presentation

extension HapticPattern.Event.Kind {
  fileprivate var title: String {
    switch self {
    case .transient: "Tap"
    case .continuous: "Continuous"
    }
  }
}

// MARK: - Previews

#Preview("Editor") {
  NavigationStack {
    HapticEditorView(pattern: .rampUp)
  }
}

#Preview("Content") {
  @Previewable @State var pattern: HapticPattern = .heartbeat
  NavigationStack {
    HapticEditorContent(
      pattern: $pattern,
      isSupported: true,
      errorMessage: nil,
      onPlay: {}
    )
  }
}
