//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//

import FargMotionBlur
import Photos
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Owns Färg's media-selection home, editor navigation, and shared libraries.
struct RootView: View {

  /// Keeps fast source resolution visible long enough to register as a state change.
  private static let minimumLoadingPresentationDuration: Duration = .seconds(1)

  /// The application-scoped LUT collection, created before onboarding by the
  /// root scene so bundled starter content is ready when the home appears.
  let library: LUTLibrary
  /// The application-scoped preferred starting location for Files video import.
  let defaultVideoFolder: DefaultVideoFolderStore
  @State private var previewSamples = LUTPreviewSampleLibrary()
  @State private var editorSession: EditorViewModel?
  @State private var pickerItems: [PhotosPickerItem] = []
  @State private var isShowingSettings = false
  @State private var isVideoFileImporterPresented = false
  @State private var defaultVideoFolderAccess: DefaultVideoFolderAccess?
  @State private var errorMessage: String?
  @State private var loadingClips: [VideoClip] = []
  @State private var videoLoadRequestID: UUID?
  @State private var videoLoadTask: Task<Void, Never>?
  @Environment(\.scenePhase) private var scenePhase
  @Namespace var namespace
  private let shortcutImports = ShortcutVideoImportCenter.shared

  var body: some View {
    NavigationStack {
      FargMediaPickerView(
        pickerItems: $pickerItems,
        loadingProgress: VideoLoadingProgress(clips: loadingClips),
        onStartEditing: { startEditing() },
        onCancelLoading: { cancelInitialVideoImport() },
        onSelectFiles: presentVideoFileImporter,
        onShowSettings: { isShowingSettings = true },
        namespace: namespace
      )
    }
    .appBlockingOverlayTarget()
    .fullScreenCover(item: $editorSession) { session in
      NavigationStack {
        EditorView(
          onFinishEditing: { editorSession = nil }
        )
        .environment(session)
        .navigationBarTitleDisplayMode(.inline)
      }
      .interactiveDismissDisabled()
      .navigationTransition(.zoom(sourceID: "editor", in: namespace))
    }
    .sheet(isPresented: $isShowingSettings) {
      FargSettingsView(
        library: library,
        defaultVideoFolder: defaultVideoFolder,
        previewSamples: previewSamples
      )
      .tint(.accentColor)
    }
    .fileImporter(
      isPresented: $isVideoFileImporterPresented,
      allowedContentTypes: [.movie],
      allowsMultipleSelection: true
    ) { result in
      switch result {
      case .success(let fileURLs):
        startEditing(fileURLs: fileURLs)
      case .failure(let error):
        if (error as? CocoaError)?.code != .userCancelled {
          errorMessage = error.localizedDescription
        }
      }
    }
    .fileDialogDefaultDirectory(defaultVideoFolderAccess?.url)
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
    .task {
      await library.activateLinkedFolderObservation()
    }
    .task(id: shortcutImports.pendingRequest?.id) {
      guard
        scenePhase == .active,
        let requestID = shortcutImports.pendingRequest?.id
      else {
        return
      }
      await consumeShortcutImport(id: requestID)
    }
    .onChange(of: scenePhase) { _, phase in
      switch phase {
      case .active:
        Task {
          await library.activateLinkedFolderObservation()
          if let requestID = shortcutImports.pendingRequest?.id {
            await consumeShortcutImport(id: requestID)
          }
        }
      case .inactive, .background:
        library.deactivateLinkedFolderObservation()
      @unknown default:
        library.deactivateLinkedFolderObservation()
      }
    }
    .onChange(of: isVideoFileImporterPresented) { _, isPresented in
      if isPresented == false {
        defaultVideoFolderAccess = nil
      }
    }
    .onDisappear {
      videoLoadTask?.cancel()
      defaultVideoFolderAccess = nil
    }
  }

  // MARK: - Video Selection

  /// Opens Files at the registered video folder when its storage is available.
  private func presentVideoFileImporter() {
    defaultVideoFolderAccess = defaultVideoFolder.makeAccess()
    isVideoFileImporterPresented = true
  }

