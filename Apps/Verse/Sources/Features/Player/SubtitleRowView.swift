//
//  SubtitleRowView.swift
//  YouTubeSubtitle
//
//  Created by Claude on 2025/12/19.
//

import CoreMedia
import SwiftUI
import UIKit

// MARK: - Subtitle Row View

struct SubtitleRowView: View {

  enum Action {
    case tap
    case setRepeatA
    case setRepeatB
    case setRepeatRange
    case explain
    case translate
    case explainSelection(String)
    case showSelectionActions(String)
  }

  let cue: Subtitle.Cue
  /// Current playback time (reads .value only when isCurrent, so only this row re-renders)
  let currentTime: CurrentTime
  let isCurrent: Bool
  let onAction: (Action) -> Void

  /// Computed highlight time - only reads currentTime.value when this row is current
  private var highlightTime: CMTime? {
    guard isCurrent else { return nil }
    return CMTime(seconds: currentTime.value, preferredTimescale: 600)
  }

  var body: some View {
    VStack(spacing: 4) {

      HStack(alignment: .top, spacing: 8) {
        
        Button {
          onAction(.tap)
        } label: {
          RoundedRectangle(cornerRadius: 8)
            .frame(minHeight: 0)
            .frame(width: 30)
            .foregroundStyle(.quinary)          
        }
        .buttonStyle(.plain)

        // Text content with selection and word tap support
        SelectableSubtitleTextView(
          content: .init(
            text: cue.decodedText,
            wordTimings: cue.wordTimings,
            startTime: cue.startTime,
            endTime: cue.endTime
          ),
          highlightTime: highlightTime,
          font: .systemFont(ofSize: 18, weight: .bold, width: .standard),
          textColor: .tintColor,
          playedTextColor: .tintColor,
          unplayedTextColor: .tintColor.withAlphaComponent(0.4),
          lineSpacing: 10,
          playbackTime: currentTime.value,
          onExplain: { selectedText in
            onAction(.explainSelection(selectedText))
          },
          onShowActions: { selectedText in
            onAction(.showSelectionActions(selectedText))
          }
        )
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)

        menu
      }
      .padding(.bottom, 10)
      .padding(.horizontal, 8)
    }
    .id(cue.id)
    .animation(.snappy, value: isCurrent)
    .foregroundStyle(.tint)
  }

  private var menu: some View {
    // Menu button for actions
    Menu {
      Button {
        #if os(iOS)
          UIPasteboard.general.string = cue.decodedText
        #else
          NSPasteboard.general.clearContents()
          NSPasteboard.general.setString(cue.decodedText, forType: .string)
        #endif
      } label: {
        Label("Copy", systemImage: "doc.on.doc")
      }

      Button {
        onAction(.explain)
      } label: {
        Label("Explain", systemImage: "sparkles")
      }

      Button {
        onAction(.translate)
      } label: {
        Label("Translate", systemImage: "character.book.closed")
      }

      Divider()

      Button {
        onAction(.setRepeatRange)
      } label: {
        Label("Repeat This", systemImage: "repeat.1")
      }

      Button {
        onAction(.setRepeatA)
      } label: {
        Label("Set as A (Start)", systemImage: "a.circle")
      }

      Button {
        onAction(.setRepeatB)
      } label: {
        Label("Set as B (End)", systemImage: "b.circle")
      }
    } label: {
      Image(systemName: "ellipsis")
        .font(.system(size: 18))
        .foregroundStyle(.primary)
        .frame(width: 32, height: 24)
        .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }

  private func formatTime(_ seconds: Double) -> String {
    let totalSeconds = Int(seconds)
    let hours = totalSeconds / 3600
    let minutes = (totalSeconds % 3600) / 60
    let secs = totalSeconds % 60
    let millis = Int((seconds.truncatingRemainder(dividingBy: 1)) * 1000)

    if hours > 0 {
      return String(format: "%d:%02d:%02d.%03d", hours, minutes, secs, millis)
    } else {
      return String(format: "%d:%02d.%03d", minutes, secs, millis)
    }
  }
}

// MARK: - Preview

#Preview("SubtitleRowView") {
  struct PreviewWrapper: View {
    let currentTime: CurrentTime = {
      let time = CurrentTime()
      time.value = 66
      return time
    }()

    var body: some View {
      VStack {
        SubtitleRowView(
          cue: Subtitle.Cue(
            id: 1,
            startTime: 65.5,
            endTime: 68.2,
            text: "This is the currently playing subtitle with some longer text to see how it wraps.",
            wordTimings: nil
          ),
          currentTime: currentTime,
          isCurrent: true,
          onAction: { _ in }
        )
        .padding()

        SubtitleRowView(
          cue: Subtitle.Cue(
            id: 2,
            startTime: 125.75,
            endTime: 129.0,
            text: "A subtitle that is not currently active.",
            wordTimings: nil
          ),
          currentTime: currentTime,
          isCurrent: false,
          onAction: { _ in }
        )
        .padding()
      }
    }
  }
  return PreviewWrapper()
}

#Preview("Word Highlight") {
  struct PreviewWrapper: View {
    // Set currentTime to highlight "beautiful" (starts at 10.8)
    let currentTime: CurrentTime = {
      let time = CurrentTime()
      time.value = 10.9  // During "beautiful"
      return time
    }()

    var body: some View {
      VStack(spacing: 20) {
        Text("Word \"beautiful\" should be highlighted")
          .font(.caption)
          .foregroundStyle(.secondary)

        SubtitleRowView(
          cue: Subtitle.Cue(
            id: 1,
            startTime: 10.0,
            endTime: 13.5,
            text: "This is a beautiful example of word highlighting.",
            wordTimings: [
              Subtitle.WordTiming(text: "This", startTime: 10.0, endTime: 10.2),
              Subtitle.WordTiming(text: "is", startTime: 10.2, endTime: 10.4),
              Subtitle.WordTiming(text: "a", startTime: 10.4, endTime: 10.5),
              Subtitle.WordTiming(text: "beautiful", startTime: 10.8, endTime: 11.2),
              Subtitle.WordTiming(text: "example", startTime: 11.3, endTime: 11.7),
              Subtitle.WordTiming(text: "of", startTime: 11.8, endTime: 11.9),
              Subtitle.WordTiming(text: "word", startTime: 12.0, endTime: 12.3),
              Subtitle.WordTiming(text: "highlighting.", startTime: 12.4, endTime: 13.0),
            ]
          ),
          currentTime: currentTime,
          isCurrent: true,
          onAction: { action in
            print("Action: \(action)")
          }
        )
        .padding()
        .tint(.blue)
      }
    }
  }
  return PreviewWrapper()
}
