//
//  SubtitleListView.swift
//  YouTubeSubtitle
//
//  Created by Claude on 2025/12/02.
//

import CoreMedia
import Speech
import SwiftUI
import Translation
import UIKit

// MARK: - Subtitle List View Container

/// Container that connects SubtitleListView to PlayerModel.
/// This isolates model observation so only this view re-renders when model.currentTime changes,
/// preventing unnecessary re-renders of the parent PlayerView.
struct SubtitleListViewContainer: View {
  let model: PlayerModel
  let cues: [Subtitle.Cue]
  let isLoading: Bool
  let error: String?
  let onAction: (SubtitleAction) -> Void

  var body: some View {
    SubtitleListView(
      cues: cues,
      currentTime: model.currentTime,
      currentCueID: model.currentCueID,  // Use shared logic from PlayerModel
      isLoading: isLoading,
      error: error,
      onAction: onAction
    )
  }
}

// MARK: - Subtitle List View

struct SubtitleListView: View {
  let cues: [Subtitle.Cue]
  let currentTime: CurrentTime
  let currentCueID: Subtitle.Cue.ID?
  let isLoading: Bool
  let error: String?
  let onAction: (SubtitleAction) -> Void

  @State var isTrackingEnabled: Bool = true

  var body: some View {
    Group {
      if isLoading {
        ProgressView()
          .frame(maxWidth: .infinity, maxHeight: .infinity)
      } else if let error {
        errorView(error: error)
      } else if cues.isEmpty {
        emptyView
      } else {
        subtitleList
          .overlay(alignment: .bottomTrailing) {
            trackingButton
          }
      }
    }

  }
  
  private var trackingButton: some View {
    Button {
      isTrackingEnabled.toggle()
    } label: {
      Image(
        systemName: "arrow.up.left.circle"
      )
      .font(.system(size: 28))
      .foregroundStyle(isTrackingEnabled ? .primary : .secondary)
    }
    .buttonStyle(.glassProminent)
    .frame(width: 48, height: 48)
    .padding(12)
  }

  // MARK: - Error View

  private func errorView(error: String) -> some View {
    VStack(spacing: 12) {
      Image(systemName: "exclamationmark.triangle")
        .font(.system(size: 40))
        .foregroundStyle(.orange)
      Text("Failed to load subtitles")
        .font(.headline)
      Text(error)
        .font(.caption)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }
    .padding()
    .frame(maxWidth: .infinity, maxHeight: .infinity)
  }

  // MARK: - Empty View

  private var emptyView: some View {
    ContentUnavailableView(
      "No Subtitles",
      systemImage: "text.bubble",
      description: Text("No subtitles available for this video")
    )
  }

  // MARK: - Subtitle List

  private var subtitleList: some View {
    ScrollViewReader { proxy in
      SubtitleScrollContent(
        cues: cues,
        currentTime: currentTime,
        currentCueID: currentCueID,
        onAction: onAction,
        onSelectionChanged: { hasSelection in
          if hasSelection {
            isTrackingEnabled = false
          }
        }
      )
      .onScrollPhaseChange { _, newPhase in
        if newPhase == .interacting {
          isTrackingEnabled = false
        }
      }
      .onChange(of: currentCueID) { _, newID in
        guard let newID, isTrackingEnabled else { return }
        withAnimation(.bouncy) {
          proxy.scrollTo(newID, anchor: .center)
        }
      }
      .onChange(of: isTrackingEnabled) { _, isEnabled in
        guard isEnabled, let currentCueID else { return }
        withAnimation(.bouncy) {
          proxy.scrollTo(currentCueID, anchor: .center)
        }
      }
    }
  }
}

// MARK: - Subtitle Action

enum SubtitleAction {
  case tap(time: Double)
  case setRepeatA(time: Double)
  case setRepeatB(time: Double)
  case setRepeatRange(startTime: Double, endTime: Double)
  case explain(cue: Subtitle.Cue)
  case translate(cue: Subtitle.Cue)
  case explainSelection(text: String, context: String)
  case showSelectionActions(text: String, context: String)
}

// MARK: - Subtitle Scroll Content

/// Isolated component that re-renders when currentCueID changes.
/// Since currentCueID only changes when the subtitle changes (every few seconds),
/// this prevents re-renders every 500ms when currentTime updates.
private struct SubtitleScrollContent: View {
  let cues: [Subtitle.Cue]
  let currentTime: CurrentTime
  let currentCueID: Subtitle.Cue.ID?
  let onAction: (SubtitleAction) -> Void
  var onSelectionChanged: ((Bool) -> Void)?

