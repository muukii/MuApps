//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//

import AVFoundation
import Photos
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// Selects the previewed clip while making the shared edit scope explicit.
struct VideoBatchStripView: View {

  let contentPadding: CGFloat
  let clips: [VideoClip]
  let selectedClipID: VideoClip.ID?
  @Binding var pickerItems: [PhotosPickerItem]
  let onSelectClip: @MainActor @Sendable (VideoClip.ID) -> Void
  let onRemoveClip: @MainActor @Sendable (VideoClip.ID) -> Void
  let onPickFileURLs: @MainActor @Sendable ([URL]) -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 10) {    
      VideoBatchFilmstrip(
        contentPadding: contentPadding,
        clips: clips,
        selectedClipID: selectedClipID,
        pickerItems: $pickerItems,
        isPickerDisabled: clips.contains(where: \.isPreparing),
        onSelectClip: onSelectClip,
        onRemoveClip: onRemoveClip,
        onPickFileURLs: onPickFileURLs
      )
    }
  }
}

/// A thumbnail rail whose stable clip identity survives selection and removal.
private struct VideoBatchFilmstrip: View {

  let contentPadding: CGFloat
  let clips: [VideoClip]
  let selectedClipID: VideoClip.ID?
  @Binding var pickerItems: [PhotosPickerItem]
  let isPickerDisabled: Bool
  let onSelectClip: @MainActor @Sendable (VideoClip.ID) -> Void
  let onRemoveClip: @MainActor @Sendable (VideoClip.ID) -> Void
  let onPickFileURLs: @MainActor @Sendable ([URL]) -> Void

  var body: some View {
    ScrollViewReader { proxy in
      ScrollView(.horizontal, showsIndicators: false) {
        LazyHStack(spacing: 8) {
          ForEach(clips) { clip in
            VideoBatchClipCell(
              clip: clip,
              isSelected: clip.id == selectedClipID,
              onSelect: { onSelectClip(clip.id) },
              onRemove: { onRemoveClip(clip.id) }
            )
            .id(clip.id)
          }

          VideoBatchAddCell(
            pickerItems: $pickerItems,
            isDisabled: isPickerDisabled,
            onPickFileURLs: onPickFileURLs
          )
        }
        .padding(.horizontal, 1)
      }
      .contentMargins(.horizontal, contentPadding, for: .scrollContent)
      .onAppear {
        if let selectedClipID {
          proxy.scrollTo(selectedClipID, anchor: .center)
        }
      }
      .onChange(of: selectedClipID) { _, newID in
        if let newID {
          withAnimation(.snappy) {
            proxy.scrollTo(newID, anchor: .center)
          }
        }
      }
    }
    .frame(height: 54)
  }
}

extension View {
  
  func selectionOverlay(isSelected: Bool) -> some View {
    overlay {
      RoundedRectangle(cornerRadius: 9, style: .continuous)
        .stroke(
          .tint,
          lineWidth: isSelected ? 2 : 0
        )
    }
  }
  
}

/// Renders one clip's lifecycle at its stable filmstrip position.
private struct VideoBatchClipCell: View {

  let clip: VideoClip
  let isSelected: Bool
  let onSelect: @MainActor @Sendable () -> Void
  let onRemove: @MainActor @Sendable () -> Void

  var body: some View {
    switch clip.state {
    case .queued, .loading:
      VideoBatchLoadingPlaceholder()

    case .ready(let content):
      Button(action: onSelect) {
        VideoClipThumbnail(source: content.source)
          .frame(width: 72, height: 52)
          .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
          .selectionOverlay(isSelected: isSelected)
      }
      .buttonStyle(.plain)
      .contextMenu {
        Button("Delete Video", systemImage: "trash", role: .destructive) {
          onRemove()
        }
      }
      .accessibilityLabel(content.displayName)
      .accessibilityAddTraits(isSelected ? .isSelected : [])
      .accessibilityAction(named: "Delete Video", onRemove)

    case .failed:
      VideoBatchFailurePlaceholder()
    }
  }
}

/// Offers both supported import sources at the trailing end of the filmstrip.
private struct VideoBatchAddCell: View {

