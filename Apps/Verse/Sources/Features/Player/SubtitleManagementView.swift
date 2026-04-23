//
//  SubtitleManagementView.swift
//  YouTubeSubtitle
//
//  Created by Claude on 2025/12/01.
//

import SwiftData
import SwiftUI
import UniformTypeIdentifiers

/// View for managing subtitles and playback options
struct SubtitleManagementView: View {
  let videoID: YouTubeContentID
  let subtitles: Subtitle?
  let localFileURL: URL?
  let playbackSource: PlaybackSource
  let onSubtitlesImported: (Subtitle) -> Void
  let onPlaybackSourceChange: (PlaybackSource) -> Void
  var onLocalVideoDeleted: (() -> Void)?
  var onTranscribe: (() -> Void)?
  var isTranscribing: Bool = false

  @State private var showExportSheet = false
  @State private var showImportPicker = false
  @State private var exportFormat: SubtitleFormat = .srt
  @State private var showDeleteConfirmation = false
  @State private var errorMessage: String?
  @State private var showError = false

  @Environment(\.modelContext) private var modelContext
  @Environment(VideoItemService.self) private var historyService

  var body: some View {
    Menu {
      // MARK: - Share
      Section {
        if let youtubeURL = URL(string: "https://www.youtube.com/watch?v=\(videoID)") {
          ShareLink(item: youtubeURL) {
            Label("Share YouTube URL", systemImage: "square.and.arrow.up")
          }
        }
      }

      // MARK: - Playback Source (only if local file exists)
      if localFileURL != nil {
        Section("Playback Source") {
          Button {
            onPlaybackSourceChange(.youtube)
          } label: {
            Label(
              "YouTube",
              systemImage: playbackSource == .youtube ? "checkmark" : "play.rectangle"
            )
          }

          Button {
            onPlaybackSourceChange(.local)
          } label: {
            Label(
              "Local File",
              systemImage: playbackSource == .local ? "checkmark" : "internaldrive"
            )
          }
        }

        // MARK: - Local Video Management
        Section("Local Video") {
          // Transcribe audio to subtitles
          Button {
            onTranscribe?()
          } label: {
            Label("Transcribe Audio", systemImage: "waveform.badge.mic")
          }
          .disabled(isTranscribing)

          Button(role: .destructive) {
            showDeleteConfirmation = true
          } label: {
            Label("Delete Local Video", systemImage: "trash")
          }
        }
      }

      // MARK: - Subtitle Management
      Section("Subtitles") {
        if subtitles != nil {
          // Export to file
          Button {
            showExportSheet = true
          } label: {
            Label("Export...", systemImage: "square.and.arrow.up")
          }
        }

        // Import from file
        Button {
          showImportPicker = true
        } label: {
          Label("Import Subtitle File...", systemImage: "doc.badge.plus")
        }
      }
    } label: {
      Image(systemName: "ellipsis.circle")
        .font(.system(size: 20))
    }
    .sheet(isPresented: $showExportSheet) {
      ExportSheetView(
        videoID: videoID,
        subtitles: subtitles,
        selectedFormat: $exportFormat
      )
    }
    .fileImporter(
      isPresented: $showImportPicker,
      allowedContentTypes: subtitleContentTypes,
      allowsMultipleSelection: false
    ) { result in
      handleImport(result)
    }
    .alert("Error", isPresented: $showError) {
      Button("OK", role: .cancel) {}
    } message: {
      Text(errorMessage ?? "Unknown error occurred")
    }
    .confirmationDialog(
      "Delete Local Video",
      isPresented: $showDeleteConfirmation,
      titleVisibility: .visible
    ) {
      Button("Delete", role: .destructive) {
        deleteLocalVideo()
      }
      Button("Cancel", role: .cancel) {}
    } message: {
      Text("This will delete the downloaded video file. You can re-download it later.")
    }
  }

  private var subtitleContentTypes: [UTType] {
    [
      UTType(filenameExtension: "srt") ?? .plainText,
      UTType(filenameExtension: "vtt") ?? .plainText,
      UTType(filenameExtension: "sbv") ?? .plainText,
      UTType(filenameExtension: "csv") ?? .commaSeparatedText,
      UTType(filenameExtension: "lrc") ?? .plainText,
      UTType(filenameExtension: "ttml") ?? .xml,
      .plainText
    ]
  }

