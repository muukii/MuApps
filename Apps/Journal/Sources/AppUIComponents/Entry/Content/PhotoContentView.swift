import SwiftUI

#if canImport(UIKit)
  import UIKit
#endif

/// Photo preview source for either an unsaved draft or a saved card.
public struct PhotoContentSource: Equatable, Sendable {
  public let imageData: Data?
  public let fileURL: URL?
  public let fileRevision: Int
  public let displayAspectRatio: CGFloat?

  public init(
    imageData: Data? = nil,
    fileURL: URL? = nil,
    fileRevision: Int = 0,
    pixelSize: CGSize? = nil
  ) {
    self.imageData = imageData
    self.fileURL = fileURL
    self.fileRevision = fileRevision
    self.displayAspectRatio =
      pixelSize?.contentAspectRatio
      ?? EncodedImageDimensions.displayAspectRatio(from: imageData)
      ?? EncodedImageDimensions.displayAspectRatio(at: fileURL)
  }
}

/// Renders still-photo content while preserving its eventual media geometry.
struct PhotoContentView: View {

  /// Visual and loading treatment owned by still-photo content.
  struct Style {
    let preset: EntryContentStyle

    init(_ preset: EntryContentStyle) {
      self.preset = preset
    }

    var contentMode: ContentMode {
      switch preset {
      case .composer:
        return .fill
      case .cell:
        return .fit
      }
    }

    var placeholderAspectRatio: CGFloat { 1 }
  }

  let photo: PhotoContentSource
  let style: Style
  @State private var decodedImageDataImage: UIImage?
  @State private var loadedFileImage: UIImage?

  @ViewBuilder
  var body: some View {
    if let inlineImageData {
      ContentMediaFrame(aspectRatio: displayAspectRatio(for: nil)) {
        InlineImageDataContentView(
          imageData: inlineImageData,
          fallbackSystemImage: "photo"
        )
      }
    } else {
      content
        .task(id: imageLoadID) {
          await refreshImages()
        }
    }
  }

  /// In-memory Cell values are already detached from file-backed loading.
  /// Rendering them immediately also keeps one-shot raster consumers independent
  /// from SwiftUI lifecycle task scheduling.
  private var inlineImageData: Data? {
    guard photo.fileURL == nil else { return nil }
    switch style.preset {
    case .composer:
      return nil
    case .cell:
      break
    }
    return photo.imageData
  }

  @ViewBuilder
  private var content: some View {
    if let image {
      Image(uiImage: image)
        .resizable()
        .aspectRatio(
          displayAspectRatio(for: image),
          contentMode: style.contentMode
        )
    } else {
      ContentMediaPlaceholder(
        systemImage: "photo",
        aspectRatio: displayAspectRatio(for: nil)
      )
    }
  }

  private var image: UIImage? {
    switch style.preset {
    case .composer:
      return decodedImageDataImage
    case .cell:
      return loadedFileImage
    }
  }

  private var imageLoadID: ContentImageLoadID {
    ContentImageLoadID(
      style: style.preset,
      fileURL: photo.fileURL,
      fileRevision: photo.fileRevision,
      data: ContentImageDataFingerprint(photo.imageData)
    )
  }

  /// Keeps loading and decoded states on the same placement geometry.
  private func displayAspectRatio(for image: UIImage?) -> CGFloat {
    switch style.preset {
    case .composer:
      return image?.contentAspectRatio ?? style.placeholderAspectRatio
    case .cell:
      return
        photo.displayAspectRatio
        ?? image?.contentAspectRatio
        ?? style.placeholderAspectRatio
    }
  }

  @MainActor
  private func refreshImages() async {
    decodedImageDataImage = nil
    loadedFileImage = nil

    switch style.preset {
    case .composer:
      let image = await ContentMediaFileReader.image(from: photo.imageData)
      guard Task.isCancelled == false else {
        return
      }

      decodedImageDataImage = image

    case .cell:
      guard let fileURL = photo.fileURL else {
        return
      }

      let fileImage = await ContentMediaFileReader.image(at: fileURL)
      guard Task.isCancelled == false else {
        return
      }

      loadedFileImage = fileImage
    }
  }
}

#Preview("Photo Content — 3:2") {
  EntryContentPreviewCanvas {
    PhotoContentView(
      photo: PhotoContentSource(
        pixelSize: CGSize(width: 1_200, height: 800)
      ),
      style: .init(.cell)
    )
  }
}
