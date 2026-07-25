//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//

import FargMotionBlur
import Foundation
import PhotosUI
import SwiftUI

/// Authors one shared LUT recipe over an ordered collection of videos.
struct EditorView: View {

  let library: LUTLibrary
  @Bindable var editState: EditState
  let onShowSettings: @MainActor @Sendable () -> Void
  let onFinishEditing: @MainActor @Sendable () -> Void

  @State private var preview = VideoPreviewModel()
  @State private var lutPreviewModels = LUTPreviewModelStore()
  @State private var pickerItems: [PhotosPickerItem] = []
  @State private var exportBatch: VideoExportBatch?
  @State private var errorMessage: String?
  @State private var isDiscardConfirmationPresented = false
  @State private var videoLoadRequestID: UUID?
  @State private var videoLoadTask: Task<Void, Never>?

  var body: some View {
    EditorLayout(
      preview: preview,
      lutPreviewSource: preview.lutPreviewSource,
      clips: editState.clips,
      selectedClipID: editState.selectedClipID,
      hdrVideoCount: editState.hdrVideoCount,
      library: library,
      pickerItems: $pickerItems,
      selectedLUT: $editState.selectedLUT,
      amount: $editState.amount,
      motionBlur: $editState.motionBlur,
      onSelectClip: editState.selectClip,
      onRemoveClip: removeClip,
      onPickFileURLs: loadPickedVideoFiles
    )
    .environment(lutPreviewModels)
    .background(EditorPalette.chrome.ignoresSafeArea())
    .toolbar {
      EditorToolbarContent(
        canExport:
          editState.hasVideos
          && editState.isPreparingClips == false
          && preview.renderState == .ready,
        onRequestDiscard: { isDiscardConfirmationPresented = true },
        onShowSettings: onShowSettings,
        onExport: startExport
      )
    }
    .toolbarBackground(EditorPalette.chrome, for: .navigationBar)
    .toolbarBackground(.visible, for: .navigationBar)
    .toolbarColorScheme(.dark, for: .navigationBar)
    .onAppear {
      reloadPreview()
    }
    .onChange(of: pickerItems) { _, items in loadPickedPhotos(items) }
    .onChange(of: editState.selectedClip?.content?.source.id) { _, _ in
      reloadPreview()
    }
    .onChange(of: editState.selectedLUT) { _, _ in applyComposition() }
    .onChange(of: editState.amount) { _, _ in applyComposition() }
    .onChange(of: editState.motionBlur) { _, _ in applyComposition() }
    .onChange(of: preview.renderingErrorMessage) { _, message in
      if let message {
        errorMessage = message
      }
    }
    .onChange(of: preview.lutPreviewSource?.id, initial: true) { _, sourceID in
      lutPreviewModels.updateContext(
        LUTPreviewContextID(
          sourceID: sourceID,
          libraryRevision: library.revision
        )
      )
    }
    .onChange(of: library.revision, initial: true) { _, revision in
      lutPreviewModels.synchronize(lutIDs: library.luts.map(\.id))
      lutPreviewModels.updateContext(
        LUTPreviewContextID(
          sourceID: preview.lutPreviewSource?.id,
          libraryRevision: revision
        )
      )
    }
    .onChange(of: library.revision) { _, _ in reconcileSelectedLUT() }
    .sheet(
      item: $exportBatch,
      onDismiss: exportPresentationDidDismiss
    ) { batch in
      ExportProgressView(batch: batch)
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
    .confirmationDialog(
      "Discard edits?",
      isPresented: $isDiscardConfirmationPresented,
      titleVisibility: .visible
    ) {
      Button("Discard Edits", role: .destructive) {
        onFinishEditing()
      }
      Button("Keep Editing", role: .cancel) {}
    } message: {
      Text("Your video selection and LUT adjustments will be lost.")
    }
    .onDisappear(perform: viewDidDisappear)
  }

  // MARK: - Video Collection

  private func viewDidDisappear() {
    videoLoadTask?.cancel()
    if exportBatch == nil {
      // Navigation may retain this view's state briefly. Release the player
      // item now so its compositor, VideoToolbox session, and IOSurfaces do
      // not depend on SwiftUI's eventual state destruction.
      preview.clear()
    }
  }

  private func loadPickedPhotos(_ items: [PhotosPickerItem]) {
    guard items.isEmpty == false else { return }
    loadPickedVideos(photoItems: items, fileURLs: [])
  }

  private func loadPickedVideoFiles(_ fileURLs: [URL]) {
    guard fileURLs.isEmpty == false else { return }
    loadPickedVideos(photoItems: [], fileURLs: fileURLs)
  }

  private func loadPickedVideos(
    photoItems: [PhotosPickerItem],
    fileURLs: [URL]
  ) {
    videoLoadTask?.cancel()

    let selectedItems = photoItems
    let selectedFileURLs = fileURLs
    pickerItems = []
    let clips = VideoPickerImport.makeClips(
      photoItems: selectedItems,
      fileURLs: selectedFileURLs
    )
    let clipIDs = Set(clips.map(\.id))
    let requestID = UUID()
    videoLoadRequestID = requestID
    editState.append(clips: clips)

    videoLoadTask = Task {
      defer {
        if videoLoadRequestID == requestID {
          let unresolvedIDs = Set(
            clips.filter { $0.isReady == false }.map(\.id)
          )
          editState.removeClips(ids: unresolvedIDs)
          videoLoadRequestID = nil
          videoLoadTask = nil
        }
      }

      do {
        let result = try await VideoPickerImport.load(
          clips,
          requiresPhotoLibraryReadAccess: selectedItems.isEmpty == false
        )
        guard
          Task.isCancelled == false,
          videoLoadRequestID == requestID
        else {
          return
        }

        if let failureMessage = result.failureMessage {
          errorMessage = failureMessage
        }
      } catch is CancellationError {
        editState.removeClips(ids: clipIDs)
        return
      } catch {
        editState.removeClips(ids: clipIDs)
        errorMessage = error.localizedDescription
      }
    }
  }

  private func removeClip(id: VideoClip.ID) {
    editState.removeClip(id: id)
    if editState.hasVideos == false {
      preview.clear()
      onFinishEditing()
    }
  }

  // MARK: - Preview

  private func reloadPreview() {
    guard let content = editState.selectedClip?.content else {
      preview.clear()
      return
    }
    preview.load(content.source)
    applyComposition()
  }

  private func applyComposition() {
    guard let content = editState.selectedClip?.content else { return }
    do {
      let recipe = try editState.makeRenderRecipe(using: library)
      preview.apply(
        recipe: recipe,
        for: content.source,
        colorInfo: content.colorInfo
      )
    } catch {
      preview.failCurrentRender(error)
      errorMessage = error.localizedDescription
    }
  }

  /// Rebinds the selection to synchronized metadata or clears a removed LUT.
  private func reconcileSelectedLUT() {
    guard let selectedLUT = editState.selectedLUT else { return }
    editState.selectedLUT = library.lut(id: selectedLUT.id)
  }

  // MARK: - Export

  private func exportPresentationDidDismiss() {
    BackgroundExportCoordinator.shared.reset()
    if editState.hasVideos {
      preview.resumeRendering()
      applyComposition()
      preview.play()
    }
  }

  private func startExport() {
    guard
      editState.readyClips.isEmpty == false,
      editState.isPreparingClips == false
    else {
      return
    }
    do {
      let recipe = try editState.makeRenderRecipe(using: library)
      let items: [VideoExportBatch.Item] =
        editState.readyClips.enumerated().compactMap {
          index,
          clip -> VideoExportBatch.Item? in
          guard let content = clip.content else { return nil }
          return VideoExportBatch.Item(
            id: clip.id,
            displayName:
              content.displayName.isEmpty
              ? String(
                localized: "Video \(index + 1)",
                comment:
                  "Fallback export item name. The variable is its position."
              )
              : content.displayName,
            source: content.source,
            colorInfo: content.colorInfo
          )
        }
      preview.suspendRendering()
      exportBatch = VideoExportBatch(
        items: items,
        recipe: recipe
      )
    } catch {
      errorMessage = error.localizedDescription
    }
  }
}

/// Places the selected preview above or beside the shared batch inspector.
private struct EditorLayout: View {

