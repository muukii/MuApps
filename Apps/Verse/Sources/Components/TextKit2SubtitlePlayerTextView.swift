//
//  TextKit2SubtitlePlayerTextView.swift
//  YouTubeSubtitle
//
//  Production TextKit 2 subtitle reader for the player screen.
//

import ScrollEdgeEffect
import SwiftUI
import UIKit

// MARK: - TextKit2SubtitlePlayerTextView

/// A single-scroll-surface subtitle reader backed by an explicit TextKit 2 stack.
///
/// The view keeps subtitle layout, highlighting, selection, and cue-centered
/// auto-scroll in one UIKit surface so SwiftUI does not need to reconcile many
/// per-cue cells while playback time changes.
final class TextKit2SubtitlePlayerTextView: UITextView {

  // MARK: Callbacks

  /// Called when the user taps a cue or a timed word.
  var onTapAtTime: ((Double) -> Void)?

  /// Called when the user chooses the selection action from the edit menu.
  var onSelectText: ((_ text: String, _ context: String) -> Void)?

  /// Called when the user taps the action attachment below a cue.
  var onActionButton: ((_ cueID: Int, _ cueText: String) -> Void)?

  /// Called when direct user interaction should pause automatic scroll tracking.
  var onTrackingShouldPause: (() -> Void)?

  /// Called when the visible scroll edges change enough to update the SwiftUI mask.
  var onScrollEdgeVisibilityChange: ((ScrollEdgeEffect.Visibility) -> Void)?

  // MARK: TextKit 2 Stack

  private let managedTextContentStorage: NSTextContentStorage
  private let managedTextLayoutManager: NSTextLayoutManager
  private let managedTextContainer: NSTextContainer

  // MARK: Styling

  private let textFont = UIFont.systemFont(ofSize: 18, weight: .bold)
  private let playedTextColor = UIColor.tintColor
  private let unplayedTextColor = UIColor.tintColor.withAlphaComponent(0.4)
  private let lineSpacing: CGFloat = 10
  private let paragraphSpacing: CGFloat = 18

  // MARK: State

  private var cues: [Subtitle.Cue] = []
  private var cueRanges: [CueTextRange] = []
  private var wordRanges: [WordTextRange] = []
  private var actionRanges: [CueActionTextRange] = []
  private var displayedCueID: Subtitle.Cue.ID?
  private var pendingScroll: PendingScroll?
  private var cueRenderingStates: [Int: TextRenderingState] = [:]
  private var wordRenderingStates: [TextRangeKey: TextRenderingState] = [:]
  private var cueIDsUsingWordTiming: Set<Int> = []
  private var isAutoScrollSuppressedByUser = false
  private var isAdjustingSelection = false
  private var isPerformingProgrammaticScroll = false
  private var scrollEdgeVisibility = ScrollEdgeEffect.Visibility.hidden
  private var resetProgrammaticScrollTask: Task<Void, Never>?

  // MARK: Initialization

  override init(frame: CGRect, textContainer: NSTextContainer?) {
    let contentStorage = NSTextContentStorage()
    let layoutManager = NSTextLayoutManager()
    let container = NSTextContainer()

    container.widthTracksTextView = true
    container.lineFragmentPadding = 0
    contentStorage.addTextLayoutManager(layoutManager)
    layoutManager.textContainer = container

    managedTextContentStorage = contentStorage
    managedTextLayoutManager = layoutManager
    managedTextContainer = container

    super.init(frame: frame, textContainer: container)

    precondition(
      isUsingManagedTextKit2Stack,
      "TextKit2SubtitlePlayerTextView must be backed by its managed TextKit 2 stack."
    )

    setupTextView()
  }

