import ImageIO
import MuColor
import SwiftUI

#if canImport(UIKit)
  import UIKit
#endif

struct ContentMediaBadge: View {

  let systemImage: String

  var body: some View {
    Image(systemName: systemImage)
      .font(.caption.weight(.bold))
      .foregroundStyle(.white)
      .padding(8)
      .background(.black.opacity(0.48), in: Circle())
      .padding(8)
  }
}

/// Loading state for authored media that may need to be decoded from disk.
enum ContentMediaLoadState<Payload> {
  case idle
  case loading
  case loaded(Payload)
  case unavailable

  var loadedPayload: Payload? {
    guard case .loaded(let payload) = self else {
      return nil
    }

    return payload
  }

  var isLoading: Bool {
    if case .loading = self {
      return true
    }

    return false
  }
}

/// Stable identity for image decode tasks without hashing entire image data.
struct ContentImageLoadID: Hashable {
  let style: EntryContentStyle
  let fileURL: URL?
  let fileRevision: Int
  let primaryData: ContentImageDataFingerprint?
  let fallbackData: ContentImageDataFingerprint?
}

struct ContentFileLoadID: Hashable {
  let fileURL: URL?
  let fileRevision: Int
}

/// Lightweight fingerprint for image data used only to restart decode tasks.
struct ContentImageDataFingerprint: Hashable, Sendable {
  let byteCount: Int
  let prefix: UInt64
  let suffix: UInt64

  init?(_ data: Data?) {
    guard let data else {
      return nil
    }

    byteCount = data.count
    prefix = Self.word(from: data.prefix(8))
    suffix = Self.word(from: data.suffix(8))
  }

  private static func word(from bytes: Data.SubSequence) -> UInt64 {
    bytes.reduce(UInt64(0)) { result, byte in
      (result << 8) | UInt64(byte)
    }
  }
}

struct ContentLoadingMedia: View {

  let isCompact: Bool

  var body: some View {
    if isCompact {
      ProgressView()
        .controlSize(.small)
        .tint(.secondary)
    } else {
      // Overlaid on a shape for the same reason as `ContentMediaPlaceholder`:
      // a spinner's ideal size would otherwise collapse the reserved box.
      Rectangle()
        .fill(.clear)
        .aspectRatio(1, contentMode: .fit)
        .overlay {
          ProgressView()
            .controlSize(.small)
            .tint(.secondary)
        }
    }
  }
}

struct ContentMediaPlaceholder: View {

  let systemImage: String
  let aspectRatio: CGFloat

  init(
    systemImage: String,
    aspectRatio: CGFloat = 1
  ) {
    self.systemImage = systemImage
    self.aspectRatio = aspectRatio
  }

  /// The symbol is overlaid on a flexible shape rather than sized directly.
  ///
  /// `aspectRatio` derives an unspecified dimension from the subview's ideal
  /// size, and a symbol's ideal size is only a few dozen points. Anchoring the
  /// ratio to a shape that accepts any proposal keeps the reserved box tied to
  /// the available width instead of collapsing to glyph size.
  var body: some View {
    Rectangle()
      .fill(.clear)
      .aspectRatio(aspectRatio, contentMode: .fit)
      .overlay {
        Image(systemName: systemImage)
          .font(.system(size: 34, weight: .semibold))
          .foregroundStyle(.appOnSecondaryContainer.opacity(0.42))
      }
  }
}

/// Reads encoded image dimensions without decoding the full raster.
///
/// Persisted `pixelWidth` and `pixelHeight` remain the primary layout metadata.
/// Header inspection keeps placeholders for older photo resources stable until
/// those records can be rewritten with explicit dimensions.
enum EncodedImageDimensions {

  static func displayAspectRatio(from data: Data?) -> CGFloat? {
    guard let data,
      let source = CGImageSourceCreateWithData(
        data as CFData,
        [kCGImageSourceShouldCache: false] as CFDictionary
      )
    else {
      return nil
    }

    return displayAspectRatio(from: source)
  }

  static func displayAspectRatio(at fileURL: URL?) -> CGFloat? {
    guard let fileURL,
      let source = CGImageSourceCreateWithURL(
        fileURL as CFURL,
        [kCGImageSourceShouldCache: false] as CFDictionary
      )
    else {
      return nil
    }

    return displayAspectRatio(from: source)
  }