  let preview: VideoPreviewModel
  let lutPreviewSource: LUTPreviewSourceImage?
  let clips: [VideoClip]
  let selectedClipID: VideoClip.ID?
  let hdrVideoCount: Int
  let library: LUTLibrary
  @Binding var pickerItems: [PhotosPickerItem]
  @Binding var selectedLUT: LUT?
  @Binding var amount: Double
  @Binding var motionBlur: MotionBlurSettings
  let onSelectClip: @MainActor @Sendable (VideoClip.ID) -> Void
  let onRemoveClip: @MainActor @Sendable (VideoClip.ID) -> Void
  let onPickFileURLs: @MainActor @Sendable ([URL]) -> Void

  var body: some View {
    VStack(spacing: 0) {
      EditorPreviewStage(preview: preview)
        .frame(
          minWidth: 0,
          maxWidth: .infinity,
          minHeight: 220,
          maxHeight: .infinity
        )
        .padding(16)

      controlPanel(placement: .bottom)
        .frame(maxHeight: 420)
    }
  }

  private func controlPanel(
    placement: EditorPanelPlacement
  ) -> some View {
    EditorControlPanel(
      placement: placement,
      clips: clips,
      selectedClipID: selectedClipID,
      hdrVideoCount: hdrVideoCount,
      library: library,
      lutPreviewSource: lutPreviewSource,
      pickerItems: $pickerItems,
      selectedLUT: $selectedLUT,
      amount: $amount,
      motionBlur: $motionBlur,
      onSelectClip: onSelectClip,
      onRemoveClip: onRemoveClip,
      onPickFileURLs: onPickFileURLs
    )
  }
}

/// Displays the live video for the editor's current nonempty collection.
private struct EditorPreviewStage: View {