  convenience init() {
    self.init(frame: .zero, textContainer: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  deinit {
    resetProgrammaticScrollTask?.cancel()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    flushPendingScrollIfPossible()
    updateScrollEdgeVisibility()
  }

  // MARK: Public API

  /// Returns whether the view is still attached to the TextKit 2 objects it created.
  var isUsingManagedTextKit2Stack: Bool {
    textLayoutManager === managedTextLayoutManager
      && (managedTextLayoutManager.textContentManager as? NSTextContentStorage) === managedTextContentStorage
      && managedTextLayoutManager.textContainer === managedTextContainer
  }

  /// Replaces the displayed subtitle document.
  func setCues(_ newCues: [Subtitle.Cue]) {
    guard cues != newCues else { return }

    cues = newCues
    displayedCueID = nil
    pendingScroll = nil
    cueRenderingStates = [:]
    wordRenderingStates = [:]
    cueIDsUsingWordTiming = []
    selectedRange = .init(location: 0, length: 0)

    let document = makeSubtitleDocument(cues: newCues)
    cueRanges = document.cueRanges
    wordRanges = document.wordRanges
    actionRanges = document.actionRanges
    cueIDsUsingWordTiming = Set(document.wordRanges.map(\.cueID))
    attributedText = document.attributedString

    assert(isUsingManagedTextKit2Stack)
    setNeedsLayout()
    updateScrollEdgeVisibility()
  }

  /// Updates time-based rendering and optionally schedules a scroll to the current cue.
  ///
  /// - Parameters:
  ///   - currentTime: Playback position in seconds.
  ///   - currentCueID: Cue identity calculated by `PlayerModel`.
  ///   - tracksCurrentCue: Whether automatic scroll tracking is enabled.
  ///   - forcesScroll: Whether to scroll even when the cue identity did not change.
  func setPlaybackState(
    currentTime: Double,
    currentCueID: Subtitle.Cue.ID?,
    tracksCurrentCue: Bool,
    forcesScroll: Bool
  ) {
    let cueChanged = currentCueID != displayedCueID
    displayedCueID = currentCueID

    if forcesScroll {
      isAutoScrollSuppressedByUser = false
    }

    let allowsAutoScroll = tracksCurrentCue && !isAutoScrollSuppressedByUser
    let shouldScroll = allowsAutoScroll && currentCueID != nil && (cueChanged || forcesScroll)

    updateRenderingAttributes(
      currentTime: currentTime,
      preservesContentOffset: !shouldScroll && canPreserveContentOffsetDuringRendering
    )

    guard shouldScroll, let currentCueID else {
      return
    }

    requestScrollToCue(id: currentCueID, animated: true)
  }

  // MARK: Setup

  private func setupTextView() {
    isEditable = false
    isSelectable = true
    isScrollEnabled = true
    backgroundColor = .clear
    textContainerInset = UIEdgeInsets(top: 16, left: 20, bottom: 120, right: 20)
    textContainer.lineFragmentPadding = 0
    textDragInteraction?.isEnabled = false
    showsVerticalScrollIndicator = true
    showsHorizontalScrollIndicator = false
    alwaysBounceVertical = true
    canCancelContentTouches = true
    delaysContentTouches = false
    delegate = self

    let tapGesture = UITapGestureRecognizer(
      target: self,
      action: #selector(handleTap(_:))
    )
    tapGesture.delegate = self
    tapGesture.cancelsTouchesInView = false

    for gesture in gestureRecognizers ?? [] {
      if let longPress = gesture as? UILongPressGestureRecognizer {
        tapGesture.require(toFail: longPress)
      }
    }

    addGestureRecognizer(tapGesture)
  }

  // MARK: Document Building

  private func makeSubtitleDocument(cues: [Subtitle.Cue]) -> SubtitleTextDocument {
    let result = NSMutableAttributedString()
    var cueRanges: [CueTextRange] = []
    var wordRanges: [WordTextRange] = []
    var actionRanges: [CueActionTextRange] = []

    let paragraphStyle = NSMutableParagraphStyle()
    paragraphStyle.lineSpacing = lineSpacing
    paragraphStyle.paragraphSpacing = paragraphSpacing
    paragraphStyle.lineBreakMode = .byWordWrapping

    for (index, cue) in cues.enumerated() {
      let cueText = cue.decodedText
      let cueStartLocation = result.length
      let cueRange = NSRange(
        location: cueStartLocation,
        length: (cueText as NSString).length
      )

      result.append(NSAttributedString(
        string: cueText,
        attributes: [
          .font: textFont,
          .foregroundColor: unplayedTextColor,
          .paragraphStyle: paragraphStyle,
        ]
      ))

      cueRanges.append(CueTextRange(
        cueID: cue.id,
        cueText: cueText,
        range: cueRange,
        startTime: cue.startTime,
        endTime: cue.endTime
      ))

      if let timings = cue.wordTimings, !timings.isEmpty {
        wordRanges.append(contentsOf: makeWordRanges(
          cueID: cue.id,
          cueText: cueText,
          cueStartLocation: cueStartLocation,
          timings: timings
        ))
      }

      result.append(NSAttributedString(string: "\n"))
      let actionLocation = result.length
      result.append(NSAttributedString(attachment: TextKit2SubtitleCueActionAttachment(
        cueID: cue.id,
        cueText: cueText
      )))
      actionRanges.append(CueActionTextRange(
        cueID: cue.id,
        cueText: cueText,
        range: NSRange(location: actionLocation, length: 1)
      ))

      if index < cues.count - 1 {
        result.append(NSAttributedString(string: "\n"))
      }
    }

    return SubtitleTextDocument(
      attributedString: result,
      cueRanges: cueRanges,
      wordRanges: wordRanges,
      actionRanges: actionRanges
    )
  }

  private func makeWordRanges(
    cueID: Int,
    cueText: String,
    cueStartLocation: Int,
    timings: [Subtitle.WordTiming]
  ) -> [WordTextRange] {
    var ranges: [WordTextRange] = []
    var searchStartIndex = cueText.startIndex

    for timing in timings {
      guard let range = cueText.range(
        of: timing.text,
        range: searchStartIndex..<cueText.endIndex
      ) else {
        continue
      }

      let localRange = NSRange(range, in: cueText)
      ranges.append(WordTextRange(
        cueID: cueID,
        range: NSRange(
          location: cueStartLocation + localRange.location,
          length: localRange.length
        ),
        startTime: timing.startTime,
        endTime: timing.endTime
      ))
      searchStartIndex = range.upperBound
    }

    return ranges
  }

  // MARK: Rendering

  private var canPreserveContentOffsetDuringRendering: Bool {
    !isPerformingProgrammaticScroll
      && !isTracking
      && !isDragging
      && !isDecelerating
      && pendingScroll == nil
  }

  private func updateRenderingAttributes(
    currentTime: Double,
    preservesContentOffset: Bool
  ) {
    guard textStorage.length > 0 else { return }

    let contentOffsetBeforeRendering = contentOffset
    var didUpdateAttributes = false

    textStorage.beginEditing()
    defer {
      textStorage.endEditing()

      if preservesContentOffset, didUpdateAttributes {
        restoreContentOffset(contentOffsetBeforeRendering)
      }
    }

    for cueRange in cueRanges {
      guard NSMaxRange(cueRange.range) <= textStorage.length else { continue }
      guard !cueIDsUsingWordTiming.contains(cueRange.cueID) else { continue }

      let state = TextRenderingState(time: currentTime, startsAt: cueRange.startTime)
      guard cueRenderingStates[cueRange.cueID] != state else { continue }

      cueRenderingStates[cueRange.cueID] = state
      didUpdateAttributes = true
      textStorage.addAttribute(.foregroundColor, value: color(for: state), range: cueRange.range)
    }

    for wordRange in wordRanges {
      guard NSMaxRange(wordRange.range) <= textStorage.length else { continue }
      let state = TextRenderingState(time: currentTime, startsAt: wordRange.startTime)
      let key = TextRangeKey(range: wordRange.range)
      guard wordRenderingStates[key] != state else { continue }

      wordRenderingStates[key] = state
      didUpdateAttributes = true
      textStorage.addAttribute(.foregroundColor, value: color(for: state), range: wordRange.range)
    }
  }

  private func color(for renderingState: TextRenderingState) -> UIColor {
    switch renderingState {
    case .played:
      return playedTextColor
    case .unplayed:
      return unplayedTextColor
    }
  }

  private func restoreContentOffset(_ offset: CGPoint) {
    let minY = -adjustedContentInset.top
    let maxY = max(minY, contentSize.height - bounds.height + adjustedContentInset.bottom)
    let clampedOffset = CGPoint(
      x: offset.x,
      y: min(max(offset.y, minY), maxY)
    )

    guard abs(contentOffset.y - clampedOffset.y) > 0.5 else { return }

    UIView.performWithoutAnimation {
      setContentOffset(clampedOffset, animated: false)
    }
  }

  // MARK: Scroll Tracking

  private func requestScrollToCue(id cueID: Int, animated: Bool) {
    pendingScroll = PendingScroll(cueID: cueID, animated: animated)
    flushPendingScrollIfPossible()
  }

  private func flushPendingScrollIfPossible() {
    guard let pendingScroll else { return }
    guard window != nil, bounds.width > 0, bounds.height > 0 else { return }

    layoutIfNeeded()

    guard let cueRect = contentRectForCue(id: pendingScroll.cueID),
          cueRect.height > 0 else {
      setNeedsLayout()
      return
    }

    self.pendingScroll = nil
    scrollToContentRect(cueRect, animated: pendingScroll.animated)
  }

  private func contentRectForCue(id cueID: Int) -> CGRect? {
    guard let cueRange = cueRanges.first(where: { $0.cueID == cueID }) else {
      return nil
    }

    let rect = contentRects(for: cueRange.range).reduce(CGRect.null) { partial, rect in
      partial.union(rect)
    }

    return rect.isNull ? nil : rect
  }

  private func scrollToContentRect(_ rect: CGRect, animated: Bool) {
    let visibleHeight = max(bounds.height - adjustedContentInset.top - adjustedContentInset.bottom, 1)
    let targetY = rect.midY - visibleHeight * 0.42 - adjustedContentInset.top
    let minY = -adjustedContentInset.top
    let maxY = max(minY, contentSize.height - bounds.height + adjustedContentInset.bottom)
    let clampedY = min(max(targetY, minY), maxY)
    let targetOffset = CGPoint(x: contentOffset.x, y: clampedY)

    resetProgrammaticScrollTask?.cancel()
    isPerformingProgrammaticScroll = true

    if animated {
      setContentOffset(targetOffset, animated: true)
      resetProgrammaticScrollTask = Task { @MainActor [weak self] in
        try? await Task.sleep(for: .milliseconds(500))
        self?.isPerformingProgrammaticScroll = false
      }
    } else {
      setContentOffset(targetOffset, animated: false)
      isPerformingProgrammaticScroll = false
    }

    updateScrollEdgeVisibility()
  }

  private func updateScrollEdgeVisibility() {
    let nextVisibility = ScrollEdgeEffect.Visibility(verticalScrollView: self)
    guard nextVisibility != scrollEdgeVisibility else { return }

    scrollEdgeVisibility = nextVisibility
    onScrollEdgeVisibilityChange?(nextVisibility)
  }

  private func pauseAutoScrollForUserInteraction() {
    isAutoScrollSuppressedByUser = true
    pendingScroll = nil
    resetProgrammaticScrollTask?.cancel()
    resetProgrammaticScrollTask = nil
    isPerformingProgrammaticScroll = false
    let visibleOffset = layer.presentation()?.bounds.origin ?? contentOffset
    layer.removeAllAnimations()
    setContentOffset(visibleOffset, animated: false)
    onTrackingShouldPause?()
  }

  // MARK: TextKit 2 Geometry

  private func contentRects(for nsRange: NSRange) -> [CGRect] {
    guard NSMaxRange(nsRange) <= textStorage.length,
          let textRange = textRange(for: nsRange) else {
      return []
    }

    managedTextLayoutManager.ensureLayout(for: textRange)

    var rects: [CGRect] = []
    managedTextLayoutManager.enumerateTextSegments(
      in: textRange,
      type: .highlight,
      options: []
    ) { _, rect, _, _ in
      rects.append(rect.offsetBy(
        dx: textContainerInset.left,
        dy: textContainerInset.top
      ))
      return true
    }

    return rects
  }

  private func textRange(for nsRange: NSRange) -> NSTextRange? {
    let content = managedTextContentStorage
    let documentStart = content.documentRange.location

    guard let start = content.location(documentStart, offsetBy: nsRange.location),
          let end = content.location(start, offsetBy: nsRange.length) else {
      return nil
    }

    return NSTextRange(location: start, end: end)
  }

  // MARK: Interaction

  @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
    guard gesture.state == .ended else { return }

    let point = gesture.location(in: self)
    if let actionRange = actionRange(containingActionButtonAt: point) {
      onActionButton?(actionRange.cueID, actionRange.cueText)
      return
    }

    guard let position = closestPosition(to: point) else { return }

    let offset = self.offset(from: beginningOfDocument, to: position)
    guard offset >= 0, offset < textStorage.length else { return }

    let attributes = textStorage.attributes(at: offset, effectiveRange: nil)
    if attributes[.attachment] is TextKit2SubtitleCueActionAttachment {
      return
    }

    if let wordRange = wordRanges.first(where: { NSLocationInRange(offset, $0.range) }) {
      onTapAtTime?(wordRange.startTime)
      return
    }

    if let cueRange = cueRanges.first(where: { NSLocationInRange(offset, $0.range) }) {
      onTapAtTime?(cueRange.startTime)
    }
  }

  private func actionRange(containingActionButtonAt point: CGPoint) -> CueActionTextRange? {
    actionRanges.first { actionRange in
      guard let buttonRect = actionButtonRect(for: actionRange) else {
        return false
      }

      return buttonRect.contains(point)
    }
  }

  private func actionButtonRect(for actionRange: CueActionTextRange) -> CGRect? {
    let attachmentRect = contentRects(for: actionRange.range).reduce(CGRect.null) { partial, rect in
      partial.union(rect)
    }

    guard !attachmentRect.isNull else { return nil }
    return TextKit2SubtitleCueActionView.actionButtonRect(in: attachmentRect)
  }

  private func selectedText(in range: NSRange) -> String? {
    guard range.length > 0,
          let text,
          let swiftRange = Range(range, in: text) else {
      return nil
    }

    let selectedText = String(text[swiftRange])
      .trimmingCharacters(in: .whitespacesAndNewlines)

    return selectedText.isEmpty ? nil : selectedText
  }

  private func cueContext(for range: NSRange) -> String {
    for cueRange in cueRanges {
      if NSIntersectionRange(range, cueRange.range).length > 0 {
        return cueRange.cueText
      }
    }

    return selectedText(in: range) ?? ""
  }

  private func snapSelectionToWordBoundaries() {
    guard selectedRange.length > 0,
          let text else {
      return
    }

    let nextRange = WordBoundary.snapToWordBoundaries(in: text, range: selectedRange)
    guard nextRange != selectedRange, nextRange.length > 0 else { return }

    isAdjustingSelection = true
    selectedRange = nextRange
    isAdjustingSelection = false
  }
}

// MARK: - UITextViewDelegate

extension TextKit2SubtitlePlayerTextView: UITextViewDelegate {
  func textViewDidChangeSelection(_ textView: UITextView) {
    guard selectedRange.length > 0 else { return }

    if !isAdjustingSelection {
      snapSelectionToWordBoundaries()
    }

    pauseAutoScrollForUserInteraction()
  }