  private static func displayAspectRatio(
    from source: CGImageSource
  ) -> CGFloat? {
    guard
      let properties = CGImageSourceCopyPropertiesAtIndex(
        source,
        0,
        nil
      ) as? [CFString: Any],
      let pixelWidth = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?
        .doubleValue,
      let pixelHeight = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?
        .doubleValue
    else {
      return nil
    }

    let orientation = (properties[kCGImagePropertyOrientation] as? NSNumber)?
      .uint32Value
    let swapsDimensions = orientation.map { (5...8).contains($0) } ?? false
    let displaySize =
      swapsDimensions
      ? CGSize(width: pixelHeight, height: pixelWidth)
      : CGSize(width: pixelWidth, height: pixelHeight)
    return displaySize.contentAspectRatio
  }
}

/// Immediately renders image data that is already detached from file loading.
///
/// File-backed interactive surfaces decode in cancellable tasks. Detached
/// in-memory content can also be consumed by one-shot rasterizers that do not
/// wait for SwiftUI lifecycle tasks before capturing their first frame.
struct InlineImageDataContentView: View {

  let imageData: Data?
  let fallbackSystemImage: String

  var body: some View {
    if let image = imageData.flatMap(UIImage.init(data:)) {
      Image(uiImage: image)
        .resizable()
        .scaledToFit()
    } else {
      Image(systemName: fallbackSystemImage)
        .font(.system(size: 34, weight: .semibold))
        .foregroundStyle(.appOnSecondaryContainer.opacity(0.42))
    }
  }
}

/// Stable authored-media geometry shared by loading and rendered states.
///
/// The frame derives its height from the proposed width before an asynchronous
/// poster, still, drawing, or player is ready. It describes media geometry only;
/// it does not know whether the content is shown in Home or exported by Share.
struct ContentMediaFrame<Content: View>: View {

  let aspectRatio: CGFloat
  private let content: Content

  init(
    aspectRatio: CGFloat,
    @ViewBuilder content: () -> Content
  ) {
    self.aspectRatio = aspectRatio
    self.content = content()
  }

  var body: some View {
    Rectangle()
      .fill(.clear)
      .aspectRatio(aspectRatio, contentMode: .fit)
      .overlay {
        content
      }
  }
}

extension CGSize {

  /// Width divided by height when both persisted dimensions are usable.
  var contentAspectRatio: CGFloat? {
    guard width.isFinite,
      height.isFinite,
      width > 0,
      height > 0
    else {
      return nil
    }

    return width / height
  }
}

extension UIImage {

  /// Best-effort display ratio for decoded thumbnails and original images.
  var contentAspectRatio: CGFloat {
    size.contentAspectRatio ?? 1
  }
}

/// File-system reader used by preview views from SwiftUI lifecycle tasks.
enum ContentMediaFileReader {

  @concurrent
  nonisolated static func image(from data: Data?) async -> UIImage? {
    guard let data else {
      return nil
    }

    guard let image = UIImage(data: data) else {
      return nil
    }

    #if canImport(UIKit)
      if let preparedImage = await image.byPreparingForDisplay() {
        return preparedImage
      }
    #endif

    return image

  }

  @concurrent
  nonisolated static func image(at fileURL: URL) async -> UIImage? {
    guard FileManager.default.fileExists(atPath: fileURL.path),
      let data = try? Data(contentsOf: fileURL),
      let image = UIImage(data: data)
    else {
      return nil
    }

    #if canImport(UIKit)
      if let preparedImage = await image.byPreparingForDisplay() {
        return preparedImage
      }
    #endif

    return image
  }

  @concurrent
  nonisolated static func fileExists(at fileURL: URL) async -> Bool {
    FileManager.default.fileExists(atPath: fileURL.path)
  }

  @concurrent
  nonisolated static func isPlayableMediaURL(_ url: URL) async -> Bool {

    guard url.isFileURL else {
      return true
    }

    return await fileExists(at: url)
  }

  @concurrent
  nonisolated static func data(from fileURL: URL) async -> Data? {
    try? Data(contentsOf: fileURL)
  }
}
