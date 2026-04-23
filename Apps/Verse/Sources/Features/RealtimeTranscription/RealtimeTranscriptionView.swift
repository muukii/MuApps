//
//  RealtimeTranscriptionView.swift
//  YouTubeSubtitle
//
//  Created by Claude on 2025/12/09.
//

import CoreMedia
import SwiftData
import SwiftUI
import Translation

/// Sample view demonstrating real-time microphone transcription using SpeechAnalyzer (iOS 26+)
struct RealtimeTranscriptionView: View {
  @Environment(\.modelContext) private var modelContext
  @State private var viewModel: RealtimeTranscriptionViewModel?
  @State private var explainText: Identified<String>?
  @State private var showSessionHistory = false
  @State private var selectionForActionSheet: TextSelection?

  var body: some View {
    Group {
      if let viewModel {
        mainContent(viewModel: viewModel)
      } else {
        ProgressView("Initializing...")
      }
    }
    .navigationTitle("Live Transcription")
    #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
    #endif
    .toolbar {
      ToolbarItem(placement: .primaryAction) {
        Button {
          showSessionHistory = true
        } label: {
          Image(systemName: "clock.arrow.circlepath")
        }
      }
    }
    .task {
      if viewModel == nil {
        let service = TranscriptionSessionService(modelContext: modelContext)
        viewModel = RealtimeTranscriptionViewModel(sessionService: service)
      }
      await viewModel?.prepareIfNeeded()
    }
    .onDisappear {
      // Stop recording when view disappears
      if let viewModel, viewModel.isRecording {
        Task {
          await viewModel.stopRecording()
        }
      }
      // Re-enable idle timer when leaving the view
      UIApplication.shared.isIdleTimerDisabled = false
    }
    .onChange(of: viewModel?.isRecording) { _, isRecording in
      // Prevent screen sleep during recording
      UIApplication.shared.isIdleTimerDisabled = isRecording ?? false
    }
    .sheet(item: $explainText) { item in
      ExplainSheet(text: item.value)
    }
    .sheet(isPresented: $showSessionHistory) {
      TranscriptionSessionHistoryView()
    }
    .sheet(item: $selectionForActionSheet) { selection in
      SelectionActionSheet(
        selection: selection,
        onCopy: { selectionForActionSheet = nil },
        onDismiss: { selectionForActionSheet = nil }
      )
    }
  }

  @ViewBuilder
  private func mainContent(viewModel: RealtimeTranscriptionViewModel) -> some View {
    VStack(spacing: 0) {
      // Header
      headerSection(viewModel: viewModel)

      // Transcription output
      transcriptionSection(viewModel: viewModel)

      // Controls
      controlsSection(viewModel: viewModel)
    }
  }

  // MARK: - Header Section

  private func headerSection(viewModel: RealtimeTranscriptionViewModel) -> some View {
    VStack(spacing: 8) {
      // Status indicator
      HStack(spacing: 8) {
        Circle()
          .fill(statusColor(for: viewModel.status))
          .frame(width: 12, height: 12)

        Text(viewModel.status.displayText)
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }
      .padding(.vertical, 8)

      // Audio level meter
      if viewModel.isRecording {
        AudioLevelMeter(level: viewModel.audioLevel)
          .frame(height: 4)
          .padding(.horizontal, 40)
      }
    }
    .padding()
    .frame(maxWidth: .infinity)
    .background(.quinary)
  }

  private func statusColor(for status: RealtimeTranscriptionViewModel.Status) -> Color {
    switch status {
    case .idle:
      return .gray
    case .preparing:
      return .orange
    case .ready:
      return .green
    case .recording:
      return .red
    case .error:
      return .red
    }
  }

  // MARK: - Transcription Section

