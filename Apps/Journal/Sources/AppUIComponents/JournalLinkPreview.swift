@preconcurrency import LinkPresentation
import SwiftUI
#if canImport(UIKit)
import UIKit
#elseif canImport(AppKit)
import AppKit
#endif

/// SwiftUI wrapper around iOS's native rich link preview.
///
/// `LPLinkView` owns the visual treatment. This view only fetches and caches
/// `LPLinkMetadata` for the current app session, then falls back to a small URL
/// placeholder when metadata is unavailable.
public struct JournalLinkPreview: View {

  let url: URL

  @State private var metadata: LPLinkMetadata?
  @State private var fetchState: LinkPreviewFetchState = .idle

  public init(
    url: URL
  ) {
    self.url = url
  }

  public var body: some View {
    ZStack(alignment: .bottomTrailing) {
      LinkPreviewRepresentable(
        url: url,
        metadata: metadata
      )

      if fetchState == .failed {
        Label("Preview unavailable", systemImage: "exclamationmark.triangle")
          .font(.caption2.weight(.semibold))
          .padding(.horizontal, 8)
          .padding(.vertical, 5)
          .background(.regularMaterial, in: Capsule())
          .padding(8)
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .task(id: url) {
      await loadMetadata()
    }
  }

  @MainActor
  private func loadMetadata() async {
    if let cachedMetadata = LinkPreviewMetadataCache.metadata(for: url) {
      metadata = cachedMetadata
      fetchState = .loaded
      return
    }

    fetchState = .loading
    let provider = LPMetadataProvider()
    provider.timeout = 8
    provider.shouldFetchSubresources = true

    do {
      let fetchedMetadata = try await provider.startFetchingMetadata(for: url)
      LinkPreviewMetadataCache.store(fetchedMetadata, for: url)
      metadata = fetchedMetadata
      fetchState = .loaded
    } catch is CancellationError {
      provider.cancel()
    } catch {
      fetchState = .failed
    }
  }
}

private enum LinkPreviewFetchState: Hashable {
  case idle
  case loading
  case loaded
  case failed
}

@MainActor
private enum LinkPreviewMetadataCache {

  private static var metadataByURL: [URL: LPLinkMetadata] = [:]

  static func metadata(for url: URL) -> LPLinkMetadata? {
    metadataByURL[url]
  }

  static func store(_ metadata: LPLinkMetadata, for url: URL) {
    metadataByURL[url] = metadata
  }
}

#if canImport(UIKit)
private struct LinkPreviewRepresentable: UIViewRepresentable {

  let url: URL
  let metadata: LPLinkMetadata?

  func makeUIView(context: Context) -> LinkPreviewContainerView {
    LinkPreviewContainerView(metadata: metadata ?? Self.placeholderMetadata(for: url))
  }

  func updateUIView(_ uiView: LinkPreviewContainerView, context: Context) {
    uiView.metadata = metadata ?? Self.placeholderMetadata(for: url)
  }

  private static func placeholderMetadata(for url: URL) -> LPLinkMetadata {
    let metadata = LPLinkMetadata()
    metadata.originalURL = url
    metadata.url = url
    metadata.title = url.host(percentEncoded: false) ?? url.absoluteString
    return metadata
  }
}

/// Width-constrained host for `LPLinkView`.
///
/// `LPLinkView` has an intrinsic UIKit layout that can be wider than a SwiftUI
/// grid tile. The container pins it to the proposed card width and clips the
/// subtree so rich previews cannot draw over neighboring cards.
private final class LinkPreviewContainerView: UIView {

  private let linkView: LPLinkView

  var metadata: LPLinkMetadata {
    didSet {
      linkView.metadata = metadata
      linkView.invalidateIntrinsicContentSize()
      invalidateIntrinsicContentSize()
      setNeedsLayout()
    }
  }

  init(metadata: LPLinkMetadata) {
    self.metadata = metadata
    self.linkView = LPLinkView(metadata: metadata)

    super.init(frame: .zero)

    backgroundColor = .clear

    linkView.translatesAutoresizingMaskIntoConstraints = false
    linkView.setContentHuggingPriority(.defaultLow, for: .horizontal)
    linkView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    linkView.setContentHuggingPriority(.defaultLow, for: .vertical)
    linkView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)

    addSubview(linkView)
    NSLayoutConstraint.activate([
      linkView.leadingAnchor.constraint(equalTo: leadingAnchor),
      linkView.trailingAnchor.constraint(equalTo: trailingAnchor),
      linkView.topAnchor.constraint(equalTo: topAnchor),
      linkView.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override var intrinsicContentSize: CGSize {
    CGSize(width: UIView.noIntrinsicMetric, height: UIView.noIntrinsicMetric)
  }
}
#elseif canImport(AppKit)
private struct LinkPreviewRepresentable: NSViewRepresentable {
  let url: URL
  let metadata: LPLinkMetadata?

  func makeNSView(context: Context) -> LinkPreviewContainerView {
    LinkPreviewContainerView(metadata: metadata ?? Self.placeholderMetadata(for: url))
  }

  func updateNSView(_ nsView: LinkPreviewContainerView, context: Context) {
    nsView.metadata = metadata ?? Self.placeholderMetadata(for: url)
  }

  private static func placeholderMetadata(for url: URL) -> LPLinkMetadata {
    let metadata = LPLinkMetadata()
    metadata.originalURL = url
    metadata.url = url
    metadata.title = url.host(percentEncoded: false) ?? url.absoluteString
    return metadata
  }
}

/// Width-constrained native AppKit host for `LPLinkView`.
private final class LinkPreviewContainerView: NSView {
  private let linkView: LPLinkView

  var metadata: LPLinkMetadata {
    didSet {
      linkView.metadata = metadata
      linkView.invalidateIntrinsicContentSize()
      invalidateIntrinsicContentSize()
      needsLayout = true
    }
  }

  init(metadata: LPLinkMetadata) {
    self.metadata = metadata
    self.linkView = LPLinkView(metadata: metadata)
    super.init(frame: .zero)

    wantsLayer = true
    layer?.backgroundColor = NSColor.clear.cgColor
    linkView.translatesAutoresizingMaskIntoConstraints = false
    linkView.setContentHuggingPriority(.defaultLow, for: .horizontal)
    linkView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    linkView.setContentHuggingPriority(.defaultLow, for: .vertical)
    linkView.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
    addSubview(linkView)
    NSLayoutConstraint.activate([
      linkView.leadingAnchor.constraint(equalTo: leadingAnchor),
      linkView.trailingAnchor.constraint(equalTo: trailingAnchor),
      linkView.topAnchor.constraint(equalTo: topAnchor),
      linkView.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override var intrinsicContentSize: NSSize {
    NSSize(width: NSView.noIntrinsicMetric, height: NSView.noIntrinsicMetric)
  }
}
#endif