  let preview: VideoPreviewModel

  var body: some View {
    EditorVideoPlayer(model: preview)
  }
}

/// The physical edge occupied by the editing inspector.
private enum EditorPanelPlacement {
  case bottom
  case trailing
}

/// Places video, look, intensity, and export information in the active panel.
private struct EditorControlPanel: View {

  let placement: EditorPanelPlacement
  let clips: [VideoClip]
  let selectedClipID: VideoClip.ID?
  let hdrVideoCount: Int
  let library: LUTLibrary
  let lutPreviewSource: LUTPreviewSourceImage?
  @Binding var pickerItems: [PhotosPickerItem]
  @Binding var selectedLUT: LUT?
  @Binding var amount: Double
  @Binding var motionBlur: MotionBlurSettings
  let onSelectClip: @MainActor @Sendable (VideoClip.ID) -> Void
  let onRemoveClip: @MainActor @Sendable (VideoClip.ID) -> Void
  let onPickFileURLs: @MainActor @Sendable ([URL]) -> Void

  var body: some View {
    switch placement {
    case .bottom:
      EditorControlPanelBody(
        contentPadding: 16,
        clips: clips,
        selectedClipID: selectedClipID,
        hdrVideoCount: hdrVideoCount,
        library: library,
        lutPreviewSource: lutPreviewSource,
        pickerItems: $pickerItems,
        selectedLUT: $selectedLUT,
        amount: $amount,
        motionBlur: $motionBlur,
        onSelectClip: onSelectClip,
        onRemoveClip: onRemoveClip,
        onPickFileURLs: onPickFileURLs
      )
      .background(EditorPalette.chrome)
      .overlay(alignment: .top) {
        Rectangle()
          .fill(EditorPalette.hairline)
          .frame(height: 1)
      }

    case .trailing:
      EditorControlPanelBody(
        contentPadding: 20,
        clips: clips,
        selectedClipID: selectedClipID,
        hdrVideoCount: hdrVideoCount,
        library: library,
        lutPreviewSource: lutPreviewSource,
        pickerItems: $pickerItems,
        selectedLUT: $selectedLUT,
        amount: $amount,
        motionBlur: $motionBlur,
        onSelectClip: onSelectClip,
        onRemoveClip: onRemoveClip,
        onPickFileURLs: onPickFileURLs
      )
      .background(EditorPalette.chrome)
      .overlay(alignment: .leading) {
        Rectangle()
          .fill(EditorPalette.hairline)
          .frame(width: 1)
      }
    }
  }
}

/// Scrolls the complete inspector after Export moves to the navigation bar.
private struct EditorControlPanelBody: View {

