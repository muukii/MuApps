//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//

import SwiftUI

/// Keeps every picker item visible while its own export attempt advances.
struct ExportProgressView: View {

  let session: VideoExportSessionModel

  @Environment(\.dismiss) private var dismiss
  @State private var isCancellingAll = false

  private let coordinator = BackgroundExportCoordinator.shared

  var body: some View {
    NavigationStack {
      ExportSessionList(
        session: session,
        onCancel: cancel,
        onRetry: coordinator.retry,
        onSaveToPhotos: coordinator.saveToPhotos
      )
      .navigationTitle("Export")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          if session.isSettled {
            Button(
              session.hasManualPhotosSaveInProgress
                ? "Saving…" : "Done"
            ) {
              if coordinator.discardSettledSession(
                sessionID: session.id
              ) {
                dismiss()
              }
            }
            .disabled(session.hasManualPhotosSaveInProgress)
          } else {
            Button(isCancellingAll ? "Cancelling…" : "Cancel All") {
              guard isCancellingAll == false else { return }
              isCancellingAll = true
              Task {
                await coordinator.cancelAllAndWait()
                isCancellingAll = false
              }
            }
            .disabled(isCancellingAll)
            .accessibilityIdentifier("cancel-all-exports")
          }
        }
      }
    }
    .interactiveDismissDisabled(
      session.hasActiveItems
        || session.hasManualPhotosSaveInProgress
        || isCancellingAll
    )
  }

  private func cancel(itemID: VideoClip.ID) {
    Task {
      await coordinator.cancelAndWait(itemID: itemID)
    }
  }
}

/// Displays aggregate context above stable, picker-ordered export rows.
private struct ExportSessionList: View {

  let session: VideoExportSessionModel
  let onCancel: @MainActor @Sendable (VideoClip.ID) -> Void
  let onRetry: @MainActor @Sendable (VideoClip.ID) -> Void
  let onSaveToPhotos: @MainActor @Sendable (VideoClip.ID) -> Void

  var body: some View {
    List {
      Section {
        ExportSessionSummaryView(session: session)
      }

      Section {
        ForEach(session.items) { item in
          ExportItemRow(
            item: item,
            onCancel: { onCancel(item.id) },
            onRetry: { onRetry(item.id) },
            onSaveToPhotos: { onSaveToPhotos(item.id) }
          )
          .accessibilityIdentifier("export-item-\(item.id.uuidString)")
        }
      }
    }
    .listStyle(.insetGrouped)
    .accessibilityIdentifier("export-session-list")
  }
}

/// Summarizes the session without replacing item-level status and actions.
private struct ExportSessionSummaryView: View {

  let session: VideoExportSessionModel

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack(alignment: .firstTextBaseline) {
        Text(summary)
          .font(.headline)

        Spacer()

        Text(
          session.overallFraction,
          format: .percent.precision(.fractionLength(0))
        )
        .font(.subheadline.monospacedDigit().weight(.medium))
        .foregroundStyle(.secondary)
      }

      ProgressView(value: session.overallFraction)
        .progressViewStyle(.linear)
        .accessibilityIdentifier("export-summary-progress")

      executionNotice