  @available(iOS 16.0, *)
  func textView(
    _ textView: UITextView,
    editMenuForTextIn range: NSRange,
    suggestedActions: [UIMenuElement]
  ) -> UIMenu? {
    guard let selectedText = selectedText(in: range) else {
      return UIMenu(children: suggestedActions)
    }

    let actionsItem = UIAction(
      title: "Actions...",
      image: UIImage(systemName: "ellipsis.circle")
    ) { [weak self] _ in
      self?.onSelectText?(selectedText, self?.cueContext(for: range) ?? selectedText)
    }

    return UIMenu(children: [actionsItem] + suggestedActions)
  }

  func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
    pauseAutoScrollForUserInteraction()
  }

  func scrollViewDidScroll(_ scrollView: UIScrollView) {
    updateScrollEdgeVisibility()
  }

  func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
    isPerformingProgrammaticScroll = false
    updateScrollEdgeVisibility()
  }
}

// MARK: - UIGestureRecognizerDelegate

extension TextKit2SubtitlePlayerTextView: UIGestureRecognizerDelegate {
  func gestureRecognizer(
    _ gestureRecognizer: UIGestureRecognizer,
    shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
  ) -> Bool {
    true
  }

  func gestureRecognizer(
    _ gestureRecognizer: UIGestureRecognizer,
    shouldReceive touch: UITouch
  ) -> Bool {
    return true
  }
}

