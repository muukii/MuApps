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
  let previewSamples: LUTPreviewSampleLibrary
  @Bindable var editState: EditState
  let onFinishEditing: @MainActor @Sendable () -> Void

  @State private var preview = VideoPreviewModel()
  @State private var lutPreviewModels = LUTPreviewModelStore()
  @State private var pickerItems: [PhotosPickerItem] = []
  @State private var isSettingsPresented = false
  @State private var exportSession: VideoExportSessionModel?
  @State private var errorMessage: String?
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
      motionBlur: $editState.motionBlur,
      onSelectClip: editState.selectClip,
      onRemoveClip: removeClip,
      onPickFileURLs: loadPickedVideoFiles
    )
    .environment(lutPreviewModels)
    .background(.background.secondary)
    .toolbar {
      EditorToolbarContent(
        canExport:
          editState.hasVideos
          && editState.isPreparingClips == false
          && preview.renderState == .ready,
        onDiscard: onFinishEditing,
        onShowSettings: { isSettingsPresented = true },
        onExport: startExport
      )
    }
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
    .sheet(isPresented: $isSettingsPresented) {
      FargSettingsView(
        library: library,
        previewSamples: previewSamples
      )
      .tint(.accentColor)
    }
    .sheet(
      item: $exportSession,
      onDismiss: exportPresentationDidDismiss
    ) { session in
      ExportProgressView(session: session)
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
    .onDisappear(perform: viewDidDisappear)
  }

  // MARK: - Video Collection

  private func viewDidDisappear() {
    videoLoadTask?.cancel()
    if exportSession == nil {
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
    Task {
      // Parent-driven sheet removal is rare, but it must still drain media work
      // before rebuilding the editor's preview pipeline.
      await BackgroundExportCoordinator.shared
        .cancelAndDiscardCurrentSession()
      if editState.hasVideos {
        preview.resumeRendering()
        applyComposition()
        preview.play()
      }
    }
  }

  private func startExport() {
    guard
      exportSession == nil,
      editState.readyClips.isEmpty == false,
      editState.isPreparingClips == false
    else {
      return
    }
    do {
      let recipe = try editState.makeRenderRecipe(using: library)
      let items: [VideoExportSessionItem] =
        editState.readyClips.enumerated().compactMap {
          index,
          clip -> VideoExportSessionItem? in
          guard let content = clip.content else { return nil }
          return VideoExportSessionItem(
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
      let session = VideoExportSessionModel(
        items: items,
        recipe: recipe
      )
      // Background leases must be registered and submitted as part of this
      // foreground user action, before presenting the progress sheet.
      guard BackgroundExportCoordinator.shared.start(session: session) else {
        preview.resumeRendering()
        applyComposition()
        preview.play()
        errorMessage = String(
          localized: "Another export session is still active."
        )
        return
      }
      exportSession = session
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

      EditorLowerPanel(
        clips: clips,
        selectedClipID: selectedClipID,
        hdrVideoCount: hdrVideoCount,
        library: library,
        lutPreviewSource: lutPreviewSource,
        pickerItems: $pickerItems,
        selectedLUT: $selectedLUT,
        motionBlur: $motionBlur,
        onSelectClip: onSelectClip,
        onRemoveClip: onRemoveClip,
        onPickFileURLs: onPickFileURLs
      )
      .frame(maxHeight: 420)
    }
  }
}

/// Displays the live video for the editor's current nonempty collection.
private struct EditorPreviewStage: View {

  let preview: VideoPreviewModel

  var body: some View {
    EditorVideoPlayer(model: preview)
  }
}

/// The effect editor displayed below the shared video collection.
private enum EditorEffectTab {
  case lut
  case motionBlur

  var isLUT: Bool {
    switch self {
    case .lut:
      return true
    case .motionBlur:
      return false
    }
  }

  var isMotionBlur: Bool {
    switch self {
    case .lut:
      return false
    case .motionBlur:
      return true
    }
  }
}

/// Separates the fixed video collection from the scrollable edit controls.
private struct EditorLowerPanel: View {

  let clips: [VideoClip]
  let selectedClipID: VideoClip.ID?
  let hdrVideoCount: Int
  let library: LUTLibrary
  let lutPreviewSource: LUTPreviewSourceImage?
  @Binding var pickerItems: [PhotosPickerItem]
  @Binding var selectedLUT: LUT?
  @Binding var motionBlur: MotionBlurSettings
  let onSelectClip: @MainActor @Sendable (VideoClip.ID) -> Void
  let onRemoveClip: @MainActor @Sendable (VideoClip.ID) -> Void
  let onPickFileURLs: @MainActor @Sendable ([URL]) -> Void

  var body: some View {
    EditorLowerPanelContent(
      contentPadding: 16,
      clips: clips,
      selectedClipID: selectedClipID,
      hdrVideoCount: hdrVideoCount,
      library: library,
      lutPreviewSource: lutPreviewSource,
      pickerItems: $pickerItems,
      selectedLUT: $selectedLUT,
      motionBlur: $motionBlur,
      onSelectClip: onSelectClip,
      onRemoveClip: onRemoveClip,
      onPickFileURLs: onPickFileURLs
    )
    .background(.background)   
  }
  
  /// Composes Videos and EditControl as independent siblings.
  private struct EditorLowerPanelContent: View {

    let contentPadding: CGFloat
    let clips: [VideoClip]
    let selectedClipID: VideoClip.ID?
    let hdrVideoCount: Int
    let library: LUTLibrary
    let lutPreviewSource: LUTPreviewSourceImage?
    @Binding var pickerItems: [PhotosPickerItem]
    @Binding var selectedLUT: LUT?
    @Binding var motionBlur: MotionBlurSettings
    let onSelectClip: @MainActor @Sendable (VideoClip.ID) -> Void
    let onRemoveClip: @MainActor @Sendable (VideoClip.ID) -> Void
    let onPickFileURLs: @MainActor @Sendable ([URL]) -> Void

    var body: some View {
      VStack(spacing: 0) {
        VideoBatchStripView(
          contentPadding: contentPadding,
          clips: clips,
          selectedClipID: selectedClipID,
          pickerItems: $pickerItems,
          onSelectClip: onSelectClip,
          onRemoveClip: onRemoveClip,
          onPickFileURLs: onPickFileURLs
        )
        .padding(.vertical, contentPadding)

        EditorEditControl(
          contentPadding: contentPadding,
          videoCount: clips.count,
          hdrVideoCount: hdrVideoCount,
          library: library,
          lutPreviewSource: lutPreviewSource,
          selectedLUT: $selectedLUT,
          motionBlur: $motionBlur
        )
      }
    }
  }

  
  /// Owns the LUT and Motion Blur tabs below the fixed video collection.
  private struct EditorEditControl: View {

    let contentPadding: CGFloat
    let videoCount: Int
    let hdrVideoCount: Int
    let library: LUTLibrary
    let lutPreviewSource: LUTPreviewSourceImage?
    @Binding var selectedLUT: LUT?
    @Binding var motionBlur: MotionBlurSettings

    @State private var selectedEffect: EditorEffectTab = .lut

    var body: some View {
      VStack(spacing: 0) {
        ScrollView {
          EditorControlContent(
            contentPadding: contentPadding,
            selectedEffect: selectedEffect,
            videoCount: videoCount,
            hdrVideoCount: hdrVideoCount,
            library: library,
            lutPreviewSource: lutPreviewSource,
            selectedLUT: $selectedLUT,
            motionBlur: $motionBlur
          )
          .padding(.vertical, contentPadding)
        }
        .scrollBounceBehavior(.basedOnSize)

        EditorEffectTabBar(selection: $selectedEffect)
      }
    }

    /// Keeps effect selection reachable while the active controls scroll above it.
    private struct EditorEffectTabBar: View {

      @Binding var selection: EditorEffectTab

      var body: some View {
        ScrollView(.horizontal) {
          HStack(spacing: 16) {
            EditorEffectTabButton(
              title: "LUT",
              systemImage: "camera.filters",
              accessibilityIdentifier: "editor-effect-tab-lut",
              isSelected: selection.isLUT
            ) {
              selection = .lut
            }
            
            EditorEffectTabButton(
              title: "Motion",
              systemImage: "wind",
              accessibilityIdentifier: "editor-effect-tab-motion-blur",
              isSelected: selection.isMotionBlur
            ) {
              selection = .motionBlur
            }
          }
        }
        .defaultScrollAnchor(.center)
        .frame(height: 64)
        .background(.background)  
      }
      
      /// Represents one accessible effect mode in the editor's persistent tab bar.
      private struct EditorEffectTabButton: View {

        let title: LocalizedStringResource
        let systemImage: String
        let accessibilityIdentifier: String
        let isSelected: Bool
        let action: @MainActor @Sendable () -> Void

        var body: some View {
          Button(action: action) {
            VStack(spacing: 6) {
              Image(systemName: systemImage)
                .font(.body)
                .symbolVariant(isSelected ? .fill : .none)

              Text(title)
                .font(.caption.weight(isSelected ? .semibold : .regular))
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .contentShape(Rectangle())
          }
          .buttonStyle(.plain)
          .accessibilityLabel(title)
          .foregroundStyle(
            isSelected ? Color.primary : Color.secondary
          )
          .overlay(alignment: .bottom) {
            Circle()
              .fill(.primary)
              .frame(width: 4, height: 4)
              .padding(.bottom, 5)
              .opacity(isSelected ? 1 : 0)
          }
          .accessibilityAddTraits(isSelected ? .isSelected : [])
          .accessibilityIdentifier(accessibilityIdentifier)
        }
      }

    }

    /// Orders effect-specific controls and the shared export summary.
    fileprivate struct EditorControlContent: View {

      let contentPadding: CGFloat
      let selectedEffect: EditorEffectTab
      let videoCount: Int
      let hdrVideoCount: Int
      let library: LUTLibrary
      let lutPreviewSource: LUTPreviewSourceImage?
      @Binding var selectedLUT: LUT?
      @Binding var motionBlur: MotionBlurSettings
      
      var body: some View {
        ZStack(alignment: .topLeading) {
          switch selectedEffect {
          case .lut:
            EditorLookControls(
              contentPadding: contentPadding,
              library: library,
              lutPreviewSource: lutPreviewSource,
              selectedLUT: $selectedLUT
            )
            .transition(.opacity)

          case .motionBlur:
            EditorMotionBlurControls(settings: $motionBlur)
              .padding(.horizontal, contentPadding)
              .transition(.opacity)
          }
        }
        .frame(
          maxWidth: .infinity,
          minHeight: 154,
          alignment: .topLeading
        )
        .animation(.snappy, value: selectedEffect)
      }
    }

    /// Names the shared look and exposes the library's quick selector.
    fileprivate struct EditorLookControls: View {

      let contentPadding: CGFloat
      let library: LUTLibrary
      let lutPreviewSource: LUTPreviewSourceImage?
      @Binding var selectedLUT: LUT?

      var body: some View {
        VStack(alignment: .leading, spacing: 10) {
          LUTStripView(
            contentPadding: contentPadding,
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
                .foregroundStyle(.secondary)

              Text("Optical Flow")
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            Toggle("Motion Blur", isOn: $settings.isEnabled)
              .labelsHidden()
              .tint(.primary)
              .disabled(isSupported == false)
              .accessibilityIdentifier("motion-blur-toggle")
          }

          if isSupported == false {
            Text(
              "Requires a supported iPhone. Optical Flow isn't available in Simulator."
            )
            .font(.caption)
            .foregroundStyle(.secondary)
          } else if settings.isEnabled {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
              Text("Strength")
                .font(.caption)
                .foregroundStyle(.secondary)

              Spacer(minLength: 12)

              Text(settings.strength, format: .number)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.primary)
            }

            Slider(
              value: strength,
              in: strengthRange,
              step: 1
            )
            .tint(.primary)
            .accessibilityLabel("Motion blur strength")
            .accessibilityValue(settings.strength.formatted())
          } else {
            Text("Uses adjacent frames to create ND-like motion trails.")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }
        .animation(.snappy, value: settings.isEnabled)
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
  /// Finishes the editor after the user selects the destructive discard action.
  let onDiscard: @MainActor @Sendable () -> Void
  let onShowSettings: @MainActor @Sendable () -> Void
  let onExport: @MainActor @Sendable () -> Void

  var body: some ToolbarContent {
    ToolbarItem(placement: .topBarLeading) {
      Menu {
        Button("Discard Edits", role: .destructive, action: onDiscard)
      } label: {
        Image(systemName: "xmark")
      }
      .accessibilityLabel("Close Editor")
      .accessibilityIdentifier("discard-editor-edits")
    }

    ToolbarSpacer(.fixed, placement: .topBarLeading)

    ToolbarItem(placement: .topBarLeading) {
      Button(action: onShowSettings) {
        Image(systemName: "gearshape")
      }
      .accessibilityLabel("Settings")
    }

    ToolbarItem(placement: .topBarTrailing) {
      Button(
        action: onExport,
        label: {
          Image(systemName: "square.and.arrow.up")
        }
      )
      .disabled(canExport == false)
      .accessibilityIdentifier("export-videos")
    }
  }
}

#Preview("Editor") {
  NavigationStack {
    EditorView(
      library: LUTLibrary(),
      previewSamples: LUTPreviewSampleLibrary(),
      editState: EditState(),
      onFinishEditing: {}
    )
    .navigationBarTitleDisplayMode(.inline)
  }
}
