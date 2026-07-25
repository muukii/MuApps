//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//

import AVFoundation
import BrightroomParametric
import Foundation

/// An immutable snapshot of the videos and shared recipe submitted for export.
///
/// The batch is one continued-processing job. Its items are rendered serially
/// so each source keeps its own color metadata without competing for GPU memory.
nonisolated struct VideoExportBatch: Identifiable {

  /// One source movie in picker order.
  nonisolated struct Item: Identifiable {
    let id: VideoClip.ID
    let displayName: String
    /// Keeps Files authorization alive through detached/background rendering.
    let source: VideoSource
    let colorInfo: VideoColorInfo

    var asset: AVAsset { source.asset }
  }

  let id = UUID()
  let items: [Item]
  let recipe: FargVideoRenderRecipe

  var hdrVideoCount: Int {
    items.count { $0.colorInfo.isHDR }
  }
}

/// Progress for the current movie and the batch as a whole.
nonisolated struct VideoExportBatchProgress: Equatable, Sendable {
  let currentItemIndex: Int
  let itemCount: Int
  let currentItemFraction: Double

  var overallFraction: Double {
    guard itemCount > 0 else { return 0 }
    let completedFraction = Double(currentItemIndex) + currentItemFraction
    return min(max(completedFraction / Double(itemCount), 0), 1)
  }
}

/// The durable result of attempting one movie in a batch.
nonisolated struct VideoExportBatchResult: Identifiable, Equatable, Sendable {

  enum Outcome: Equatable, Sendable {
    /// Rendering succeeded. Photos permission or saving may still have failed.
    case exported(url: URL, savedToPhotos: Bool)
    /// Rendering failed, so no shareable output exists for this item.
    case failed(message: String)
  }

  let id: VideoClip.ID
  let displayName: String
  let outcome: Outcome
}
