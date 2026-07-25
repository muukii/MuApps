//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//

import SwiftUI

/// Presents aggregate progress and per-video results for one serial export job.
struct ExportProgressView: View {

  let batch: VideoExportBatch

  @Environment(\.dismiss) private var dismiss
  private let coordinator = BackgroundExportCoordinator.shared

  @State private var activeBatch: VideoExportBatch
  @State private var retainedResults: [VideoExportBatchResult] = []
  @State private var manualSavePhases: [VideoClip.ID: ExportManualSavePhase] = [:]
  @State private var isCancelling = false

  init(batch: VideoExportBatch) {
    self.batch = batch
    self._activeBatch = State(initialValue: batch)
  }

  var body: some View {
    NavigationStack {
      ExportProgressContent(
        phase: visiblePhase,
        batch: activeBatch,
        activePath: coordinator.activePath,
        manualSavePhases: manualSavePhases,
        onSaveToPhotos: saveToPhotos,
        onRetryFailed: retryFailed
      )
      .padding()
      .navigationTitle("Export")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(isCancelling ? "Cancelling…" : (isTerminal ? "Done" : "Cancel")) {
            if isTerminal {
              coordinator.reset()
              dismiss()
            } else {
              guard isCancelling == false else { return }
              isCancelling = true
              Task {
                await coordinator.cancelAndWait()
                dismiss()
              }
            }
          }
          .disabled(isCancelling)
        }
      }
      .onAppear {
        guard case .idle = coordinator.phase else { return }
        coordinator.start(batch: activeBatch)
      }
    }
    .interactiveDismissDisabled(isExporting || isCancelling)
  }

  private var isExporting: Bool {
    switch coordinator.phase {
    case .exporting:
      return true
    case .idle, .finished, .failed:
      return false
    }
  }

  /// Recombines successful earlier attempts with the latest retry results in
  /// the original picker order.
  private var visiblePhase: BackgroundExportCoordinator.Phase {
    guard case .finished(let latestResults) = coordinator.phase else {
      return coordinator.phase
    }

    let resultsByID = Dictionary(
      (retainedResults + latestResults).map { ($0.id, $0) },
      uniquingKeysWith: { _, latest in latest }
    )
    let orderedResults = batch.items.compactMap { resultsByID[$0.id] }
    return .finished(orderedResults)
  }

  private var isTerminal: Bool {
    switch coordinator.phase {
    case .finished, .failed:
      return true
    case .idle, .exporting:
      return false
    }
  }

  private func saveToPhotos(result: VideoExportBatchResult) {
    guard case .exported(let url, _) = result.outcome else { return }
    manualSavePhases[result.id] = .saving

    Task {
      do {
        try await PhotoLibrarySaver.save(videoAt: url)
        manualSavePhases[result.id] = .saved
      } catch {
        manualSavePhases[result.id] = .failed(error.localizedDescription)
      }
    }
  }

  private func retryFailed(results: [VideoExportBatchResult]) {
    let failedIDs = Set(
      results.compactMap { result -> VideoClip.ID? in
        switch result.outcome {
        case .exported:
          return nil
        case .failed:
          return result.id
        }
      }
    )
    let retryItems = batch.items.filter { failedIDs.contains($0.id) }
    guard retryItems.isEmpty == false else { return }

    retainedResults = results.filter { result in
      switch result.outcome {
      case .exported:
        return true
      case .failed:
        return false
      }
    }
    let retainedOutputURLs = Set(
      retainedResults.compactMap { result -> URL? in
        guard case .exported(let url, _) = result.outcome else { return nil }
        return url
      }
    )
    coordinator.reset()
    activeBatch = VideoExportBatch(
      items: retryItems,
      recipe: batch.recipe
    )
    coordinator.start(
      batch: activeBatch,
      retaining: retainedOutputURLs
    )
  }
}

