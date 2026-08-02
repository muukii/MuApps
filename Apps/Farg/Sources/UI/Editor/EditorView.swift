//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//

import FargMotionBlur
import Foundation
import Photos
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Authors one shared LUT recipe over an ordered collection of videos.
struct EditorView: View {

  @Environment(\.displayScale) private var displayScale

  let library: LUTLibrary
  let defaultVideoFolder: DefaultVideoFolderStore
  let previewSamples: LUTPreviewSampleLibrary
  @Bindable var editState: EditState
  let onFinishEditing: @MainActor @Sendable () -> Void

  @State private var preview = VideoPreviewModel()
  @State private var lutPreviewModels = LUTPreviewModelStore()
  @State private var pickerItems: [PhotosPickerItem] = []
  @State private var isPhotosPickerPresented = false
  @State private var isVideoFileImporterPresented = false
  @State private var defaultVideoFolderAccess: DefaultVideoFolderAccess?
  @State private var isSettingsPresented = false
  @State private var videoInformationPresentation: VideoInformationPresentation?
  @State private var selectedEffect: EditorEffectTab = .lut
  @State private var exportSession: VideoExportSessionModel?
  @State private var errorMessage: String?
  @State private var videoLoadRequestID: UUID?
  @State private var videoLoadTask: Task<Void, Never>?

  private var isErrorPresented: Binding<Bool> {
    Binding(
      get: { errorMessage != nil },
      set: { isPresented in
        if isPresented == false {
          errorMessage = nil
        }
      }
    )
  }

  /// The stable content size of the Editor's hosting window.
  ///
  /// Unlike the player surface, this does not shrink when LUT and Motion Blur
  /// controls change height. It is therefore safe to use as a Preview-quality
  /// input without coupling the compositor to tab animation.
  private nonisolated struct EditorWindowMeasurement: Equatable, Sendable {
    let sizeInPoints: CGSize
    let displayScale: CGFloat
  }

