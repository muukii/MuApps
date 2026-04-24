import CoreGraphics
import ImageIO
import Photos
import UIKit
import UniformTypeIdentifiers
import avif

enum ConversionFormat: String, CaseIterable, Identifiable {
  case heif = "HEIF"
  case avif = "AVIF"

  var id: String { rawValue }
}

struct ConversionResult {
  let originalSize: Int64
  let convertedSize: Int64
  let convertedData: Data

  var savedBytes: Int64 { originalSize - convertedSize }
  var savedPercentage: Double {
    guard originalSize > 0 else { return 0 }
    return Double(savedBytes) / Double(originalSize) * 100
  }
}

actor ImageConverter {

  func loadOriginalData(for asset: PHAsset) async throws -> Data {
    let resources = PHAssetResource.assetResources(for: asset)
    guard let resource = resources.first else {
      throw ConversionError.noResource
    }

    return try await withCheckedThrowingContinuation { continuation in
      var data = Data()
      let options = PHAssetResourceRequestOptions()
      options.isNetworkAccessAllowed = true

      PHAssetResourceManager.default().requestData(
        for: resource,
        options: options,
        dataReceivedHandler: { chunk in
          data.append(chunk)
        },
        completionHandler: { error in
          if let error {
            continuation.resume(throwing: error)
          } else {
            continuation.resume(returning: data)
          }
        }
      )
    }
  }

  func convert(
    imageData: Data,
    to format: ConversionFormat,
    quality: Double
  ) throws -> Data {
    guard let cgImage = createCGImage(from: imageData) else {
      throw ConversionError.invalidImageData
    }

    let metadata = extractMetadata(from: imageData)

    switch format {
    case .heif:
      return try encodeHEIF(cgImage: cgImage, quality: quality, metadata: metadata)
    case .avif:
      return try encodeAVIF(cgImage: cgImage, quality: quality)
    }
  }

  func saveToPhotoLibrary(data: Data, originalAsset: PHAsset) async throws {
    try await PHPhotoLibrary.shared().performChanges {
      let request = PHAssetCreationRequest.forAsset()
      request.addResource(with: .photo, data: data, options: nil)
      request.creationDate = originalAsset.creationDate
      request.location = originalAsset.location
      request.isFavorite = originalAsset.isFavorite
    }
  }

  // MARK: - Private

  private func createCGImage(from data: Data) -> CGImage? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil),
      CGImageSourceGetCount(source) > 0
    else {
      return nil
    }
    return CGImageSourceCreateImageAtIndex(source, 0, nil)
  }

  private func extractMetadata(from data: Data) -> CFDictionary? {
    guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
      return nil
    }
    return CGImageSourceCopyPropertiesAtIndex(source, 0, nil)
  }

  private func encodeHEIF(cgImage: CGImage, quality: Double, metadata: CFDictionary?) throws -> Data {
    let data = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(
        data as CFMutableData,
        UTType.heic.identifier as CFString,
        1,
        nil
      )
    else {
      throw ConversionError.encodingFailed
    }

    var options: [CFString: Any] = [
      kCGImageDestinationLossyCompressionQuality: quality
    ]
    if let metadata = metadata as? [CFString: Any] {
      options.merge(metadata) { current, _ in current }
    }
    CGImageDestinationAddImage(destination, cgImage, options as CFDictionary)

    guard CGImageDestinationFinalize(destination) else {
      throw ConversionError.encodingFailed
    }

    return data as Data
  }

  private func encodeAVIF(cgImage: CGImage, quality: Double) throws -> Data {
    let speed = 6
    let image = UIImage(cgImage: cgImage)
    return try AVIFEncoder.encode(image: image, quality: quality, speed: speed)
  }
}

enum ConversionError: LocalizedError {
  case noResource
  case invalidImageData
  case encodingFailed

  var errorDescription: String? {
    switch self {
    case .noResource: "No image resource found"
    case .invalidImageData: "Could not decode image data"
    case .encodingFailed: "Image encoding failed"
    }
  }
}
