@preconcurrency import LinkPresentation
import SwiftUI
import UIKit

/// SwiftUI wrapper around iOS's native rich link preview.
///
/// `LPLinkView` owns the visual treatment. This view only fetches and caches
/// `LPLinkMetadata` for the current app session, then falls back to a small URL
/// placeholder when metadata is unavailable.
struct JournalLinkPreview: View {

  /// The layout density used by card summaries and detail cards.
  enum Mode: Hashable, Sendable {
    /// Compact preview sized for grid tiles and draft summaries.
    case summary

    /// Larger preview sized for the saved-card detail surface.
    case detail
  }

  let url: URL
  let mode: Mode

  @State private var metadata: LPLinkMetadata?
  @State private var fetchState: LinkPreviewFetchState = .idle

  var body: some View {
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
    .frame(maxWidth: .infinity)
    .frame(height: previewHeight)
    .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
    .task(id: url) {
      await loadMetadata()
    }
  }

  private var previewHeight: CGFloat {
    switch mode {
    case .summary:
      return 112
    case .detail:
      return 220
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

private struct LinkPreviewRepresentable: UIViewRepresentable {

  let url: URL
  let metadata: LPLinkMetadata?

  func makeUIView(context: Context) -> LPLinkView {
    LPLinkView(metadata: metadata ?? Self.placeholderMetadata(for: url))
  }

  func updateUIView(_ uiView: LPLinkView, context: Context) {
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
