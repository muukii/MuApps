@preconcurrency import Photos
import SwiftUI

struct PhotoDetailView: View {

  let asset: PHAsset
  let manager: PhotoLibraryManager

  @State private var image: UIImage?
  @State private var showingConversion = false

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 16) {
        // Image preview
        Group {
          if let image {
            Image(uiImage: image)
              .resizable()
              .scaledToFit()
          } else {
            Rectangle()
              .fill(.gray.opacity(0.2))
              .aspectRatio(
                CGFloat(asset.pixelWidth) / CGFloat(asset.pixelHeight),
                contentMode: .fit
              )
              .overlay { ProgressView() }
          }
        }

        // Metadata
        VStack(alignment: .leading, spacing: 12) {
          Text("Metadata")
            .font(.headline)

          MetadataGrid(asset: asset, fileSize: manager.fileSize(for: asset))
        }
        .padding(.horizontal)

        // Convert button
        Button {
          showingConversion = true
        } label: {
          Label("Convert", systemImage: "arrow.triangle.2.circlepath")
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .padding(.horizontal)
      }
    }
    .navigationTitle("Detail")
    .navigationBarTitleDisplayMode(.inline)
    .sheet(isPresented: $showingConversion) {
      ConversionView(asset: asset, originalSize: manager.fileSize(for: asset))
    }
    .task {
      await loadFullImage()
    }
  }

  private func loadFullImage() async {
    let options = PHImageRequestOptions()
    options.deliveryMode = .highQualityFormat
    options.isNetworkAccessAllowed = true

    let targetSize = CGSize(
      width: UIScreen.main.bounds.width * UIScreen.main.scale,
      height: UIScreen.main.bounds.height * UIScreen.main.scale
    )

    let img = await withCheckedContinuation { (continuation: CheckedContinuation<UIImage?, Never>) in
      PHImageManager.default().requestImage(
        for: asset,
        targetSize: targetSize,
        contentMode: .aspectFit,
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

struct MetadataGrid: View {

  let asset: PHAsset
  let fileSize: Int64?

  @State private var filename: String?
  @State private var uti: String?

  var body: some View {
    Grid(alignment: .leading, verticalSpacing: 8) {
      if let fileSize {
        metadataRow("File Size", formatFileSize(fileSize))
      }

      metadataRow("Dimensions", "\(asset.pixelWidth) × \(asset.pixelHeight)")

      if let filename {
        metadataRow("Filename", filename)
      }

      if let uti {
        metadataRow("Format", uti)
      }

      if let date = asset.creationDate {
        metadataRow("Created", date.formatted(date: .abbreviated, time: .shortened))
      }

      if asset.mediaSubtypes.contains(.photoHDR) {
        metadataRow("Type", "HDR")
      } else if asset.mediaSubtypes.contains(.photoScreenshot) {
        metadataRow("Type", "Screenshot")
      } else if asset.mediaSubtypes.contains(.photoPanorama) {
        metadataRow("Type", "Panorama")
      }

      if let location = asset.location {
        metadataRow(
          "Location",
          String(format: "%.4f, %.4f", location.coordinate.latitude, location.coordinate.longitude)
        )
      }
    }
    .task {
      let resources = await Task.detached {
        PHAssetResource.assetResources(for: self.asset)
      }.value
      let primary = resources.first
      filename = primary?.originalFilename
      uti = primary?.uniformTypeIdentifier
    }
  }

  private func metadataRow(_ label: String, _ value: String) -> some View {
    GridRow {
      Text(label)
        .foregroundStyle(.secondary)
        .gridColumnAlignment(.leading)
      Text(value)
        .gridColumnAlignment(.leading)
    }
  }
}