      if session.hdrVideoCount > 0 {
        Label {
          if session.hdrVideoCount == 1 {
            Text("1 HDR video will be exported in SDR.")
          } else {
            Text(
              "\(session.hdrVideoCount) HDR videos will be exported in SDR.",
              comment:
                "The number of HDR input videos that export as SDR."
            )
          }
        } icon: {
          Image(systemName: "exclamationmark.triangle")
        }
        .font(.footnote)
        .foregroundStyle(.secondary)
      }
    }
    .padding(.vertical, 4)
  }

  private var summary: String {
    if session.isSettled {
      var parts: [String] = []
      if session.exportedCount > 0 {
        parts.append(
          String(
            localized: "\(session.exportedCount) exported",
            comment:
              "Export summary component. The variable is a video count."
          )
        )
      }
      if session.failedCount > 0 {
        parts.append(
          String(
            localized: "\(session.failedCount) failed",
            comment:
              "Export summary component. The variable is a video count."
          )
        )
      }
      if session.cancelledCount > 0 {
        parts.append(
          String(
            localized: "\(session.cancelledCount) cancelled",
            comment:
              "Export summary component. The variable is a video count."
          )
        )
      }
      return parts.joined(separator: " · ")
    }

    return String(
      localized:
        "\(session.settledCount) of \(session.items.count) finished",
      comment:
        "Export session progress. Variables are finished videos and total videos."
    )
  }

  @ViewBuilder
  private var executionNotice: some View {
    if session.foregroundFallbackCount > 0 {
      VStack(alignment: .leading, spacing: 5) {
        Label(
          "Keep Färg open",
          systemImage: "exclamationmark.triangle.fill"
        )
        .font(.footnote.weight(.semibold))
        .foregroundStyle(.red)

        if session.foregroundFallbackCount == 1 {
          Text("1 video must stay in the foreground.")
        } else {
          Text(
            "\(session.foregroundFallbackCount) videos must stay in the foreground.",
            comment:
              "Foreground fallback notice. The variable is a video count."
          )
        }

        if let error = firstForegroundError {
          Text(error.localizedDescription)
        }
      }
      .font(.caption)
      .foregroundStyle(.secondary)
      .padding(10)
      .background(
        .red.opacity(0.1),
        in: RoundedRectangle(cornerRadius: 10, style: .continuous)
      )
    } else if session.isSettled == false {
      Label(
        "You can leave the app while exports continue.",
        systemImage: "moon.zzz"
      )
      .font(.footnote)
      .foregroundStyle(.secondary)
    }
  }

  private var firstForegroundError: VideoExportBackgroundStartError? {
    for item in session.items {
      guard
        let attempt = item.attempt,
        case .foreground(let error) = attempt.path
      else {
        continue
      }
      return error
    }
    return nil
  }
}

/// One stable row whose state and actions belong to a single source video.
private struct ExportItemRow: View {

  let item: VideoExportItemModel
  let onCancel: @MainActor @Sendable () -> Void
  let onRetry: @MainActor @Sendable () -> Void
  let onSaveToPhotos: @MainActor @Sendable () -> Void