  /// Resolves the committed Photos/Files selection before exposing the editor.
  private func startEditing(fileURLs: [URL] = []) {
    guard pickerItems.isEmpty == false || fileURLs.isEmpty == false else {
      return
    }
    videoLoadTask?.cancel()

    let selectedItems = pickerItems
    let selectedFileURLs = fileURLs
    let clips = VideoPickerImport.makeClips(
      photoItems: selectedItems,
      fileURLs: selectedFileURLs
    )
    let requestID = UUID()
    videoLoadRequestID = requestID
    loadingClips = clips

    videoLoadTask = Task {
      async let minimumLoadingPresentation: Void = Task.sleep(
        for: Self.minimumLoadingPresentationDuration
      )

      defer {
        if videoLoadRequestID == requestID {
          loadingClips = []
          videoLoadRequestID = nil
          videoLoadTask = nil
        }
      }

      do {
        let result = try await VideoPickerImport.load(
          clips,
          requiresPhotoLibraryReadAccess: selectedItems.isEmpty == false
        )
        try await minimumLoadingPresentation
        guard
          Task.isCancelled == false,
          videoLoadRequestID == requestID
        else {
          return
        }

        if let failureMessage = result.failureMessage {
          errorMessage = failureMessage
        }
        guard result.clips.isEmpty == false else { return }

        pickerItems = []
        presentEditor(clips: result.clips)
      } catch is CancellationError {
        return
      } catch {
        errorMessage = error.localizedDescription
      }
    }
  }

  /// Stops source resolution and immediately returns control to the media picker.
  private func cancelInitialVideoImport() {
    videoLoadTask?.cancel()
    videoLoadTask = nil
    videoLoadRequestID = nil
    loadingClips = []
  }

  // MARK: - Shortcuts

  /// Loads one buffered App Intent request into a new editor session.
  private func consumeShortcutImport(
    id: ShortcutVideoImportRequest.ID
  ) async {
    guard
      let request = shortcutImports.take(id: id),
      let lut = library.luts.first(where: { $0.id == request.lutID })
    else {
      return
    }

    let source = VideoSource(appOwnedURL: request.videoURL)
    let colorInfo = await VideoColorInfo.resolve(from: source.asset)
    guard Task.isCancelled == false else { return }

    let clip = VideoClip(
      source: source,
      displayName: request.videoURL.deletingPathExtension().lastPathComponent,
      colorInfo: colorInfo
    )
    pickerItems = []
    presentEditor(clips: [clip], initialSelectedLUTID: lut.id)
  }

  /// Creates a new session owner for the next Editor presentation.
  private func presentEditor(
    clips: [VideoClip],
    initialSelectedLUTID: LUT.ID? = nil
  ) {
    editorSession = EditorViewModel(
      library: library,
      defaultVideoFolder: defaultVideoFolder,
      previewSamples: previewSamples,
      initialClips: clips,
      initialSelectedLUTID: initialSelectedLUTID
    )
  }
}

/// Makes the system media library the first interactive surface in Färg.
private struct FargMediaPickerView: View {

  @Binding var pickerItems: [PhotosPickerItem]
  let loadingProgress: VideoLoadingProgress?
  let onStartEditing: @MainActor @Sendable () -> Void
  let onCancelLoading: @MainActor @Sendable () -> Void
  let onSelectFiles: @MainActor @Sendable () -> Void
  let onShowSettings: @MainActor @Sendable () -> Void
  let namespace: Namespace.ID