// MARK: - Supporting Types

/// The attributed subtitle document and its lookup tables.
private struct SubtitleTextDocument {
  let attributedString: NSAttributedString
  let cueRanges: [CueTextRange]
  let wordRanges: [WordTextRange]
  let actionRanges: [CueActionTextRange]
}

/// Text range metadata for a single subtitle cue in the unified attributed string.
private struct CueTextRange {
  let cueID: Int
  let cueText: String
  let range: NSRange
  let startTime: Double
  let endTime: Double
}

/// Text range metadata for a timed word inside a cue.
private struct WordTextRange {
  let cueID: Int
  let range: NSRange
  let startTime: Double
  let endTime: Double
}

/// Text range metadata for the visual action attachment rendered below a cue.
private struct CueActionTextRange {
  let cueID: Int
  let cueText: String
  let range: NSRange
}

/// A compact playback-dependent rendering state for a text range.
private enum TextRenderingState: Equatable {
  case played
  case unplayed

  init(time: Double, startsAt startTime: Double) {
    self = time >= startTime ? .played : .unplayed
  }
}

/// Hashable lookup key for caching rendering state by attributed-string range.
private struct TextRangeKey: Hashable {
  let location: Int
  let length: Int

  init(range: NSRange) {
    location = range.location
    length = range.length
  }
}

