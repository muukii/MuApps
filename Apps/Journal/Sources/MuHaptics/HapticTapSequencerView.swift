import QuartzCore
import SwiftUI
import UIKit

/// A recorder for creating playable tap-only haptic timelines by hand.
///
/// Binding layer: owns the haptic engine and the live recording clock, while the
/// content view receives plain values and callbacks.
public struct HapticTapSequencerView: View {

  @State private var sequence: HapticTapSequence
  @State private var engine = HapticEngine()
  @State private var isRecording = false
  @State private var recordingStartedAt: TimeInterval?
  @State private var recordingOffset: TimeInterval = 0
  @State private var playbackStartedAt: Date?
  @State private var errorMessage: String?

  public init(sequence: HapticTapSequence = HapticTapSequence(name: "Haptic Doodle")) {
    self._sequence = State(initialValue: sequence)
  }

  public var body: some View {
    HapticTapSequencerContent(
      sequence: $sequence,
      isRecording: isRecording,
      isSupported: HapticEngine.isSupported,
      playbackStartedAt: playbackStartedAt,
      errorMessage: errorMessage,
      onStartRecording: { startRecording() },
      onStopRecording: { stopRecording() },
      onRecordTap: { recordTap() },
      onUndo: { undoLastTap() },
      onClear: { clear() },
      onPlay: { play() },
      onCopySwiftCode: { copySwiftCode() }
    )
  }

  private func startRecording() {
    recordingOffset = sequence.taps.isEmpty ? 0 : sequence.duration + 0.18
    recordingStartedAt = nil
    playbackStartedAt = nil
    errorMessage = nil
    isRecording = true
  }

  private func stopRecording() {
    isRecording = false
    recordingStartedAt = nil
  }

  private func recordTap() {
    guard isRecording else { return }

    let timestamp = CACurrentMediaTime()
    let elapsed: TimeInterval
    if let recordingStartedAt {
      elapsed = timestamp - recordingStartedAt
    } else {
      recordingStartedAt = timestamp
      elapsed = 0
    }

    let tap = sequence.appendTap(at: recordingOffset + elapsed)
    preview(tap)
  }

  private func undoLastTap() {
    sequence.removeLastTap()
    playbackStartedAt = nil
  }

  private func clear() {
    sequence.taps.removeAll()
    recordingOffset = 0
    recordingStartedAt = nil
    playbackStartedAt = nil
    errorMessage = nil
  }

  private func play() {
    do {
      try engine.play(sequence.pattern)
      playbackStartedAt = Date()
      errorMessage = nil
    } catch {
      errorMessage = String(describing: error)
    }
  }

  private func preview(_ tap: HapticTapSequence.Tap) {
    let pattern = HapticPattern(
      name: "Tap Preview",
      events: [
        HapticPattern.Event(
          kind: .transient,
          time: 0,
          intensity: tap.intensity,
          sharpness: tap.sharpness
        ),
      ]
    )
    try? engine.play(pattern)
  }

  private func copySwiftCode() {
    UIPasteboard.general.string = sequence.swiftSourceCode
  }
}

// MARK: - Content