  private func handleImport(_ result: Result<[URL], Error>) {
    switch result {
    case .success(let urls):
      guard let url = urls.first else { return }

      // Start accessing security-scoped resource
      guard url.startAccessingSecurityScopedResource() else {
        errorMessage = "Cannot access the file"
        showError = true
        return
      }

      defer { url.stopAccessingSecurityScopedResource() }

      do {
        let subtitles = try SubtitleAdapter.decode(from: url)
        onSubtitlesImported(subtitles)
      } catch {
        errorMessage = error.localizedDescription
        showError = true
      }

    case .failure(let error):
      errorMessage = error.localizedDescription
      showError = true
    }
  }

  private func deleteLocalVideo() {
    guard localFileURL != nil else { return }

    Task {
      do {
        // Find the history item
        guard let historyItem = try historyService.findItem(videoID: videoID) else {
          throw VideoItemError.itemNotFound
        }

        // Delete local video using service
        try historyService.deleteLocalVideo(for: historyItem)

        // Switch to YouTube playback if currently on local
        await MainActor.run {
          if playbackSource == .local {
            onPlaybackSourceChange(.youtube)
          }

          // Notify parent
          onLocalVideoDeleted?()
        }

      } catch {
        await MainActor.run {
          errorMessage = "Failed to delete video: \(error.localizedDescription)"
          showError = true
        }
      }
    }
  }
}

// MARK: - Export Sheet View

struct ExportSheetView: View {
  let videoID: YouTubeContentID
  let subtitles: Subtitle?
  @Binding var selectedFormat: SubtitleFormat

  @State private var showExporter = false
  @State private var exportContent = ""
  @Environment(\.dismiss) private var dismiss

  var body: some View {
    NavigationStack {
      Form {
        Section("Export Format") {
          Picker("Format", selection: $selectedFormat) {
            ForEach(SubtitleFormat.allCases) { format in
              Text(format.rawValue).tag(format)
            }
          }
          .pickerStyle(.menu)

          Text("File extension: .\(selectedFormat.fileExtension)")
            .font(.caption)
            .foregroundStyle(.secondary)
        }

        Section {
          Button("Export") {
            prepareExport()
          }
          .disabled(subtitles == nil)
        }
      }
      .navigationTitle("Export Subtitles")
      #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
      #endif
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Cancel") {
            dismiss()
          }
        }
      }
      .fileExporter(
        isPresented: $showExporter,
        document: SubtitleDocument(content: exportContent, format: selectedFormat),
        contentType: UTType(filenameExtension: selectedFormat.fileExtension) ?? .plainText,
        defaultFilename: "\(videoID).\(selectedFormat.fileExtension)"
      ) { result in
        switch result {
        case .success:
          dismiss()
        case .failure(let error):
          print("Export failed: \(error)")
        }
      }
    }
    #if os(macOS)
    .frame(minWidth: 300, minHeight: 200)
    #endif
  }

  private func prepareExport() {
    guard let subtitles else { return }

    do {
      exportContent = try SubtitleAdapter.encode(subtitles, format: selectedFormat)
      showExporter = true
    } catch {
      print("Failed to encode: \(error)")
    }
  }
}

// MARK: - Subtitle Document for Export

struct SubtitleDocument: FileDocument {
  static var readableContentTypes: [UTType] { [.plainText] }

  let content: String
  let format: SubtitleFormat

  init(content: String, format: SubtitleFormat) {
    self.content = content
    self.format = format
  }

  init(configuration: ReadConfiguration) throws {
    content = ""
    format = .srt
  }

  func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
    let data = content.data(using: .utf8) ?? Data()
    return FileWrapper(regularFileWithContents: data)
  }
}

#Preview {
  SubtitleManagementView(
    videoID: "test123",
    subtitles: nil,
    localFileURL: nil,
    playbackSource: .youtube,
    onSubtitlesImported: { _ in },
    onPlaybackSourceChange: { _ in }
  )
}