/// A pending auto-scroll request that waits until TextKit layout is ready.
private struct PendingScroll {
  let cueID: Int
  let animated: Bool
}

// MARK: - Cue Action Attachment

/// TextKit 2 attachment that renders a visual cue-level action button below a cue.
final class TextKit2SubtitleCueActionAttachment: NSTextAttachment {
  /// Cue identity associated with the action button.
  nonisolated(unsafe) var cueID: Int = 0

  /// Cue text used as the default action-sheet text and context.
  nonisolated(unsafe) var cueText: String = ""

  convenience init(
    cueID: Int,
    cueText: String
  ) {
    self.init()
    self.cueID = cueID
    self.cueText = cueText
  }

  @available(*, unavailable)
  nonisolated required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  nonisolated override init(data contentData: Data?, ofType uti: String?) {
    super.init(data: contentData, ofType: uti)
  }

  nonisolated override func viewProvider(
    for parentView: UIView?,
    location: any NSTextLocation,
    textContainer: NSTextContainer?
  ) -> NSTextAttachmentViewProvider? {
    let provider = TextKit2SubtitleCueActionAttachmentViewProvider(
      textAttachment: self,
      parentView: parentView,
      textLayoutManager: textContainer?.textLayoutManager,
      location: location
    )
    provider.tracksTextAttachmentViewBounds = true
    return provider
  }
}

