import AVFoundation
import CoreImage
import MuDesignSystem
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {

  @StateObject private var catalog = LUTCatalog()
  @StateObject private var thumbnailCache = LUTThumbnailCache()

  @State private var selectedLUTID: LUT.ID?
  @State private var frameSource: (any FrameSource)?
  @State private var isPeeking = false

  @State private var pickerItem: PhotosPickerItem?
  @State private var isImportingLUT = false

  @State private var loadError: String?
  @State private var isLoadingMedia = false

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        previewArea
        Divider()
        LUTPickerView(
          luts: catalog.all,
          selection: $selectedLUTID,
          onImportTap: { isImportingLUT = true }
        )
        .background(.ultraThinMaterial)
      }
      .navigationTitle("PeekLUT")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          PhotosPicker(
            selection: $pickerItem,
            matching: .any(of: [.images, .videos]),
            photoLibrary: .shared()
          ) {
            Image(systemName: "photo.on.rectangle")
          }
        }
      }
      .task(id: pickerItem) {
        await loadPickedItem()
      }
      .onAppear {
        thumbnailCache.ensureThumbnails(for: catalog.all)
      }
      .onChange(of: catalog.all) { _, newValue in
        thumbnailCache.ensureThumbnails(for: newValue)
      }
      .fileImporter(
        isPresented: $isImportingLUT,
        allowedContentTypes: lutImportContentTypes,
        allowsMultipleSelection: true
      ) { result in
        handleImport(result)
      }
      .alert(
        "Failed to load",
        isPresented: Binding(
          get: { loadError != nil },
          set: { if !$0 { loadError = nil } }
        ),
        presenting: loadError
      ) { _ in
        Button("OK", role: .cancel) {}
      } message: { message in
        Text(message)
      }
    }
    .environmentObject(thumbnailCache)
  }

  // MARK: - Preview

  @ViewBuilder
  private var previewArea: some View {
    ZStack {
      Color.black.ignoresSafeArea(edges: .top)
      MetalLUTView(
        frameSource: frameSource,
        lut: currentLUT,
        isPeeking: isPeeking
      )
      .ignoresSafeArea(edges: .top)
      if frameSource == nil {
        emptyState
      }
      if isPeeking {
        VStack {
          HStack {
            Text("Original")
              .font(.caption.weight(.semibold))
              .padding(.horizontal, 10)
              .padding(.vertical, 6)
              .background(.thinMaterial, in: Capsule())
            Spacer()
          }
          .padding()
          Spacer()
        }
        .transition(.opacity)
      }
      if isLoadingMedia {
        ProgressView()
          .controlSize(.large)
          .tint(.white)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .contentShape(Rectangle())
    .gesture(peekGesture)
  }

  private var emptyState: some View {
    VStack(spacing: 12) {
      Image(systemName: "photo.stack")
        .font(.system(size: 48))
        .foregroundStyle(.white.opacity(0.7))
      Text("Pick a photo or video")
        .foregroundStyle(.white.opacity(0.8))
      Text("Tap the picker in the top-right")
        .font(.footnote)
        .foregroundStyle(.white.opacity(0.5))
    }
  }

  private var peekGesture: some Gesture {
    LongPressGesture(minimumDuration: 0.05)
      .sequenced(before: DragGesture(minimumDistance: 0))
      .onChanged { value in
        switch value {
        case .second(true, _):
          if !isPeeking { isPeeking = true }
        default:
          break
        }
      }
      .onEnded { _ in
        isPeeking = false
      }
  }

  // MARK: - Computed

  private var currentLUT: LUT? {
    guard let id = selectedLUTID else { return nil }
    return catalog.all.first(where: { $0.id == id })
  }

  private var lutImportContentTypes: [UTType] {
    var types: [UTType] = [.png, .jpeg, .heic, .image]
    if let cube = UTType(filenameExtension: "cube") {
      types.insert(cube, at: 0)
    }
    types.append(.data)
    return types
  }

  // MARK: - Media loading

  private func loadPickedItem() async {
    guard let item = pickerItem else { return }
    isLoadingMedia = true
    defer { isLoadingMedia = false }

    if let movieURL = await loadVideoURL(from: item) {
      let source = VideoFrameSource(url: movieURL)
      frameSource = source
      source.play()
      return
    }
    if let data = try? await item.loadTransferable(type: Data.self),
       let image = UIImage(data: data),
       let source = StillImageFrameSource(uiImage: image) {
      frameSource = source
      return
    }
    loadError = "Could not read the selected item."
  }

  private func loadVideoURL(from item: PhotosPickerItem) async -> URL? {
    guard let movie = try? await item.loadTransferable(type: VideoTransferable.self) else {
      return nil
    }
    return movie.url
  }

  // MARK: - LUT import

  private func handleImport(_ result: Result<[URL], Error>) {
    switch result {
    case .success(let urls):
      var firstImported: LUT?
      for url in urls {
        do {
          let lut = try catalog.importFile(at: url)
          if firstImported == nil { firstImported = lut }
        } catch {
          loadError = "Could not import \(url.lastPathComponent): \(error.localizedDescription)"
        }
      }
      thumbnailCache.ensureThumbnails(for: catalog.all)
      if let firstImported {
        selectedLUTID = firstImported.id
      }
    case .failure(let error):
      loadError = error.localizedDescription
    }
  }
}

// MARK: - Video Transferable

private struct VideoTransferable: Transferable {
  let url: URL

  static var transferRepresentation: some TransferRepresentation {
    FileRepresentation(contentType: .movie) { movie in
      SentTransferredFile(movie.url)
    } importing: { received in
      let dest = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension(received.file.pathExtension)
      if FileManager.default.fileExists(atPath: dest.path) {
        try FileManager.default.removeItem(at: dest)
      }
      try FileManager.default.copyItem(at: received.file, to: dest)
      return Self(url: dest)
    }
  }
}

#Preview {
  ContentView()
}