  var body: some View {
    PhotosPicker(
      selection: $pickerItems,
      selectionBehavior: .continuousAndOrdered,
      matching: .videos,
      photoLibrary: .shared()
    ) {
      Text("Select Videos")
    }
    .photosPickerStyle(.inline)
    .photosPickerDisabledCapabilities(.selectionActions)
    .photosPickerAccessoryVisibility(.visible, edges: .top)
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .clipShape(.rect(cornerRadius: 36))
    .padding(.horizontal, 4)
    .safeAreaInset(edge: .bottom, spacing: 0) {
      MediaPickerEditAction(
        selectionCount: pickerItems.count,
        onStartEditing: onStartEditing
      )
      .matchedTransitionSource(id: "editor", in: namespace)
    }
    .appBlockingOverlay(isPresented: loadingProgress != nil) {
      if let loadingProgress {
        InitialVideoLoadingHUD(
          progress: loadingProgress,
          onCancel: onCancelLoading
        )
      }
    }
    .background(.background.secondary)
    .toolbarTitleDisplayMode(.inline)
    .toolbar {
      ToolbarItem(placement: .topBarLeading) {
        Button(action: onShowSettings) {
          Image(systemName: "gearshape")
        }
        .disabled(loadingProgress != nil)
        .accessibilityLabel("Settings")
      }

      ToolbarItem(placement: .principal) {
        Image("logo")
          .resizable()
          .aspectRatio(contentMode: .fit)
          .frame(width: 36)
      }

      ToolbarItem(placement: .topBarTrailing) {
        Button(action: onSelectFiles) {
          //          Image(systemName: "externaldrive")
          Image(systemName: "folder")
        }
        .disabled(loadingProgress != nil)
        .accessibilityLabel("Choose from Files")
        .accessibilityIdentifier("choose-videos-from-files")
      }
    }
  }
}

/// Commits the ordered inline selection from a floating picker action.
private struct MediaPickerEditAction: View {

  let selectionCount: Int
  let onStartEditing: @MainActor @Sendable () -> Void

  var body: some View {
    Button(action: onStartEditing) {
      HStack(spacing: 10) {
        Image(systemName: "arrow.up")
      }
      .font(.headline)
      .padding(.horizontal, 4)
    }
    .buttonStyle(.borderedProminent)
    .glassEffect(.regular.interactive())
    .controlSize(.large)
    .disabled(selectionCount == 0)
    .accessibilityIdentifier("open-selected-videos")
    .padding(.horizontal, 16)
    .padding(.vertical, 8)
  }
}

/// Blocks repeated selection while showing import progress above the current picker.
private struct InitialVideoLoadingHUD: View {

  let progress: VideoLoadingProgress
  /// Cancels the source-resolution task owned by the home screen.
  let onCancel: @MainActor @Sendable () -> Void

  var body: some View {
    ZStack {
      Rectangle()
        .fill(.black.opacity(0.16))

      VStack(spacing: 24) {
        VStack(spacing: 14) {
          ProgressView()
            .controlSize(.large)
            .accessibilityLabel("Loading video")
            .accessibilityValue(
              "\(progress.currentItemIndex + 1) of \(progress.itemCount)"
            )

          VStack(spacing: 6) {
            Text(
              "Loading video \(progress.currentItemIndex + 1) of \(progress.itemCount)…",
              comment:
                "Initial video import progress. Variables are the current and total videos."
            )
            .font(.title3.weight(.semibold))

            Text("Preparing your selection for editing.")
              .font(.subheadline)
              .foregroundStyle(.secondary)
          }
          .multilineTextAlignment(.center)

        }

        Button(action: onCancel) {
          Image(systemName: "xmark")
        }
        .buttonStyle(.bordered)
        .controlSize(.large)
        .accessibilityIdentifier("cancel-video-loading")
      }
      .padding(24)
      .frame(maxWidth: 280)
      .glassEffect(in: .rect(cornerRadius: 32))

    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .accessibilityIdentifier("initial-video-loading")
  }
}

/// Provides a standalone Canvas host for the initial video loading HUD.
@MainActor
private struct InitialVideoLoadingHUDPreview: View {

  @State private var isLoading = true
  @State private var clips = [
    VideoClip { throw CancellationError() },
    VideoClip { throw CancellationError() },
    VideoClip { throw CancellationError() },
  ]

  var body: some View {
    ZStack {
      Rectangle()
        .fill(.background.secondary)

      if isLoading {
        InitialVideoLoadingHUD(
          progress: VideoLoadingProgress(clips: clips)!,
          onCancel: { isLoading = false }
        )
      } else {
        Text("Loading cancelled")
          .foregroundStyle(.secondary)
      }
    }
    .frame(width: 390, height: 844)
  }
}

#Preview("Initial Video Loading HUD") {
  InitialVideoLoadingHUDPreview()
}

#Preview {
  RootView(
    library: LUTLibrary(),
    defaultVideoFolder: DefaultVideoFolderStore()
  )
}
