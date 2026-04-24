import Photos
import SwiftUI

struct PhotoGridView: View {

  @Bindable var manager: PhotoLibraryManager

  private let columns = [
    GridItem(.flexible(), spacing: 2),
    GridItem(.flexible(), spacing: 2),
    GridItem(.flexible(), spacing: 2),
  ]

  var body: some View {
    ScrollView {
      if manager.isLoadingFileSizes {
        ProgressView(value: manager.fileSizeProgress) {
          Text("Loading file sizes...")
        }
        .padding()
      }

      LazyVGrid(columns: columns, spacing: 2) {
        ForEach(manager.assets) { item in
          NavigationLink(value: item.asset) {
            PhotoThumbnailView(asset: item.asset, fileSize: item.fileSize)
              .frame(minWidth: 0, maxWidth: .infinity, minHeight: 0, maxHeight: .infinity)
              .aspectRatio(1, contentMode: .fit)
              .clipped()
          }
        }
      }
    }
    .toolbar {
      ToolbarItem(placement: .topBarTrailing) {
        Menu {
          Picker("Sort", selection: $manager.sortOrder) {
            Label("Date", systemImage: "calendar").tag(PhotoLibraryManager.SortOrder.date)
            Label("Size", systemImage: "arrow.down.circle").tag(PhotoLibraryManager.SortOrder.size)
          }
        } label: {
          Label("Sort", systemImage: "arrow.up.arrow.down")
        }
      }
    }
  }
}

struct PhotoThumbnailView: View {

  let asset: PHAsset
  let fileSize: Int64?

  @State private var image: UIImage?

  var body: some View {
    Color.clear
      .overlay {
        if let image {
          Image(uiImage: image)
            .resizable()
            .scaledToFill()
        } else {
          Rectangle()
            .fill(.gray.opacity(0.2))
        }
      }
      .clipped()
      .overlay(alignment: .bottomTrailing) {
        if let fileSize {
          Text(formatFileSize(fileSize))
            .font(.caption2)
            .fontWeight(.medium)
            .padding(.horizontal, 4)
            .padding(.vertical, 2)
            .background(.ultraThinMaterial)
            .cornerRadius(4)
            .padding(4)
        }
      }
    .task(id: asset.localIdentifier) {
      await loadThumbnail()
    }
  }

  private func loadThumbnail() async {
    let size = CGSize(width: 200, height: 200)
    let options = PHImageRequestOptions()
    options.deliveryMode = .opportunistic
    options.isNetworkAccessAllowed = true

    let img = await withCheckedContinuation { (continuation: CheckedContinuation<UIImage?, Never>) in
      PHCachingImageManager.default().requestImage(
        for: asset,
        targetSize: size,
        contentMode: .aspectFill,
        options: options
      ) { result, info in
        let isDegraded = (info?[PHImageResultIsDegradedKey] as? Bool) ?? false
        if !isDegraded {
          continuation.resume(returning: result)
        }
      }
    }
    self.image = img
  }
}