  let contentPadding: CGFloat
  let clips: [VideoClip]
  let selectedClipID: VideoClip.ID?
  let hdrVideoCount: Int
  let library: LUTLibrary
  let lutPreviewSource: LUTPreviewSourceImage?
  @Binding var pickerItems: [PhotosPickerItem]
  @Binding var selectedLUT: LUT?
  @Binding var amount: Double
  @Binding var motionBlur: MotionBlurSettings
  let onSelectClip: @MainActor @Sendable (VideoClip.ID) -> Void
  let onRemoveClip: @MainActor @Sendable (VideoClip.ID) -> Void
  let onPickFileURLs: @MainActor @Sendable ([URL]) -> Void

  var body: some View {
    ScrollView {
      EditorSharedControls(
        clips: clips,
        selectedClipID: selectedClipID,
        hdrVideoCount: hdrVideoCount,
        library: library,
        lutPreviewSource: lutPreviewSource,
        pickerItems: $pickerItems,
        selectedLUT: $selectedLUT,
        amount: $amount,
        motionBlur: $motionBlur,
        onSelectClip: onSelectClip,
        onRemoveClip: onRemoveClip,
        onPickFileURLs: onPickFileURLs
      )
      .padding(contentPadding)
    }
    .scrollBounceBehavior(.basedOnSize)
  }

  /// Orders the shared decisions and summarizes the toolbar export action.
  fileprivate struct EditorSharedControls: View {

    let clips: [VideoClip]
    let selectedClipID: VideoClip.ID?
    let hdrVideoCount: Int
    let library: LUTLibrary
    let lutPreviewSource: LUTPreviewSourceImage?
    @Binding var pickerItems: [PhotosPickerItem]
    @Binding var selectedLUT: LUT?
    @Binding var amount: Double
    @Binding var motionBlur: MotionBlurSettings
    let onSelectClip: @MainActor @Sendable (VideoClip.ID) -> Void
    let onRemoveClip: @MainActor @Sendable (VideoClip.ID) -> Void
    let onPickFileURLs: @MainActor @Sendable ([URL]) -> Void

    var body: some View {
      VStack(alignment: .leading, spacing: 18) {
        VideoBatchStripView(
          clips: clips,
          selectedClipID: selectedClipID,
          pickerItems: $pickerItems,
          onSelectClip: onSelectClip,
          onRemoveClip: onRemoveClip,
          onPickFileURLs: onPickFileURLs
        )

        EditorLookControls(
          library: library,
          lutPreviewSource: lutPreviewSource,
          selectedLUT: $selectedLUT
        )

        EditorMotionBlurControls(settings: $motionBlur)

        EditorExportSummary(
          videoCount: clips.count,
          hdrVideoCount: hdrVideoCount
        )
      }
    }
  }

  /// Names the shared look and exposes the library's quick selector.
  fileprivate struct EditorLookControls: View {

    let library: LUTLibrary
    let lutPreviewSource: LUTPreviewSourceImage?
    @Binding var selectedLUT: LUT?

    var body: some View {
      VStack(alignment: .leading, spacing: 10) {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
          Text("LOOK")
            .font(.caption.weight(.semibold))
            .tracking(0.8)
            .foregroundStyle(EditorPalette.secondary)
        }
        .font(.caption)
        .foregroundStyle(EditorPalette.primary)

        LUTStripView(
          library: library,
          source: lutPreviewSource,
          selected: $selectedLUT
        )
      }
    }
  }