fileprivate struct HapticTapSequencerContent: View {

  @Binding var sequence: HapticTapSequence
  let isRecording: Bool
  let isSupported: Bool
  let playbackStartedAt: Date?
  let errorMessage: String?
  let onStartRecording: @MainActor @Sendable () -> Void
  let onStopRecording: @MainActor @Sendable () -> Void
  let onRecordTap: @MainActor @Sendable () -> Void
  let onUndo: @MainActor @Sendable () -> Void
  let onClear: @MainActor @Sendable () -> Void
  let onPlay: @MainActor @Sendable () -> Void
  let onCopySwiftCode: @MainActor @Sendable () -> Void

  var body: some View {
    List {
      Section {
        HapticTapRecordingPad(
          tapCount: sequence.taps.count,
          duration: sequence.duration,
          isRecording: isRecording,
          onRecordTap: onRecordTap
        )
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
      }

      Section {
        HapticTapSequenceTimeline(
          taps: sequence.taps,
          playbackStartedAt: playbackStartedAt,
          playbackDuration: sequence.duration
        )
        .frame(height: 78)
        .listRowInsets(EdgeInsets())
        .listRowBackground(Color.clear)
      } header: {
        Text("Timeline")
      }

      Section("Sequence") {
        TextField("Name", text: $sequence.name)

        HStack {
          Label("\(sequence.taps.count) taps", systemImage: "hand.tap")
          Spacer()
          Text("\(sequence.duration, format: .number.precision(.fractionLength(2)))s")
            .monospacedDigit()
            .foregroundStyle(.secondary)
        }

        Button {
          isRecording ? onStopRecording() : onStartRecording()
        } label: {
          if isRecording {
            Label("Stop Recording", systemImage: "stop.fill")
          } else {
            Label("Record Taps", systemImage: "record.circle")
          }
        }
        .tint(isRecording ? .red : .accentColor)

        Button {
          onPlay()
        } label: {
          Label("Play Sequence", systemImage: "play.fill")
        }
        .disabled(!isSupported || sequence.isEmpty)

        HStack {
          Button {
            onUndo()
          } label: {
            Label("Undo Tap", systemImage: "arrow.uturn.backward")
          }
          .disabled(sequence.isEmpty)

          Spacer()

          Button(role: .destructive) {
            onClear()
          } label: {
            Label("Clear", systemImage: "trash")
          }
          .disabled(sequence.isEmpty)
        }

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

      Section("Taps") {
        if sequence.taps.isEmpty {
          ContentUnavailableView(
            "No taps yet",
            systemImage: "hand.tap",
            description: Text("Start recording, then tap the surface to create a sequence.")
          )
        } else {
          ForEach(Array(sequence.taps.enumerated()), id: \.element.id) { index, tap in
            HapticTapRow(number: index + 1, tap: tap)
          }
        }
      }

      Section {
        Text(sequence.swiftSourceCode)
          .font(.system(.caption, design: .monospaced))
          .textSelection(.enabled)
          .frame(maxWidth: .infinity, alignment: .leading)

        Button {
          onCopySwiftCode()
        } label: {
          Label("Copy Swift Code", systemImage: "doc.on.doc")
        }
      } header: {
        Text("Export")
      }
    }
    .navigationTitle("Haptic Doodle")
    .navigationBarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Button {
          onPlay()
        } label: {
          Image(systemName: "play.fill")
        }
        .disabled(!isSupported || sequence.isEmpty)
      }
    }
  }
}

// MARK: - Recording pad

fileprivate struct HapticTapRecordingPad: View {

  let tapCount: Int
  let duration: TimeInterval
  let isRecording: Bool
  let onRecordTap: @MainActor @Sendable () -> Void

  var body: some View {
    VStack(spacing: 14) {
      Image(systemName: isRecording ? "hand.tap.fill" : "hand.tap")
        .font(.system(size: 44, weight: .semibold))
        .foregroundStyle(isRecording ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))

      Text(isRecording ? "Tap Here" : "Start recording")
        .font(.title3.weight(.semibold))

      Text("\(tapCount) taps · \(duration, format: .number.precision(.fractionLength(2)))s")
        .font(.caption)
        .monospacedDigit()
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, minHeight: 220)
    .background {
      RoundedRectangle(cornerRadius: 8)
        .fill(isRecording ? AnyShapeStyle(.tint.opacity(0.16)) : AnyShapeStyle(.quaternary))
    }
    .overlay {
      RoundedRectangle(cornerRadius: 8)
        .strokeBorder(
          isRecording ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary.opacity(0.25)),
          lineWidth: 1
        )
    }
    .contentShape(RoundedRectangle(cornerRadius: 8))
    .modifier(HapticTapDownGestureModifier(isEnabled: isRecording, onRecordTap: onRecordTap))
    .accessibilityAddTraits(.isButton)
    .accessibilityLabel(isRecording ? "Record haptic tap" : "Recording stopped")
    .accessibilityAction {
      guard isRecording else { return }
      onRecordTap()
    }
  }
}