  @Binding var pickerItems: [PhotosPickerItem]
  let isDisabled: Bool
  let onPickFileURLs: @MainActor @Sendable ([URL]) -> Void

  @State private var isPhotosPickerPresented = false
  @State private var isVideoFileImporterPresented = false
  @State private var fileImporterErrorMessage: String?

  var body: some View {
    Menu {
      Button {
        isPhotosPickerPresented = true
      } label: {
        Label("Photos", systemImage: "photo.on.rectangle")
      }

      Button {
        isVideoFileImporterPresented = true
      } label: {
        Label("Files", systemImage: "externaldrive")
      }
    } label: {
      Image(systemName: "plus")
        .font(.title3)
        .foregroundStyle(.secondary)
        .frame(width: 72, height: 52)
        .background(
          .background.secondary,
          in: RoundedRectangle(cornerRadius: 9, style: .continuous)
        )
        .overlay {
          RoundedRectangle(cornerRadius: 9, style: .continuous)
            .stroke(
              Color.secondary.opacity(0.2),
              style: StrokeStyle(lineWidth: 1, dash: [4])
            )
        }
        .contentShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
    }
    .buttonStyle(.plain)
    .disabled(isDisabled)
    .accessibilityLabel("Add Videos")
    // TODO: Cellにこういうアクションがあるのはだめ
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
        onPickFileURLs(fileURLs)
      case .failure(let error):
        if (error as? CocoaError)?.code != .userCancelled {
          fileImporterErrorMessage = error.localizedDescription
        }
      }
    }
    .alert(
      "Couldn't Open Files",
      isPresented: Binding(
        get: { fileImporterErrorMessage != nil },
        set: { if $0 == false { fileImporterErrorMessage = nil } }
      ),
      presenting: fileImporterErrorMessage
    ) { _ in
      Button("OK", role: .cancel) {}
    } message: { message in
      Text(message)
    }
  }
}

/// Generates a small source frame lazily so filmstrip color comes from footage.
private struct VideoClipThumbnail: View {

  let source: VideoSource

  @State private var image: CGImage?

  var body: some View {
    ZStack {
      Rectangle()
        .fill(.background.secondary)

      if let image {
        Image(decorative: image, scale: 1)
          .resizable()
          .scaledToFill()
      } else {
        Image(systemName: "film")
          .foregroundStyle(.secondary)
      }
    }
    .clipped()
    .task(id: source.id) {
      let generator = AVAssetImageGenerator(asset: source.asset)
      generator.appliesPreferredTrackTransform = true
      generator.maximumSize = CGSize(width: 216, height: 156)
      generator.dynamicRangePolicy = .forceSDR

      do {
        let result = try await generator.image(
          at: CMTime(seconds: 0.1, preferredTimescale: 600)
        )
        guard Task.isCancelled == false else { return }
        image = result.image
      } catch {
        image = nil
      }
    }
  }
}

/// Reserves a stable visual destination while a source is opened in place.
private struct VideoBatchLoadingPlaceholder: View {

  var body: some View {
    ProgressView()
      .tint(.primary)
      .frame(width: 72, height: 52)
      .background(
        .background.secondary,
        in: RoundedRectangle(cornerRadius: 9, style: .continuous)
      )
      .overlay {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
          .stroke(
            Color.secondary.opacity(0.2),
            style: StrokeStyle(lineWidth: 1, dash: [4])
          )
      }
      .accessibilityLabel("Adding video")
  }
}

/// Identifies an unavailable picker item until the batch removes it.
private struct VideoBatchFailurePlaceholder: View {

  var body: some View {
    Image(systemName: "exclamationmark.triangle")
      .foregroundStyle(.orange)
      .frame(width: 72, height: 52)
      .background(
        .background.secondary,
        in: RoundedRectangle(cornerRadius: 9, style: .continuous)
      )
      .overlay {
        RoundedRectangle(cornerRadius: 9, style: .continuous)
          .stroke(Color.secondary.opacity(0.2), lineWidth: 1)
      }
      .accessibilityLabel("Video couldn't be loaded")
  }
}
