import Photos
import SwiftUI

@Observable
final class PhotoLibraryManager: @unchecked Sendable {

  enum AuthorizationStatus {
    case notDetermined
    case authorized
    case limited
    case denied
  }

  enum SortOrder {
    case date
    case size
  }

  struct AssetItem: Identifiable {
    let asset: PHAsset
    var fileSize: Int64?

    var id: String { asset.localIdentifier }
  }

  private(set) var authorizationStatus: AuthorizationStatus = .notDetermined
  private(set) var assets: [AssetItem] = []
  private(set) var isLoadingFileSizes = false
  private(set) var fileSizeProgress: Double = 0

  var sortOrder: SortOrder = .date {
    didSet { sortAssets() }
  }

  private var fileSizeCache: [String: Int64] = [:]

  func checkCurrentAuthorization() async {
    let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
    applyStatus(status)
    if authorizationStatus == .authorized || authorizationStatus == .limited {
      await fetchAssets()
    }
  }

  func requestAuthorization() async {
    let status = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
    applyStatus(status)
    if authorizationStatus == .authorized || authorizationStatus == .limited {
      await fetchAssets()
    }
  }

  private func applyStatus(_ status: PHAuthorizationStatus) {
    switch status {
    case .authorized:
      authorizationStatus = .authorized
    case .limited:
      authorizationStatus = .limited
    case .denied, .restricted:
      authorizationStatus = .denied
    case .notDetermined:
      authorizationStatus = .notDetermined
    @unknown default:
      authorizationStatus = .denied
    }
  }

  func fetchAssets() async {
    let options = PHFetchOptions()
    options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
    options.predicate = NSPredicate(format: "mediaType == %d", PHAssetMediaType.image.rawValue)
    options.includeAssetSourceTypes = [.typeUserLibrary]

    let result = PHAsset.fetchAssets(with: options)
    var items: [AssetItem] = []
    result.enumerateObjects { asset, _, _ in
      items.append(AssetItem(asset: asset, fileSize: nil))
    }
    assets = items
    await loadFileSizes()
  }

  func fileSize(for asset: PHAsset) -> Int64? {
    fileSizeCache[asset.localIdentifier]
  }

  private func loadFileSizes() async {
    isLoadingFileSizes = true
    let total = assets.count
    guard total > 0 else {
      isLoadingFileSizes = false
      return
    }

    for i in 0..<total {
      let asset = assets[i].asset
      let size = await fetchFileSize(for: asset)
      fileSizeCache[asset.localIdentifier] = size
      assets[i].fileSize = size
      fileSizeProgress = Double(i + 1) / Double(total)
    }

    isLoadingFileSizes = false
    sortAssets()
  }

  @concurrent
  nonisolated private func fetchFileSize(for asset: PHAsset) async -> Int64 {
    await withCheckedContinuation { continuation in
      let resources = PHAssetResource.assetResources(for: asset)
      guard let resource = resources.first else {
        continuation.resume(returning: 0)
        return
      }

      var totalSize: Int64 = 0
      let options = PHAssetResourceRequestOptions()
      options.isNetworkAccessAllowed = false

      PHAssetResourceManager.default().requestData(
        for: resource,
        options: options,
        dataReceivedHandler: { data in
          totalSize += Int64(data.count)
        },
        completionHandler: { _ in
          continuation.resume(returning: totalSize)
        }
      )
    }
  }

  private func sortAssets() {
    switch sortOrder {
    case .date:
      assets.sort { ($0.asset.creationDate ?? .distantPast) > ($1.asset.creationDate ?? .distantPast) }
    case .size:
      assets.sort { ($0.fileSize ?? 0) > ($1.fileSize ?? 0) }
    }
  }
}

func formatFileSize(_ bytes: Int64) -> String {
  let formatter = ByteCountFormatter()
  formatter.countStyle = .file
  return formatter.string(fromByteCount: bytes)
}