/// Records at touch-down instead of Button's touch-up activation point, keeping
/// the tactile response aligned with the user's finger.
fileprivate struct HapticTapDownGestureModifier: ViewModifier {

  let isEnabled: Bool
  let onRecordTap: @MainActor @Sendable () -> Void

  @State private var isTouchActive = false

  @ViewBuilder
  func body(content: Content) -> some View {
    if isEnabled {
      content
        .gesture(
          DragGesture(minimumDistance: 0)
            .onChanged { _ in
              guard isTouchActive == false else { return }
              isTouchActive = true
              onRecordTap()
            }
            .onEnded { _ in
              isTouchActive = false
            }
        )
    } else {
      content
        .onAppear {
          isTouchActive = false
        }
    }
  }
}

// MARK: - Timeline

fileprivate struct HapticTapSequenceTimeline: View {

  let taps: [HapticTapSequence.Tap]
  let playbackStartedAt: Date?
  let playbackDuration: TimeInterval

  var body: some View {
    TimelineView(.animation) { context in
      GeometryReader { geometry in
        let span = max(playbackDuration, taps.map(\.time).max() ?? 0, 0.3)
        let progress = playbackProgress(at: context.date, span: span)

        ZStack(alignment: .leading) {
          RoundedRectangle(cornerRadius: 8)
            .fill(.quaternary)

          if progress > 0 {
            RoundedRectangle(cornerRadius: 8)
              .fill(.tint.opacity(0.16))
              .frame(width: geometry.size.width * progress)
          }

          ForEach(taps.sorted { $0.time < $1.time }) { tap in
            HapticTapTimelineMarker(
              tap: tap,
              x: geometry.size.width * tap.time / span
            )
          }

          if progress > 0 {
            Rectangle()
              .fill(.tint)
              .frame(width: 2)
              .offset(x: geometry.size.width * progress)
          }
        }
      }
    }
    .padding(.horizontal)
    .padding(.vertical, 12)
  }

  private func playbackProgress(at date: Date, span: TimeInterval) -> CGFloat {
    guard let playbackStartedAt else { return 0 }
    let elapsed = date.timeIntervalSince(playbackStartedAt)
    return min(1, max(0, elapsed / max(span, 0.01)))
  }
}

fileprivate struct HapticTapTimelineMarker: View {

  let tap: HapticTapSequence.Tap
  let x: CGFloat

  var body: some View {
    Capsule()
      .fill(.tint)
      .frame(width: 5, height: markerHeight)
      .offset(x: x - 2.5)
      .accessibilityLabel("Tap")
      .accessibilityValue("\(tap.time, format: .number.precision(.fractionLength(2))) seconds")
  }

  private var markerHeight: CGFloat {
    16 + CGFloat(tap.intensity) * 42
  }
}

// MARK: - Tap list

fileprivate struct HapticTapRow: View {

  let number: Int
  let tap: HapticTapSequence.Tap

  var body: some View {
    HStack {
      Label("Tap \(number)", systemImage: "hand.tap")

      Spacer()

      Text("\(tap.time, format: .number.precision(.fractionLength(2)))s")
        .monospacedDigit()
        .foregroundStyle(.secondary)
    }
  }
}

// MARK: - Previews

#Preview("Sequencer") {
  NavigationStack {
    HapticTapSequencerView(sequence: HapticTapSequence(
      name: "Demo Rhythm",
      taps: [
        .init(time: 0),
        .init(time: 0.16),
        .init(time: 0.48, intensity: 0.62, sharpness: 0.5),
      ]
    ))
  }
}

#Preview("Content") {
  @Previewable @State var sequence = HapticTapSequence(
    name: "Preview",
    taps: [.init(time: 0), .init(time: 0.18), .init(time: 0.5)]
  )

  NavigationStack {
    HapticTapSequencerContent(
      sequence: $sequence,
      isRecording: true,
      isSupported: true,
      playbackStartedAt: Date(),
      errorMessage: nil,
      onStartRecording: {},
      onStopRecording: {},
      onRecordTap: {},
      onUndo: {},
      onClear: {},
      onPlay: {},
      onCopySwiftCode: {}
    )
  }
}