  private func transcriptionSection(viewModel: RealtimeTranscriptionViewModel) -> some View {
    ScrollViewReader { proxy in
      ScrollView {
        LazyVStack(alignment: .leading, spacing: 12) {
          ForEach(viewModel.transcriptions) { item in
            TranscriptionBubbleView(
              item: item,
              onExplain: { text in
                explainText = Identified(text)
              },
              onShowActions: { text in
                selectionForActionSheet = TextSelection(text: text)
              }
            )
            .id(item.id)
          }

          // Current partial transcription
          if let partial = viewModel.partialTranscription, !partial.isEmpty {
            Text(partial)
              .font(.body)
              .foregroundStyle(.secondary)
              .italic()
              .padding(.horizontal, 16)
              .id("partial")
          }
        }
        .padding()
      }
      .onChange(of: viewModel.transcriptions.count) { _, _ in
        withAnimation {
          if let last = viewModel.transcriptions.last {
            proxy.scrollTo(last.id, anchor: .bottom)
          }
        }
      }
      .onChange(of: viewModel.partialTranscription) { _, _ in
        withAnimation {
          proxy.scrollTo("partial", anchor: .bottom)
        }
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .background(Color(.systemBackground))
  }

  // MARK: - Controls Section

  private func controlsSection(viewModel: RealtimeTranscriptionViewModel) -> some View {
    VStack(spacing: 16) {
      Divider()

      HStack(spacing: 24) {
        // Clear button
        Button {
          viewModel.clearTranscriptions()
        } label: {
          Label("Clear", systemImage: "trash")
            .font(.subheadline)
        }
        .buttonStyle(.bordered)
        .disabled(viewModel.transcriptions.isEmpty)

        // Share button
        ShareLink(item: viewModel.exportText) {
          Label("Share", systemImage: "square.and.arrow.up")
            .font(.subheadline)
        }
        .buttonStyle(.bordered)
        .disabled(viewModel.transcriptions.isEmpty)

        // Record/Stop button
        Button {
          Task {
            if viewModel.isRecording {
              await viewModel.stopRecording()
            } else {
              await viewModel.startRecording()
            }
          }
        } label: {
          Label(
            viewModel.isRecording ? "Stop" : "Start",
            systemImage: viewModel.isRecording ? "stop.circle.fill" : "mic.circle.fill"
          )
          .font(.headline)
        }
        .buttonStyle(.borderedProminent)
        .tint(viewModel.isRecording ? .red : .blue)
        .disabled(!viewModel.canRecord)
      }
      .padding(.horizontal)
      .padding(.bottom, 16)
    }
    .background(Color(.secondarySystemBackground))
  }
}

// MARK: - Transcription Item

@MainActor
struct TranscriptionItem: Identifiable, Equatable {
  let id = UUID()
  let text: AttributedString
  let timestamp: Date

  var formattedTime: String {
    let formatter = DateFormatter()
    formatter.timeStyle = .medium
    return formatter.string(from: timestamp)
  }

  /// Extract word timings from AttributedString's audioTimeRange attributes
  var wordTimings: [Subtitle.WordTiming] {
    var timings: [Subtitle.WordTiming] = []
    var index = text.startIndex
    while index < text.endIndex {
      let run = text.runs[index]
      if let timeRange = run.audioTimeRange {
        let word = String(text[run.range].characters)
        timings.append(Subtitle.WordTiming(
          text: word,
          startTime: timeRange.start.seconds,
          endTime: timeRange.end.seconds
        ))
      }
      index = run.range.upperBound
    }
    return timings
  }

  /// Plain text representation
  var plainText: String {
    String(text.characters)
  }

  static func == (lhs: TranscriptionItem, rhs: TranscriptionItem) -> Bool {
    lhs.id == rhs.id
  }
}

// MARK: - TranscriptionDisplayable Conformance

extension TranscriptionItem: @MainActor TranscriptionDisplayable {
  var displayText: String { plainText }
  var displayWordTimings: [Subtitle.WordTiming]? { wordTimings.isEmpty ? nil : wordTimings }
  var displayFormattedTime: String { formattedTime }
}

// MARK: - Audio Level Meter

private struct AudioLevelMeter: View {
  let level: Float

  var body: some View {
    GeometryReader { geometry in
      ZStack(alignment: .leading) {
        // Background
        RoundedRectangle(cornerRadius: 2)
          .fill(Color.gray.opacity(0.3))

        // Level indicator
        RoundedRectangle(cornerRadius: 2)
          .fill(levelColor)
          .frame(width: geometry.size.width * CGFloat(normalizedLevel))
          .animation(.linear(duration: 0.1), value: level)
      }
    }
  }

  private var normalizedLevel: Float {
    // Normalize dB level to 0-1 range
    // Typical range: -60dB (silence) to 0dB (max)
    let minDb: Float = -60
    let maxDb: Float = 0
    let clampedLevel = max(minDb, min(maxDb, level))
    return (clampedLevel - minDb) / (maxDb - minDb)
  }

  private var levelColor: Color {
    if normalizedLevel > 0.8 {
      return .red
    } else if normalizedLevel > 0.5 {
      return .yellow
    } else {
      return .green
    }
  }
}

// MARK: - Explain Sheet

private struct ExplainSheet: View {
  @Environment(\.dismiss) private var dismiss
  let text: String

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(alignment: .leading, spacing: 16) {
          Text("Selected Text")
            .font(.caption)
            .foregroundStyle(.secondary)

          Text(text)
            .font(.body)
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 8))

          Divider()

          Text("Explanation")
            .font(.caption)
            .foregroundStyle(.secondary)

          // TODO: Add AI explanation here
          Text("Explanation feature coming soon...")
            .font(.body)
            .foregroundStyle(.secondary)
            .italic()
        }
        .padding()
      }
      .navigationTitle("Explain")
      #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Done") {
            dismiss()
          }
        }
        ToolbarItem(placement: .primaryAction) {
          Button {
            UIPasteboard.general.string = text
          } label: {
            Image(systemName: "doc.on.doc")
          }
        }
      }
    }
    .presentationDetents([.medium, .large])
  }
}

// MARK: - Preview

#Preview {
  NavigationStack {
    RealtimeTranscriptionView()
  }
}