  var body: some View {
    let currentDisplayScale = displayScale

    EditorLayout(
      preview: preview,
      lutPreviewSource: preview.lutPreviewSource,
      clips: editState.clips,
      selectedClipID: editState.selectedClipID,
      hdrVideoCount: editState.hdrVideoCount,
      library: library,
      selectedLUT: $editState.selectedLUT,
      exposure: $editState.exposure,
      motionBlur: $editState.motionBlur,
      grain: $editState.grain,
      selectedEffect: $selectedEffect,
      onSelectClip: editState.selectClip,
      onRemoveClip: removeClip,
      onSelectPhotos: { isPhotosPickerPresented = true },
      onSelectFiles: presentVideoFileImporter
    )
    .onGeometryChange(for: EditorWindowMeasurement.self) { proxy in
      EditorWindowMeasurement(
        sizeInPoints: proxy.size,
        displayScale: currentDisplayScale
      )
    } action: { measurement in
      preview.updateEditorWindow(
        sizeInPoints: measurement.sizeInPoints,
        displayScale: measurement.displayScale
      )
    }
    .environment(lutPreviewModels)
    .background(
      Rectangle()
        .foregroundStyle(.background.secondary)
        .ignoresSafeArea()
    )
    .toolbar {
      EditorToolbarContent(
        canExport:
          editState.hasVideos
          && editState.isPreparingClips == false
          && preview.renderState == .ready,
        canShowVideoInformation: editState.selectedClip?.content != nil,
        onDiscard: onFinishEditing,
        onShowSettings: { isSettingsPresented = true },
        onShowVideoInformation: showSelectedVideoInformation,
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
    .onChange(of: editState.exposure) { _, _ in
      applyComposition(change: .parametricDocument)
      updateLUTPreviewContext()
    }
    .onChange(of: editState.motionBlur) { _, _ in
      applyComposition(change: .motionBlur)
    }
    .onChange(of: editState.grain) { _, _ in
      applyComposition(change: .parametricDocument)
    }
    .onChange(of: preview.renderingErrorMessage) { _, message in
      if let message {
        errorMessage = message
      }
    }
    .onChange(of: preview.lutPreviewSource?.id, initial: true) { _, _ in
      updateLUTPreviewContext()
    }
    .onChange(of: library.revision, initial: true) { _, _ in
      lutPreviewModels.synchronize(lutIDs: library.luts.map(\.id))
      updateLUTPreviewContext()
    }
    .onChange(of: library.revision) { _, _ in reconcileSelectedLUT() }
    .sheet(isPresented: $isSettingsPresented) {
      FargSettingsView(
        library: library,
        defaultVideoFolder: defaultVideoFolder,
        previewSamples: previewSamples
      )
      .tint(.accentColor)
    }
    .sheet(item: $videoInformationPresentation) { presentation in
      VideoInformationView(
        displayName: presentation.content.displayName,
        source: presentation.content.source
      )
    }
    .sheet(
      item: $exportSession,
      onDismiss: exportPresentationDidDismiss
    ) { session in
      ExportProgressView(session: session)
    }
    .photosPicker(
      isPresented: $isPhotosPickerPresented,
      selection: $pickerItems,
      selectionBehavior: .ordered,
      matching: .videos,
      photoLibrary: .shared()
    )
    .fileImporter(
      isPresented: $isVideoFileImporterPresented,
      allowedContentTypes: [.movie],
      allowsMultipleSelection: true
    ) { result in
      switch result {
      case .success(let fileURLs):
        loadPickedVideoFiles(fileURLs)
      case .failure(let error):
        if (error as? CocoaError)?.code != .userCancelled {
          errorMessage = error.localizedDescription
        }
      }
    }
    .fileDialogDefaultDirectory(defaultVideoFolderAccess?.url)
    .alert(
      "Something went wrong",
      isPresented: isErrorPresented,
      presenting: errorMessage
    ) { _ in
      Button("OK", role: .cancel) {}
    } message: { message in
      Text(message)
    }
    .onChange(of: isVideoFileImporterPresented) { _, isPresented in
      if isPresented == false {
        defaultVideoFolderAccess = nil
      }
    }
    .onDisappear(perform: viewDidDisappear)
  }

  // MARK: - Video Collection

  private func viewDidDisappear() {
    videoLoadTask?.cancel()
    defaultVideoFolderAccess = nil
    if exportSession == nil {
      // Navigation may retain this view's state briefly. Release the player
      // item now so its compositor, VideoToolbox session, and IOSurfaces do
      // not depend on SwiftUI's eventual state destruction.
      preview.clear()
    }
  }

  /// Opens Files at the registered video folder when its storage is available.
  private func presentVideoFileImporter() {
    defaultVideoFolderAccess = defaultVideoFolder.makeAccess()
    isVideoFileImporterPresented = true
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

  private func showSelectedVideoInformation() {
    guard let clip = editState.selectedClip, let content = clip.content else {
      return
    }
    videoInformationPresentation = VideoInformationPresentation(
      id: clip.id,
      content: content
    )
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

  private func applyComposition(
    change: VideoPreviewRecipeChange = .complete
  ) {
    guard let content = editState.selectedClip?.content else { return }
    do {
      let recipe = try editState.makeRenderRecipe(using: library)
      preview.apply(
        recipe: recipe,
        for: content.source,
        colorInfo: content.colorInfo,
        change: change
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

  /// Invalidates editor LUT stills when their source, bytes, or exposure changes.
  private func updateLUTPreviewContext() {
    lutPreviewModels.updateContext(
      LUTPreviewContextID(
        sourceID: preview.lutPreviewSource?.id,
        libraryRevision: library.revision,
        exposureEV: editState.exposure.ev
      )
    )
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

/// Freezes the selected clip at the moment its Information button is pressed.
private struct VideoInformationPresentation: Identifiable {
  let id: VideoClip.ID
  let content: VideoClip.Content
}

/// Places the selected preview above or beside the shared batch inspector.
private struct EditorLayout: View {

  let preview: VideoPreviewModel
  let lutPreviewSource: LUTPreviewSourceImage?
  let clips: [VideoClip]
  let selectedClipID: VideoClip.ID?
  let hdrVideoCount: Int
  let library: LUTLibrary
  @Binding var selectedLUT: LUT?
  @Binding var exposure: ExposureAdjustment
  @Binding var motionBlur: MotionBlurSettings
  @Binding var grain: FilmGrainFeature
  @Binding var selectedEffect: EditorEffectTab
  let onSelectClip: @MainActor @Sendable (VideoClip.ID) -> Void
  let onRemoveClip: @MainActor @Sendable (VideoClip.ID) -> Void
  let onSelectPhotos: @MainActor @Sendable () -> Void
  let onSelectFiles: @MainActor @Sendable () -> Void
  
  var body: some View {
    VStack(spacing: 0) {

      EditorPreviewStage(preview: preview)
        .frame(
          minWidth: 0,
          maxWidth: .infinity,
          minHeight: 120,
          maxHeight: .infinity
        )
        .padding(16)

      EditorLowerPanel(
        clips: clips,
        selectedClipID: selectedClipID,
        hdrVideoCount: hdrVideoCount,
        library: library,
        lutPreviewSource: lutPreviewSource,
        selectedLUT: $selectedLUT,
        exposure: $exposure,
        motionBlur: $motionBlur,
        grain: $grain,
        selectedEffect: $selectedEffect,
        onSelectClip: onSelectClip,
        onRemoveClip: onRemoveClip,
        onSelectPhotos: onSelectPhotos,
        onSelectFiles: onSelectFiles
      )     
      .fixedSize(horizontal: false, vertical: true)
    }
    .animation(.smooth, value: UUID()) // TODO: should be better. To animate all container its content changes.
    .background(
      Rectangle()
        .foregroundStyle(.background)
    )
    .clipShape(
      RoundedRectangle(cornerRadius: 34)
    )
    .padding(4)
    .safeAreaInset(edge: .bottom) {
      EditorEffectTabBar(selection: $selectedEffect)
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

/// Separates the fixed video collection from the scrollable edit controls.
private struct EditorLowerPanel: View {

  let clips: [VideoClip]
  let selectedClipID: VideoClip.ID?
  let hdrVideoCount: Int
  let library: LUTLibrary
  let lutPreviewSource: LUTPreviewSourceImage?
  @Binding var selectedLUT: LUT?
  @Binding var exposure: ExposureAdjustment
  @Binding var motionBlur: MotionBlurSettings
  @Binding var grain: FilmGrainFeature
  @Binding var selectedEffect: EditorEffectTab
  let onSelectClip: @MainActor @Sendable (VideoClip.ID) -> Void
  let onRemoveClip: @MainActor @Sendable (VideoClip.ID) -> Void
  let onSelectPhotos: @MainActor @Sendable () -> Void
  let onSelectFiles: @MainActor @Sendable () -> Void

  var body: some View {
    EditorLowerPanelContent(
      contentPadding: 16,
      clips: clips,
      selectedClipID: selectedClipID,
      hdrVideoCount: hdrVideoCount,
      library: library,
      lutPreviewSource: lutPreviewSource,
      selectedLUT: $selectedLUT,
      exposure: $exposure,
      motionBlur: $motionBlur,
      grain: $grain,
      selectedEffect: $selectedEffect,
      onSelectClip: onSelectClip,
      onRemoveClip: onRemoveClip,
      onSelectPhotos: onSelectPhotos,
      onSelectFiles: onSelectFiles
    )
  }

  /// Composes Videos and EditControl as independent siblings.
  private struct EditorLowerPanelContent: View {

    let contentPadding: CGFloat
    let clips: [VideoClip]
    let selectedClipID: VideoClip.ID?
    let hdrVideoCount: Int
    let library: LUTLibrary
    let lutPreviewSource: LUTPreviewSourceImage?
    @Binding var selectedLUT: LUT?
    @Binding var exposure: ExposureAdjustment
    @Binding var motionBlur: MotionBlurSettings
    @Binding var grain: FilmGrainFeature
    @Binding var selectedEffect: EditorEffectTab
    let onSelectClip: @MainActor @Sendable (VideoClip.ID) -> Void
    let onRemoveClip: @MainActor @Sendable (VideoClip.ID) -> Void
    let onSelectPhotos: @MainActor @Sendable () -> Void
    let onSelectFiles: @MainActor @Sendable () -> Void

    var body: some View {
      VStack(spacing: 0) {
        VideoBatchStripView(
          contentPadding: contentPadding,
          clips: clips,
          selectedClipID: selectedClipID,
          onSelectClip: onSelectClip,
          onRemoveClip: onRemoveClip,
          onSelectPhotos: onSelectPhotos,
          onSelectFiles: onSelectFiles
        )
        .padding(.vertical, contentPadding)

        EditorEditControl(
          contentPadding: contentPadding,
          videoCount: clips.count,
          hdrVideoCount: hdrVideoCount,
          library: library,
          lutPreviewSource: lutPreviewSource,
          selectedLUT: $selectedLUT,
          exposure: $exposure,
          motionBlur: $motionBlur,
          grain: $grain,
          selectedEffect: $selectedEffect
        )
      }
    }
  }

  /// Owns the effect tabs below the fixed video collection.
  private struct EditorEditControl: View {

    let contentPadding: CGFloat
    let videoCount: Int
    let hdrVideoCount: Int
    let library: LUTLibrary
    let lutPreviewSource: LUTPreviewSourceImage?
    @Binding var selectedLUT: LUT?
    @Binding var exposure: ExposureAdjustment
    @Binding var motionBlur: MotionBlurSettings
    @Binding var grain: FilmGrainFeature
    @Binding var selectedEffect: EditorEffectTab

    var body: some View {
      ScrollView {
        EditorControlContent(
          contentPadding: contentPadding,
          selectedEffect: selectedEffect,
          videoCount: videoCount,
          hdrVideoCount: hdrVideoCount,
          library: library,
          lutPreviewSource: lutPreviewSource,
          selectedLUT: $selectedLUT,
          exposure: $exposure,
          motionBlur: $motionBlur,
          grain: $grain
        )
        .padding(.vertical, contentPadding)
      }
      .scrollBounceBehavior(.basedOnSize)

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
      @Binding var exposure: ExposureAdjustment
      @Binding var motionBlur: MotionBlurSettings
      @Binding var grain: FilmGrainFeature

      var body: some View {
        ZStack(alignment: .topLeading) {
          switch selectedEffect {
          case .lut:
            LUTStripView(
              contentPadding: contentPadding,
              library: library,
              source: lutPreviewSource,
              exposure: exposure,
              selected: $selectedLUT
            )
            .transition(.opacity)

          case .exposure:
            EditorExposureControls(exposure: $exposure)
              .padding(.horizontal, contentPadding)
              .transition(.opacity)

          case .motionBlur:
            EditorMotionBlurControls(settings: $motionBlur)
              .padding(.horizontal, contentPadding)
              .transition(.opacity)

          case .grain:
            EditorGrainControls(settings: $grain)
              .padding(.horizontal, contentPadding)
              .transition(.opacity)
          }
        }
        .animation(.smooth, value: selectedEffect)
      }
    }

    /// Authors a photographic exposure offset before the selected LUT.
    fileprivate struct EditorExposureControls: View {

      @Binding var exposure: ExposureAdjustment

      var body: some View {
        VStack(alignment: .leading, spacing: 10) {
          HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
              Text("Exposure")
                .font(.caption.weight(.semibold))
                .tracking(0.8)
                .foregroundStyle(.secondary)

              Text("Before LUT")
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            Button("Reset") {
              exposure = .neutral
            }
            .font(.caption)
            .disabled(exposure.isNeutral)
            .accessibilityIdentifier("exposure-reset")
          }

          HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text("Exposure")
              .font(.caption)
              .foregroundStyle(.secondary)

            Spacer(minLength: 12)

            HStack(alignment: .firstTextBaseline, spacing: 3) {
              Text(
                exposure.ev,
                format: .number.precision(.fractionLength(1))
              )
              Text("EV")
            }
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(.primary)
          }

          Slider(
            value: $exposure.ev,
            in: ExposureAdjustment.supportedEVRange,
            step: ExposureAdjustment.evStep
          )
          .tint(.primary)
          .accessibilityLabel("Exposure")
          .accessibilityValue(
            Text(
              "\(exposure.ev, format: .number.precision(.fractionLength(1))) EV"
            )
          )
          .accessibilityIdentifier("exposure-slider")

          Text("Adjusts light before the LUT changes the image's color response.")
            .font(.caption)
            .foregroundStyle(.secondary)
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
              Text("Motion Blur")
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

    /// Exposes the Core Image film-grain overlay applied after the selected
    /// LUT. Grain has no device-support requirement, so unlike Motion Blur it
    /// presents no availability state.
    fileprivate struct EditorGrainControls: View {

      @Binding var settings: FilmGrainFeature

      private var intensity: Binding<Double> {
        Binding(
          get: { Double(settings.intensity) },
          set: { settings.intensity = Int($0.rounded()) }
        )
      }

      private var size: Binding<Double> {
        Binding(
          get: { Double(settings.size) },
          set: { settings.size = Int($0.rounded()) }
        )
      }

      private var valueRange: ClosedRange<Double> {
        Double(
          FilmGrainFeature.valueRange.lowerBound
        )...Double(FilmGrainFeature.valueRange.upperBound)
      }

      var body: some View {
        VStack(alignment: .leading, spacing: 10) {
          HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 3) {
              Text("Grain")
                .font(.caption.weight(.semibold))
                .tracking(0.8)
                .foregroundStyle(.secondary)

              Text("Film Grain")
                .font(.caption2)
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            Toggle("Grain", isOn: $settings.isEnabled)
              .labelsHidden()
              .tint(.primary)
              .accessibilityIdentifier("grain-toggle")
          }

          if settings.isEnabled {
            HStack(alignment: .firstTextBaseline, spacing: 12) {
              Text("Intensity")
                .font(.caption)
                .foregroundStyle(.secondary)

              Spacer(minLength: 12)

              Text(settings.intensity, format: .number)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.primary)
            }

            Slider(
              value: intensity,
              in: valueRange,
              step: 1
            )
            .tint(.primary)
            .accessibilityLabel("Grain intensity")
            .accessibilityValue(settings.intensity.formatted())

            HStack(alignment: .firstTextBaseline, spacing: 12) {
              Text("Size")
                .font(.caption)
                .foregroundStyle(.secondary)

              Spacer(minLength: 12)

              Text(settings.size, format: .number)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(.primary)
            }

            Slider(
              value: size,
              in: valueRange,
              step: 1
            )
            .tint(.primary)
            .accessibilityLabel("Grain size")
            .accessibilityValue(settings.size.formatted())
          } else {
            Text("Adds film-like grain texture over the graded image.")
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
/// Keeps editor navigation, source information, and the primary Export action reachable.
private struct EditorToolbarContent: ToolbarContent {

  let canExport: Bool
  let canShowVideoInformation: Bool
  /// Finishes the editor after the user selects the destructive discard action.
  let onDiscard: @MainActor @Sendable () -> Void
  let onShowSettings: @MainActor @Sendable () -> Void
  let onShowVideoInformation: @MainActor @Sendable () -> Void
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
      Button(action: onShowVideoInformation) {
        Image(systemName: "info")
      }
      .disabled(canShowVideoInformation == false)
      .accessibilityLabel("Video Information")
      .accessibilityIdentifier("show-video-information")
    }

    ToolbarSpacer(.fixed, placement: .topBarTrailing)

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
      defaultVideoFolder: DefaultVideoFolderStore(),
      previewSamples: LUTPreviewSampleLibrary(),
      editState: EditState(),
      onFinishEditing: {}
    )
    .navigationBarTitleDisplayMode(.inline)
  }
}