/// View provider that supplies the noninteractive UIKit action affordance for a cue attachment.
private final class TextKit2SubtitleCueActionAttachmentViewProvider: NSTextAttachmentViewProvider {
  nonisolated override init(
    textAttachment: NSTextAttachment,
    parentView: UIView?,
    textLayoutManager: NSTextLayoutManager?,
    location: any NSTextLocation
  ) {
    super.init(
      textAttachment: textAttachment,
      parentView: parentView,
      textLayoutManager: textLayoutManager,
      location: location
    )
  }

  nonisolated override func loadView() {
    view = MainActor.assumeIsolated {
      TextKit2SubtitleCueActionView()
    }
  }

  nonisolated override func attachmentBounds(
    for attributes: [NSAttributedString.Key: Any],
    location: any NSTextLocation,
    textContainer: NSTextContainer?,
    proposedLineFragment: CGRect,
    position: CGPoint
  ) -> CGRect {
    let width = max(proposedLineFragment.width, 1)
    let height = MainActor.assumeIsolated {
      TextKit2SubtitleCueActionView.measuredHeight(for: width)
    }

    return CGRect(
      x: 0,
      y: 0,
      width: width,
      height: height
    )
  }
}

/// Noninteractive UIKit affordance embedded by TextKit 2 below each cue.
private final class TextKit2SubtitleCueActionView: UIView {
  private static let minimumHeight = TextKit2SubtitleCueActionMetrics.minimumHeight

