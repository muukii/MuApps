//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//

import AVFoundation
import BrightroomParametric
import SwiftUI

/// A self-contained export request handed to `ExportProgressView`.
struct ExportRequest: Identifiable {
  let id = UUID()
  let asset: AVURLAsset
  let document: EditingDocument
  let colorInfo: VideoColorInfo
}

/// Drives an export via `BackgroundExportCoordinator` (iOS 26 continued
/// processing, with a foreground fallback), shows progress, then offers
/// Share / Save-to-Photos.
struct ExportProgressView: View {

  let request: ExportRequest

  @Environment(\.dismiss) private var dismiss
  private let coordinator = BackgroundExportCoordinator.shared

  @State private var manualSave: SavePhase = .idle

  private enum SavePhase: Equatable {
    case idle
    case saving
    case saved
    case failed(String)
  }

  var body: some View {
    NavigationStack {
      VStack(spacing: 24) {
        content
        Spacer()
      }
      .padding()
      .navigationTitle("Export")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button(isFinished ? "Done" : "Cancel") {
            coordinator.reset()
            dismiss()
          }
        }
      }
      .onAppear {
        coordinator.start(
          asset: request.asset,
          document: request.document,
          colorInfo: request.colorInfo
        )
      }
    }
    .interactiveDismissDisabled(isExporting)
  }

  @ViewBuilder
  private var content: some View {
    switch coordinator.phase {
    case .idle, .exporting:
      VStack(spacing: 16) {
        ProgressView(value: progressValue) {
          Text("Exporting…")
        }
        .progressViewStyle(.linear)
        Text(progressValue, format: .percent.precision(.fractionLength(0)))
          .font(.largeTitle.monospacedDigit().weight(.semibold))
        Label(backgroundMessage, systemImage: coordinator.isBackgroundExport ? "moon.zzz" : "iphone")
          .font(.footnote)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
        if request.colorInfo.isHDR {
          Label("This HDR video is exported in SDR.", systemImage: "exclamationmark.triangle")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
        }
      }
      .padding(.top, 32)

    case .finished(let url, let savedToPhotos):
      finishedView(url: url, savedToPhotos: savedToPhotos)

    case .failed(let message):
      VStack(spacing: 16) {
        Image(systemName: "exclamationmark.triangle")
          .font(.system(size: 44))
          .foregroundStyle(.orange)
        Text("Export failed").font(.headline)
        Text(message)
          .font(.callout)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
      }
      .padding(.top, 32)
    }
  }

  private func finishedView(url: URL, savedToPhotos: Bool) -> some View {
    VStack(spacing: 20) {
      Image(systemName: "checkmark.circle.fill")
        .font(.system(size: 56))
        .foregroundStyle(.green)
      Text("Export complete").font(.headline)

      ShareLink(item: url) {
        Label("Share", systemImage: "square.and.arrow.up")
          .frame(maxWidth: .infinity)
      }
      .buttonStyle(.bordered)
      .controlSize(.large)

      if savedToPhotos || manualSave == .saved {
        Label("Saved to Photos", systemImage: "checkmark")
          .foregroundStyle(.secondary)
      } else {
        Button {
          save(url: url)
        } label: {
          HStack {
            if manualSave == .saving { ProgressView() }
            Label("Save to Photos", systemImage: "photo.badge.plus")
          }
          .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        .disabled(manualSave == .saving)
      }

      if case .failed(let message) = manualSave {
        Text(message).font(.caption).foregroundStyle(.red)
      }
    }
    .padding(.top, 24)
  }

  private var progressValue: Double {
    switch coordinator.phase {
    case .exporting(let value): return value
    case .finished: return 1
    default: return 0
    }
  }

  private var isExporting: Bool {
    if case .exporting = coordinator.phase { return true }
    return false
  }

  private var isFinished: Bool {
    switch coordinator.phase {
    case .finished, .failed: return true
    default: return false
    }
  }

  private var backgroundMessage: String {
    coordinator.isBackgroundExport
      ? "You can leave the app — it keeps exporting in the background."
      : "Keep the app open while exporting."
  }

  private func save(url: URL) {
    manualSave = .saving
    Task {
      do {
        try await PhotoLibrarySaver.save(videoAt: url)
        manualSave = .saved
      } catch {
        manualSave = .failed(error.localizedDescription)
      }
    }
  }
}