  /// Exposes Apple's Optical Flow motion blur without presenting backend tuning
  /// as a physical shutter angle.
  fileprivate struct EditorMotionBlurControls: View {

    @Binding var settings: MotionBlurSettings
    var isSupported = MotionBlurAvailability.isSupported

    private var strength: Binding<Double> {
      Binding(
        get: { Double(settings.strength) },
        set: { settings.strength = Int($0.rounded()) }
      )
    }

    private var strengthRange: ClosedRange<Double> {
      Double(
        MotionBlurSettings.strengthRange.lowerBound
      )...Double(MotionBlurSettings.strengthRange.upperBound)
    }

    var body: some View {
      VStack(alignment: .leading, spacing: 10) {
        HStack(alignment: .center, spacing: 12) {
          VStack(alignment: .leading, spacing: 3) {
            Text("MOTION BLUR")
              .font(.caption.weight(.semibold))
              .tracking(0.8)
              .foregroundStyle(EditorPalette.secondary)

            Text("Optical Flow")
              .font(.caption2)
              .foregroundStyle(EditorPalette.secondary)
          }

          Spacer(minLength: 12)

          Toggle("Motion Blur", isOn: $settings.isEnabled)
            .labelsHidden()
            .tint(EditorPalette.primary)
            .disabled(isSupported == false)
            .accessibilityIdentifier("motion-blur-toggle")
        }

        if isSupported == false {
          Text(
            "Requires a supported iPhone. Optical Flow isn't available in Simulator."
          )
          .font(.caption)
          .foregroundStyle(EditorPalette.secondary)
        } else if settings.isEnabled {
          HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("Strength")
              .font(.caption)
              .foregroundStyle(EditorPalette.secondary)

            Spacer(minLength: 12)

            Text(settings.strength, format: .number)
              .font(.caption)
              .monospacedDigit()
              .foregroundStyle(EditorPalette.primary)
          }

          Slider(
            value: strength,
            in: strengthRange,
            step: 1
          )
          .tint(EditorPalette.primary)
          .accessibilityLabel("Motion blur strength")
          .accessibilityValue(settings.strength.formatted())
        } else {
          Text("Uses adjacent frames to create ND-like motion trails.")
            .font(.caption)
            .foregroundStyle(EditorPalette.secondary)
        }
      }
      .animation(.snappy, value: settings.isEnabled)
    }
  }

  /// Describes the number and format of independent outputs before rendering.
  fileprivate struct EditorExportSummary: View {

    let videoCount: Int
    let hdrVideoCount: Int

    var body: some View {
      VStack(alignment: .leading, spacing: 8) {
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
          .font(.caption)
          .foregroundStyle(.orange)
        }

        if videoCount == 1 {
          Text("HEVC  ·  Source resolution")
            .font(.caption)
            .foregroundStyle(EditorPalette.secondary)
        } else {
          Text(
            "HEVC  ·  Source resolution  ·  \(videoCount) separate files",
            comment:
              "Export format summary. The variable is the number of output files."
          )
          .font(.caption)
          .foregroundStyle(EditorPalette.secondary)
        }
      }
    }
  }
}

extension ShapeStyle where Self == Color {
  static var debug: Self {
    #if DEBUG
      return Color.red
    #else
      return Color.clear
    #endif
  }
}
/// Keeps close and Settings available beside navigation and Export as the primary action.
private struct EditorToolbarContent: ToolbarContent {

  let canExport: Bool
  /// Asks the owning editor to confirm that its transient work should be discarded.
  let onRequestDiscard: @MainActor @Sendable () -> Void
  let onShowSettings: @MainActor @Sendable () -> Void
  let onExport: @MainActor @Sendable () -> Void

  var body: some ToolbarContent {
    ToolbarItemGroup(placement: .topBarLeading) {
      Button(action: onRequestDiscard) {
        Image(systemName: "xmark")
          .foregroundStyle(EditorPalette.primary)
      }
      .accessibilityLabel("Close Editor")

      Button(action: onShowSettings) {
        Image(systemName: "gearshape")
          .foregroundStyle(EditorPalette.primary)
      }
      .accessibilityLabel("Settings")
    }

    ToolbarItem(placement: .topBarTrailing) {
      Button("Export", action: onExport)
        .fontWeight(.semibold)
        .foregroundStyle(EditorPalette.primary)
        .disabled(canExport == false)
        .accessibilityIdentifier("export-videos")
    }
  }
}

#Preview("Editor") {
  NavigationStack {
    EditorView(
      library: LUTLibrary(),
      editState: EditState(),
      onShowSettings: {},
      onFinishEditing: {}
    )
    .navigationTitle("Färg")
    .navigationBarTitleDisplayMode(.inline)
  }
}

#Preview("Motion Blur Controls") {
  @Previewable @State var settings = MotionBlurSettings(
    isEnabled: true,
    strength: 50
  )

  EditorControlPanelBody.EditorMotionBlurControls(
    settings: $settings,
    isSupported: true
  )
  .padding(20)
  .background(EditorPalette.chrome)
}