/// Routes coordinator state into focused running, completion, and failure views.
fileprivate struct ExportProgressContent: View {

  let phase: BackgroundExportCoordinator.Phase
  let batch: VideoExportBatch
  let activePath: BackgroundExportCoordinator.ActivePath?
  let manualSavePhases: [VideoClip.ID: ExportManualSavePhase]
  let onSaveToPhotos: @MainActor @Sendable (VideoExportBatchResult) -> Void
  let onRetryFailed: @MainActor @Sendable ([VideoExportBatchResult]) -> Void

  var body: some View {
    VStack(spacing: 24) {
      switch phase {
      case .idle:
        ExportRunningView(
          progress: VideoExportBatchProgress(
            currentItemIndex: 0,
            itemCount: batch.items.count,
            currentItemFraction: 0
          ),
          hdrVideoCount: batch.hdrVideoCount,
          activePath: activePath
        )

      case .exporting(let progress):
        ExportRunningView(
          progress: progress,
          hdrVideoCount: batch.hdrVideoCount,
          activePath: activePath
        )

      case .finished(let results):
        ExportCompletionView(
          results: results,
          manualSavePhases: manualSavePhases,
          onSaveToPhotos: onSaveToPhotos,
          onRetryFailed: onRetryFailed
        )

      case .failed(let message):
        ExportFailureView(message: message)
      }

      Spacer(minLength: 0)
    }
  }
}

