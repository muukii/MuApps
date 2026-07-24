//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//

import AVKit
import PhotosUI
import SwiftUI

/// The single-screen editor: pick a video, choose a LUT, scrub intensity, export.
struct EditorView: View {

  let library: LUTLibrary
  @Bindable var editState: EditState

  @State private var preview = VideoPreviewModel()
  @State private var pickerItem: PhotosPickerItem?
  @State private var showLibrary = false
  @State private var exportRequest: ExportRequest?
  @State private var errorMessage: String?

  var body: some View {
    VStack(spacing: 0) {
      previewArea
        .frame(maxWidth: .infinity, maxHeight: .infinity)

      if editState.hasVideo {
        controlPanel
      }
    }
    .background(Color(.systemBackground))
    .toolbar { toolbarContent }
    .onChange(of: pickerItem) { _, item in loadPickedVideo(item) }
    .onChange(of: editState.videoSource) { _, _ in reloadPreview() }
    .onChange(of: editState.selectedLUT) { _, _ in applyComposition() }
    .onChange(of: editState.amount) { _, _ in applyComposition() }
    .sheet(isPresented: $showLibrary) {
      LUTLibraryView(library: library)
    }
    .sheet(item: $exportRequest) { request in
      ExportProgressView(request: request)
    }
    .alert(
      "Something went wrong",
      isPresented: Binding(
        get: { errorMessage != nil },
        set: { if $0 == false { errorMessage = nil } }
      ),
      presenting: errorMessage
    ) { _ in
      Button("OK", role: .cancel) {}
    } message: { message in
      Text(message)
    }
  }

  // MARK: - Preview

  @ViewBuilder
  private var previewArea: some View {
    ZStack {
      Color.black
      if editState.hasVideo {
        VideoPlayer(player: preview.player)
      } else {
        emptyState
      }
    }
  }

  private var emptyState: some View {
    VStack(spacing: 16) {
      Image(systemName: "film.stack")
        .font(.system(size: 56))
        .foregroundStyle(.white.opacity(0.5))
      Text("Choose a video to begin")
        .foregroundStyle(.white.opacity(0.8))
      PhotosPicker(selection: $pickerItem, matching: .videos) {
        Label("Choose Video", systemImage: "video.badge.plus")
          .padding(.horizontal, 8)
      }
      .buttonStyle(.borderedProminent)
    }
  }

  // MARK: - Controls

  private var controlPanel: some View {
    VStack(spacing: 16) {
      LUTStripView(library: library, selected: $editState.selectedLUT)

      HStack(spacing: 12) {
        Image(systemName: "circle.lefthalf.filled")
          .foregroundStyle(.secondary)
        Slider(value: $editState.amount, in: 0...1)
        Text(editState.amount, format: .percent.precision(.fractionLength(0)))
          .font(.callout.monospacedDigit())
          .frame(width: 44, alignment: .trailing)
      }
      .opacity(editState.selectedLUT == nil ? 0.4 : 1)
      .disabled(editState.selectedLUT == nil)

      Button(action: startExport) {
        Label("Export", systemImage: "square.and.arrow.up")
          .frame(maxWidth: .infinity)
      }
      .buttonStyle(.borderedProminent)
      .controlSize(.large)
    }
    .padding()
    .background(.bar)
  }

  @ToolbarContentBuilder
  private var toolbarContent: some ToolbarContent {
    ToolbarItemGroup(placement: .topBarTrailing) {
      Button {
        showLibrary = true
      } label: {
        Image(systemName: "swatchpalette")
      }
      .accessibilityLabel("LUT Library")

      if editState.hasVideo {
        PhotosPicker(selection: $pickerItem, matching: .videos) {
          Image(systemName: "video.badge.plus")
        }
        .accessibilityLabel("Change Video")
      }
    }
  }

  // MARK: - Actions

  private func loadPickedVideo(_ item: PhotosPickerItem?) {
    guard let item else { return }
    Task {
      do {
        if let movie = try await item.loadTransferable(type: PickedMovie.self) {
          let source = VideoSource(url: movie.url)
          editState.colorInfo = await VideoColorInfo.resolve(from: source.asset)
          editState.videoSource = source
        } else {
          errorMessage = "Couldn't load that video."
        }
      } catch {
        errorMessage = error.localizedDescription
      }
      pickerItem = nil
    }
  }

  private func reloadPreview() {
    guard let source = editState.videoSource else { return }
    preview.load(source)
    applyComposition()
  }

  private func applyComposition() {
    guard let source = editState.videoSource else { return }
    do {
      let document = try editState.makeDocument(using: library)
      preview.apply(document: document, for: source, colorInfo: editState.colorInfo)
    } catch {
      errorMessage = error.localizedDescription
    }
  }

  private func startExport() {
    guard let source = editState.videoSource else { return }
    do {
      let document = try editState.makeDocument(using: library)
      preview.pause()
      exportRequest = ExportRequest(
        asset: source.asset,
        document: document,
        colorInfo: editState.colorInfo ?? .sdrRec709
      )
    } catch {
      errorMessage = error.localizedDescription
    }
  }
}