  var body: some View {
    List {
      ForEach(Array(cues.enumerated()), id: \.element.id) { index, cue in
        SubtitleRowView(
          cue: cue,
          currentTime: currentTime,
          isCurrent: cue.id == currentCueID,
          onAction: { action in
            switch action {
            case .tap:
              onAction(.tap(time: cue.startTime))
            case .setRepeatA:
              onAction(.setRepeatA(time: cue.startTime))
            case .setRepeatB:
              onAction(.setRepeatB(time: cue.endTime))
            case .setRepeatRange:
              // Use next cue's startTime as end to handle overlapping cues
              let endTime = cues[safe: index + 1]?.startTime ?? cue.endTime
              onAction(.setRepeatRange(startTime: cue.startTime, endTime: endTime))
            case .explain:
              onAction(.explain(cue: cue))
            case .translate:
              onAction(.translate(cue: cue))
            case .explainSelection(let selectedText):
              onAction(.explainSelection(text: selectedText, context: cue.decodedText))
            case .showSelectionActions(let selectedText):
              onSelectionChanged?(true)
              onAction(.showSelectionActions(text: selectedText, context: cue.decodedText))
            }
          }
        )
        .listRowInsets(EdgeInsets(top: 3, leading: 12, bottom: 3, trailing: 12))
        .listRowSeparator(.hidden)
        .listRowBackground(Color.clear)
        .swipeActions(edge: .leading, allowsFullSwipe: true) {
          Button {
            onAction(.translate(cue: cue))
          } label: {
            Label("Translate", systemImage: "character.book.closed")
          }
          .tint(.blue)
        }
        .swipeActions(edge: .trailing, allowsFullSwipe: true) {
          Button {
            onAction(.explain(cue: cue))
          } label: {
            Label("Explain", systemImage: "sparkles")
          }
          .tint(.purple)
        }
      }
    }
    .listStyle(.plain)
    .scrollContentBackground(.hidden)
  }
}


// MARK: - Array Safe Subscript

extension Array {
  subscript(safe index: Int) -> Element? {
    indices.contains(index) ? self[index] : nil
  }
}

// MARK: - HTML Decoding Extension

extension String {
  nonisolated var htmlDecoded: String {
    var result =
      self
      .replacingOccurrences(of: "&amp;", with: "&")
      .replacingOccurrences(of: "&lt;", with: "<")
      .replacingOccurrences(of: "&gt;", with: ">")
      .replacingOccurrences(of: "&quot;", with: "\"")
      .replacingOccurrences(of: "&apos;", with: "'")
      .replacingOccurrences(of: "&#39;", with: "'")
      .replacingOccurrences(of: "&#x27;", with: "'")
      .replacingOccurrences(of: "&#x2F;", with: "/")
      .replacingOccurrences(of: "&nbsp;", with: " ")

    // Decode numeric entities like &#8217;
    let pattern = "&#([0-9]+);"
    while let range = result.range(of: pattern, options: .regularExpression) {
      let matched = String(result[range])
      let numStr = matched.dropFirst(2).dropLast(1)
      if let code = UInt32(numStr), let scalar = Unicode.Scalar(code) {
        result.replaceSubrange(range, with: String(scalar))
      } else {
        break
      }
    }

    return result
  }
}

#Preview("Subtitle List") {
  struct PreviewWrapper: View {
    let currentTime: CurrentTime = {
      let time = CurrentTime()
      time.value = 4
      return time
    }()

    var body: some View {
      SubtitleListView(
        cues: [
          Subtitle.Cue(
            id: 1,
            startTime: 0,
            endTime: 3,
            text: "Hello, world!",
            wordTimings: nil
          ),
          Subtitle.Cue(
            id: 2,
            startTime: 3,
            endTime: 6,
            text: "This is a test subtitle.",
            wordTimings: nil
          ),
          Subtitle.Cue(
            id: 3,
            startTime: 6,
            endTime: 9,
            text: "Testing the subtitle list view.",
            wordTimings: nil
          ),
        ],
        currentTime: currentTime,
        currentCueID: nil,
        isLoading: false,
        error: nil,
        onAction: { _ in }
      )
    }
  }
  return PreviewWrapper()
}