  var body: some View {
    HStack(alignment: .center, spacing: 12) {
      statusIcon
        .frame(width: 28, height: 28)
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 5) {
        Text(item.displayName)
          .font(.subheadline.weight(.medium))
          .lineLimit(1)

        status
          .font(.caption)
          .foregroundStyle(statusColor)
          .lineLimit(2)

        if let fraction = renderingFraction {
          ProgressView(value: fraction)
            .progressViewStyle(.linear)
            .accessibilityHidden(true)
        }
      }
      .accessibilityElement(children: .ignore)
      .accessibilityLabel(item.displayName)
      .accessibilityValue(accessibilityStatus)

      Spacer(minLength: 8)

      actions
    }
    .padding(.vertical, 5)
  }

  @ViewBuilder
  private var statusIcon: some View {
    switch item.state {
    case .queued:
      Image(systemName: "clock")
        .foregroundStyle(.secondary)

    case .attempting(let attempt):
      switch attempt.state {
      case .active(let active):
        switch active {
        case .waitingForRenderSlot, .preparingBackgroundRequest:
          Image(systemName: "clock")
            .foregroundStyle(.secondary)
        case .rendering:
          Image(systemName: "film")
            .foregroundStyle(.tint)
        case .savingToPhotos:
          ProgressView()
        }

      case .cancelling:
        ProgressView()

      case .finished(let finish):
        switch finish {
        case .exported:
          Image(systemName: "checkmark.circle.fill")
            .foregroundStyle(.green)
        case .failed:
          Image(systemName: "exclamationmark.circle.fill")
            .foregroundStyle(.orange)
        case .cancelled:
          Image(systemName: "xmark.circle.fill")
            .foregroundStyle(.secondary)
        }
      }
    }
  }

  @ViewBuilder
  private var status: some View {
    switch item.state {
    case .queued:
      Text("Waiting")

    case .attempting(let attempt):
      switch attempt.state {
      case .active(let active):
        switch active {
        case .waitingForRenderSlot:
          Text("Waiting for render slot")
        case .preparingBackgroundRequest:
          Text("Preparing background export…")
        case .rendering(_, let fraction):
          Text(
            "Exporting \(fraction, format: .percent.precision(.fractionLength(0)))"
          )
          .monospacedDigit()
        case .savingToPhotos:
          Text("Saving to Photos…")
        }

      case .cancelling:
        Text("Cancelling…")

      case .finished(let finish):
        switch finish {
        case .exported(_, _, let photos):
          switch photos {
          case .saved:
            Text("Saved to Photos")
          case .readyToSave(let message):
            if let message {
              Text(message)
            } else {
              Text("Ready to save")
            }
          case .saving:
            Text("Saving to Photos…")
          }

        case .failed(_, let message):
          Text(message)

        case .cancelled(_, let origin):
          switch origin {
          case .user:
            Text("Cancelled")
          case .system:
            Text("Stopped by the system")
          }
        }
      }
    }
  }

  private var statusColor: Color {
    guard let finish = item.finish else { return .secondary }
    switch finish {
    case .exported(_, _, let photos):
      switch photos {
      case .saved, .saving:
        return .secondary
      case .readyToSave:
        return .orange
      }
    case .failed:
      return .orange
    case .cancelled:
      return .secondary
    }
  }

  private var renderingFraction: Double? {
    guard
      let attempt = item.attempt,
      case .active(.rendering(_, let fraction)) = attempt.state
    else {
      return nil
    }
    return fraction
  }

  @ViewBuilder
  private var actions: some View {
    switch item.state {
    case .queued:
      EmptyView()

    case .attempting(let attempt):
      switch attempt.state {
      case .active:
        Button(action: onCancel) {
          Image(systemName: "stop.circle")
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Cancel \(item.displayName)")
        .accessibilityIdentifier("cancel-export-\(item.id.uuidString)")

      case .cancelling:
        EmptyView()

      case .finished(let finish):
        switch finish {
        case .exported(_, let url, let photos):
          HStack(spacing: 8) {
            switch photos {
            case .readyToSave:
              Button(action: onSaveToPhotos) {
                Image(systemName: "photo.badge.plus")
                  .frame(minWidth: 44, minHeight: 44)
                  .contentShape(Rectangle())
              }
              .buttonStyle(.borderless)
              .accessibilityLabel("Save \(item.displayName) to Photos")
              .accessibilityIdentifier(
                "save-export-\(item.id.uuidString)"
              )

            case .saving:
              ProgressView()
                .controlSize(.small)
                .frame(minWidth: 44, minHeight: 44)
                .accessibilityHidden(true)

            case .saved:
              EmptyView()
            }

            ShareLink(item: url) {
              Image(systemName: "square.and.arrow.up")
                .frame(minWidth: 44, minHeight: 44)
                .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Share \(item.displayName)")
            .accessibilityIdentifier(
              "share-export-\(item.id.uuidString)"
            )
          }

        case .failed, .cancelled:
          Button("Retry", action: onRetry)
            .frame(minWidth: 44, minHeight: 44)
            .contentShape(Rectangle())
            .buttonStyle(.borderless)
            .accessibilityLabel("Retry \(item.displayName)")
            .accessibilityIdentifier(
              "retry-export-\(item.id.uuidString)"
            )
        }
      }
    }
  }

  private var accessibilityStatus: String {
    switch item.state {
    case .queued:
      return String(localized: "Waiting")

    case .attempting(let attempt):
      switch attempt.state {
      case .active(let active):
        switch active {
        case .waitingForRenderSlot:
          return String(localized: "Waiting")
        case .preparingBackgroundRequest:
          return String(localized: "Preparing background export")
        case .rendering(_, let fraction):
          return String(
            localized:
              "Exporting \(Int(min(max(fraction, 0), 1) * 100)) percent",
            comment:
              "Export row accessibility status. The variable is a whole-number percentage."
          )
        case .savingToPhotos:
          return String(localized: "Saving to Photos")
        }

      case .cancelling:
        return String(localized: "Cancelling")

      case .finished(let finish):
        switch finish {
        case .exported(_, _, let photos):
          switch photos {
          case .saved:
            return String(localized: "Saved to Photos")
          case .readyToSave:
            return String(localized: "Ready to save")
          case .saving:
            return String(localized: "Saving to Photos")
          }
        case .failed(_, let message):
          return message
        case .cancelled(_, let origin):
          switch origin {
          case .user:
            return String(localized: "Cancelled")
          case .system:
            return String(localized: "Stopped by the system")
          }
        }
      }
    }
  }
}