  private let hostingController = UIHostingController(
    rootView: TextKit2SubtitleCueActionContentView()
  )

  override init(frame: CGRect) {
    super.init(frame: frame)
    setupView()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override var intrinsicContentSize: CGSize {
    CGSize(
      width: UIView.noIntrinsicMetric,
      height: fittingHeight(for: bounds.width)
    )
  }

  func fittingHeight(for _: CGFloat) -> CGFloat {
    Self.minimumHeight
  }

  @MainActor
  static func measuredHeight(for _: CGFloat) -> CGFloat {
    minimumHeight
  }

  @MainActor
  static func actionButtonRect(in attachmentRect: CGRect) -> CGRect {
    let buttonSize = measuredButtonSize()
    let buttonHeight = min(max(buttonSize.height, minimumHeight), attachmentRect.height)

    return CGRect(
      x: attachmentRect.maxX - buttonSize.width,
      y: attachmentRect.midY - buttonHeight / 2,
      width: buttonSize.width,
      height: buttonHeight
    )
  }

  private func setupView() {
    backgroundColor = .clear
    isAccessibilityElement = false
    isUserInteractionEnabled = false

    let hostedView = hostingController.view!
    hostedView.backgroundColor = .clear
    hostedView.isAccessibilityElement = false
    hostedView.isUserInteractionEnabled = false
    hostedView.translatesAutoresizingMaskIntoConstraints = false
    hostedView.setContentHuggingPriority(.required, for: .horizontal)
    hostedView.setContentHuggingPriority(.required, for: .vertical)
    hostedView.setContentCompressionResistancePriority(.required, for: .horizontal)
    hostedView.setContentCompressionResistancePriority(.required, for: .vertical)

    addSubview(hostedView)

    NSLayoutConstraint.activate([
      hostedView.topAnchor.constraint(equalTo: topAnchor),
      hostedView.trailingAnchor.constraint(equalTo: trailingAnchor),
      hostedView.leadingAnchor.constraint(greaterThanOrEqualTo: leadingAnchor),
      hostedView.heightAnchor.constraint(equalToConstant: Self.minimumHeight),
    ])
  }

  @MainActor
  private static func measuredButtonSize() -> CGSize {
    let controller = UIHostingController(
      rootView: TextKit2SubtitleCueActionContentView()
    )
    let size = controller.sizeThatFits(in: CGSize(
      width: 320,
      height: minimumHeight
    ))

    return CGSize(
      width: ceil(size.width),
      height: max(minimumHeight, ceil(size.height))
    )
  }
}

private enum TextKit2SubtitleCueActionMetrics {
  static let minimumHeight: CGFloat = 44
  static let horizontalPadding: CGFloat = 12
  static let labelSpacing: CGFloat = 6
}

/// SwiftUI content for the visual cue action affordance.
private struct TextKit2SubtitleCueActionContentView: View {
  var body: some View {
    HStack(spacing: TextKit2SubtitleCueActionMetrics.labelSpacing) {
      Image(systemName: "ellipsis.circle")
      Text("Actions")
    }
    .font(.body)
    .foregroundStyle(.secondary)
    .padding(.horizontal, TextKit2SubtitleCueActionMetrics.horizontalPadding)
    .frame(minHeight: TextKit2SubtitleCueActionMetrics.minimumHeight)
  }
}
