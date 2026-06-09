//
//  SubtitleScrollEdgeMask.swift
//  YouTubeSubtitle
//

import ScrollEdgeEffect
import SwiftUI
import UIKit

// MARK: - Subtitle Scroll Edge Mask

/// Shared edge-mask configuration for scrollable subtitle readers.
///
/// The cell-based list can use `scrollEdgeEffect` directly. The TextKit 2 reader
/// reports UIKit scroll visibility and uses the same mask view manually.
enum SubtitleScrollEdgeMask {
  /// Edges that should fade for vertical subtitle content.
  static let edges: Edge.Set = [.top, .bottom]

  /// Distance in points over which subtitle content fades into the player surface.
  static let length: CGFloat = 40

  /// Distance from an edge that still counts as being scrolled to that edge.
  static let threshold: CGFloat = 1

  /// Animation used when a fade appears or disappears at a scroll boundary.
  static let animation: Animation? = .spring
}

extension ScrollEdgeEffect.Visibility {
  /// Creates edge-fade visibility from a UIKit vertical scroll view.
  ///
  /// This bridges `UITextView`-backed subtitle rendering to the package's SwiftUI
  /// mask without changing the TextKit 2 layout or scroll ownership.
  init(
    verticalScrollView scrollView: UIScrollView,
    threshold: CGFloat = SubtitleScrollEdgeMask.threshold
  ) {
    let visibleMinY = scrollView.contentOffset.y + scrollView.adjustedContentInset.top
    let visibleHeight = max(
      scrollView.bounds.height
        - scrollView.adjustedContentInset.top
        - scrollView.adjustedContentInset.bottom,
      0
    )
    let visibleMaxY = visibleMinY + visibleHeight
    let contentHeight = scrollView.contentSize.height

    self.init(
      showsTop: visibleMinY > threshold,
      showsBottom: visibleMaxY < contentHeight - threshold
    )
  }
}