/// Displays both the active video's position and aggregate batch progress.
fileprivate struct ExportRunningView: View {

  let progress: VideoExportBatchProgress
  let hdrVideoCount: Int
  let activePath: BackgroundExportCoordinator.ActivePath?

  var body: some View {
    VStack(spacing: 16) {
      ProgressView(value: progress.overallFraction) {
        Text(
          "Exporting video \(progress.currentItemIndex + 1) of \(progress.itemCount)",
          comment:
            "Export progress. The first variable is the current video and the second is the total."
        )
      }
      .progressViewStyle(.linear)
      .accessibilityLabel(
        Text(
          "Exporting video \(progress.currentItemIndex + 1) of \(progress.itemCount)",
          comment:
            "Export accessibility label. The first variable is the current video and the second is the total."
        )
      )
      .accessibilityValue(
        Text(
          progress.overallFraction,
          format: .percent.precision(.fractionLength(0))
        )
      )

      Text(
        progress.overallFraction,
        format: .percent.precision(.fractionLength(0))
      )
      .font(.largeTitle.monospacedDigit().weight(.semibold))

      ExportExecutionNotice(activePath: activePath)

      if hdrVideoCount > 0 {
        Group {
          if hdrVideoCount == 1 {
            Label(
              "1 HDR video will be exported in SDR.",
              systemImage: "exclamationmark.triangle"
            )
          } else {
            Label(
              "\(hdrVideoCount) HDR videos will be exported in SDR.",
              systemImage: "exclamationmark.triangle"
            )
          }
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
      }
    }
    .padding(.top, 32)
  }
}

/// Explains whether the current export may continue outside the foreground.
fileprivate struct ExportExecutionNotice: View {

  let activePath: BackgroundExportCoordinator.ActivePath?

  var body: some View {
    switch activePath {
    case .background:
      Label(
        "You can leave the app — it keeps exporting in the background.",
        systemImage: "moon.zzz"
      )
      .font(.footnote)
      .foregroundStyle(.secondary)
      .multilineTextAlignment(.center)

    case .foreground(let error):
      VStack(alignment: .leading, spacing: 6) {
        Label(
          "Background export could not start",
          systemImage: "exclamationmark.triangle.fill"
        )
        .font(.footnote.weight(.semibold))
        .foregroundStyle(.red)

        Text(error.localizedDescription)
          .font(.caption)

        Text("Export is continuing in the foreground. Keep the app open.")
          .font(.caption)
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .foregroundStyle(.secondary)
      .padding(12)
      .background(.red.opacity(0.1), in: RoundedRectangle(cornerRadius: 12))

    case nil:
      Label("Starting background export…", systemImage: "clock")
        .font(.footnote)
        .foregroundStyle(.secondary)
    }
  }
}

/// Summarizes partial success without conflating render and Photos failures.
fileprivate struct ExportCompletionView: View {

  let results: [VideoExportBatchResult]
  let manualSavePhases: [VideoClip.ID: ExportManualSavePhase]
  let onSaveToPhotos: @MainActor @Sendable (VideoExportBatchResult) -> Void
  let onRetryFailed: @MainActor @Sendable ([VideoExportBatchResult]) -> Void

  var body: some View {
    ScrollView {
      VStack(spacing: 20) {
        Image(
          systemName:
            renderFailureCount == 0
              ? "checkmark.circle.fill"
              : "exclamationmark.circle.fill"
        )
        .font(.system(size: 56))
        .foregroundStyle(renderFailureCount == 0 ? .green : .orange)

        VStack(spacing: 6) {
          Text(renderFailureCount == 0 ? "Export complete" : "Batch complete")
            .font(.headline)

          if renderFailureCount == 0 {
            if exportedCount == 1 {
              Text("1 video exported")
            } else {
              Text(
                "\(exportedCount) videos exported",
                comment: "Completion summary. The variable is the number of rendered videos."
              )
            }
          } else {
            Text(
              "\(exportedCount) exported · \(renderFailureCount) failed",
              comment:
                "Partial completion summary. Variables are successful and failed video counts."
            )
          }

          if readyToSaveCount > 0 {
            Group {
              if readyToSaveCount == 1 {
                Text("1 video ready to save to Photos")
              } else {
                Text(
                  "\(readyToSaveCount) videos ready to save to Photos",
                  comment:
                    "The number of rendered videos that still need to be saved to Photos."
                )
              }
            }
            .foregroundStyle(.secondary)
          }
        }
        .font(.callout)

        LazyVStack(spacing: 10) {
          ForEach(results) { result in
            ExportResultRow(
              result: result,
              manualSavePhase: manualSavePhases[result.id],
              onSaveToPhotos: { onSaveToPhotos(result) }
            )
          }
        }

        if renderFailureCount > 0 {
          Button {
            onRetryFailed(results)
          } label: {
            Text(
              "Retry \(renderFailureCount) Failed",
              comment: "Retries only the videos that failed to render."
            )
            .frame(maxWidth: .infinity)
          }
          .buttonStyle(.borderedProminent)
          .controlSize(.large)
        }
      }
      .padding(.top, 24)
    }
  }

  private var exportedCount: Int {
    results.count { result in
      switch result.outcome {
      case .exported:
        return true
      case .failed:
        return false
      }
    }
  }

  private var renderFailureCount: Int {
    results.count - exportedCount
  }

  private var readyToSaveCount: Int {
    results.count { result in
      switch result.outcome {
      case .exported(_, let savedToPhotos):
        let manualSavePhase = manualSavePhases[result.id]
        return savedToPhotos == false && manualSavePhase != .saved
      case .failed:
        return false
      }
    }
  }
}

/// One stable result row with independent Share and Photos recovery actions.
fileprivate struct ExportResultRow: View {

  let result: VideoExportBatchResult
  let manualSavePhase: ExportManualSavePhase?
  let onSaveToPhotos: @MainActor @Sendable () -> Void

  var body: some View {
    HStack(spacing: 12) {
      resultIcon
        .frame(width: 24)

      VStack(alignment: .leading, spacing: 3) {
        Text(result.displayName)
          .font(.subheadline.weight(.medium))
          .lineLimit(1)
        resultStatus
          .font(.caption)
          .foregroundStyle(.secondary)
          .lineLimit(2)
      }

      Spacer(minLength: 8)

      switch result.outcome {
      case .exported(let url, let savedToPhotos):
        if savedToPhotos == false, manualSavePhase != .saved {
          Button(action: onSaveToPhotos) {
            if manualSavePhase == .saving {
              ProgressView()
            } else {
              Image(systemName: "photo.badge.plus")
            }
          }
          .buttonStyle(.bordered)
          .disabled(manualSavePhase == .saving)
          .accessibilityLabel("Save to Photos")
        }

        ShareLink(item: url) {
          Image(systemName: "square.and.arrow.up")
        }
        .buttonStyle(.bordered)
        .accessibilityLabel("Share \(result.displayName)")

      case .failed:
        EmptyView()
      }
    }
    .padding(12)
    .background(
      Color(.secondarySystemBackground),
      in: RoundedRectangle(cornerRadius: 14, style: .continuous)
    )
  }

  @ViewBuilder
  private var resultIcon: some View {
    switch result.outcome {
    case .exported:
      Image(systemName: "checkmark.circle.fill")
        .foregroundStyle(.green)
    case .failed:
      Image(systemName: "exclamationmark.circle.fill")
        .foregroundStyle(.orange)
    }
  }

  @ViewBuilder
  private var resultStatus: some View {
    switch result.outcome {
    case .exported(_, let savedToPhotos):
      if savedToPhotos || manualSavePhase == .saved {
        Text("Saved to Photos")
      } else if case .failed(let message) = manualSavePhase {
        Text(message)
      } else {
        Text("Ready to save")
      }
    case .failed(let message):
      Text(message)
    }
  }
}

/// Displays an unrecoverable job-level failure rather than an item failure.
fileprivate struct ExportFailureView: View {

  let message: String

  var body: some View {
    VStack(spacing: 16) {
      Image(systemName: "exclamationmark.triangle")
        .font(.system(size: 44))
        .foregroundStyle(.orange)
      Text("Export failed")
        .font(.headline)
      Text(message)
        .font(.callout)
        .foregroundStyle(.secondary)
        .multilineTextAlignment(.center)
    }
    .padding(.top, 32)
  }
}

/// Manual recovery state for a rendered file that was not auto-saved.
fileprivate enum ExportManualSavePhase: Equatable {
  case saving
  case saved
  case failed(String)
}

#Preview("Exporting") {
  NavigationStack {
    ExportRunningView(
      progress: VideoExportBatchProgress(
        currentItemIndex: 1,
        itemCount: 3,
        currentItemFraction: 0.42
      ),
      hdrVideoCount: 1,
      activePath: .background
    )
    .padding()
    .navigationTitle("Export")
    .navigationBarTitleDisplayMode(.inline)
  }
}

#Preview("Foreground fallback error") {
  NavigationStack {
    ExportRunningView(
      progress: VideoExportBatchProgress(
        currentItemIndex: 0,
        itemCount: 1,
        currentItemFraction: 0.12
      ),
      hdrVideoCount: 0,
      activePath: .foreground(
        .requestSubmissionFailed(
          description: "The request was denied.",
          domain: "BGTaskSchedulerErrorDomain",
          code: 1
        )
      )
    )
    .padding()
    .navigationTitle("Export")
    .navigationBarTitleDisplayMode(.inline)
  }
}

#Preview("Export results") {
  NavigationStack {
    ExportCompletionView(
      results: [
        VideoExportBatchResult(
          id: UUID(),
          displayName: "Morning Log",
          outcome: .exported(
            url: URL(filePath: "/tmp/Morning-Log.mov"),
            savedToPhotos: true
          )
        ),
        VideoExportBatchResult(
          id: UUID(),
          displayName: "Evening Log",
          outcome: .failed(message: "The source video could not be read.")
        ),
      ],
      manualSavePhases: [:],
      onSaveToPhotos: { _ in },
      onRetryFailed: { _ in }
    )
    .padding()
    .navigationTitle("Export")
    .navigationBarTitleDisplayMode(.inline)
  }
}
