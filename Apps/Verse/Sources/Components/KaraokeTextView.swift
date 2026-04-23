//
//  KaraokeTextView.swift
//  YouTubeSubtitle
//
//  Pure UIKit component for displaying subtitles with karaoke-style highlighting.
//  Uses TextKit2 for advanced text layout and supports word-level timing.
//

import CoreMedia
import NaturalLanguage
import SwiftUI
import UIKit

// MARK: - Custom NSAttributedString Keys

extension NSAttributedString.Key {
  static let cueID = NSAttributedString.Key("cueID")
  static let cueStartTime = NSAttributedString.Key("cueStartTime")
  static let wordStartTime = NSAttributedString.Key("wordStartTime")
  static let wordEndTime = NSAttributedString.Key("wordEndTime")
}

// MARK: - Cue Action Callback Registry

/// Global callback registry for CueActionView button taps.
/// Uses nonisolated(unsafe) since UIKit operations are main-thread only.
enum CueActionCallback {
  nonisolated(unsafe) static var handler: ((Int, String) -> Void)?
}

// MARK: - Cue Action SwiftUI View

/// SwiftUI content view for cue actions
struct CueActionContentView: View {
  let cueID: Int
  let cueText: String

  var body: some View {
    Button {
      CueActionCallback.handler?(cueID, cueText)
    } label: {
      Label("Actions", systemImage: "ellipsis.circle")
        .foregroundStyle(.secondary)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.leading, 12)
  }
}

// MARK: - Cue Action View (UIKit Wrapper)

/// Block-level view displayed below each cue for actions.
/// Wraps a SwiftUI view using UIHostingController.
final class CueActionView: UIView {
  var cueID: Int = 0 {
    didSet { updateContent() }
  }
  var cueText: String = "" {
    didSet { updateContent() }
  }

  private var hostingController: UIHostingController<CueActionContentView>?

  override init(frame: CGRect) {
    super.init(frame: frame)
    setupView()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func setupView() {
    backgroundColor = .clear
    updateContent()
  }

  private func updateContent() {
    // Remove existing hosting controller
    hostingController?.view.removeFromSuperview()
    hostingController?.removeFromParent()

    // Create SwiftUI view
    let contentView = CueActionContentView(cueID: cueID, cueText: cueText)
    let controller = UIHostingController(rootView: contentView)
    controller.view.backgroundColor = .clear
    controller.view.translatesAutoresizingMaskIntoConstraints = false

    addSubview(controller.view)

    NSLayoutConstraint.activate([
      controller.view.topAnchor.constraint(equalTo: topAnchor),
      controller.view.leadingAnchor.constraint(equalTo: leadingAnchor),
      controller.view.trailingAnchor.constraint(equalTo: trailingAnchor),
      controller.view.bottomAnchor.constraint(equalTo: bottomAnchor),
    ])

    hostingController = controller
  }
}

// MARK: - Cue Action Attachment View Provider

/// Provides block-level CueActionView for attachments
final class CueActionAttachmentViewProvider: NSTextAttachmentViewProvider {
  private nonisolated static let viewHeight: CGFloat = 44

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
    // Access attachment properties
    let attachment = textAttachment as? CueActionAttachment
    let cueID = attachment?.cueID ?? 0
    let cueText = attachment?.cueText ?? ""

    // Create view on main thread
    view = MainActor.assumeIsolated {
      let actionView = CueActionView()
      actionView.cueID = cueID
      actionView.cueText = cueText
      return actionView
    }
  }

  nonisolated override func attachmentBounds(
    for attributes: [NSAttributedString.Key: Any],
    location: any NSTextLocation,
    textContainer: NSTextContainer?,
    proposedLineFragment: CGRect,
    position: CGPoint
  ) -> CGRect {
    // Full width, fixed height for block-level display
    CGRect(
      x: 0,
      y: 0,
      width: proposedLineFragment.width,
      height: Self.viewHeight
    )
  }
}

// MARK: - Cue Action Attachment

/// Custom text attachment that embeds a block-level CueActionView below each cue.
/// Uses viewProvider override approach (not registerViewProviderClass).
final class CueActionAttachment: NSTextAttachment {
  /// Cue ID for identifying which cue this attachment belongs to
  nonisolated(unsafe) var cueID: Int = 0
  /// Original cue text for action handling
  nonisolated(unsafe) var cueText: String = ""

  convenience init(cueID: Int, cueText: String) {
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

  // MARK: - ViewProvider Override (Key for TextKit2!)

  nonisolated override func viewProvider(
    for parentView: UIView?,
    location: any NSTextLocation,
    textContainer: NSTextContainer?
  ) -> NSTextAttachmentViewProvider? {
    let provider = CueActionAttachmentViewProvider(
      textAttachment: self,
      parentView: parentView,
      textLayoutManager: textContainer?.textLayoutManager,
      location: location
    )
    provider.tracksTextAttachmentViewBounds = true
    return provider
  }
}

// MARK: - KaraokeTextView

/// UITextView subclass that displays subtitles with karaoke-style word highlighting.
/// Uses TextKit2 for advanced text layout and native scrolling with animation.
final class KaraokeTextView: UITextView {

  // MARK: - Callbacks

  /// Called when user taps on a word or cue (parameter: start time in seconds)
  var onTapAtTime: ((Double) -> Void)?

  /// Called when user selects text (parameters: selected text, context/cue text)
  var onSelectText: ((_ text: String, _ context: String) -> Void)?

  /// Called when user manually scrolls (for disabling auto-tracking)
  var onScroll: (() -> Void)?

  /// Called when user taps the action button for a cue
  var onActionButton: ((_ cueID: Int, _ cueText: String) -> Void)?

  // MARK: - Styling

  private let textFont: UIFont = .systemFont(ofSize: 18, weight: .bold)
  private let playedTextColor: UIColor = .tintColor
  private let unplayedTextColor: UIColor = .tintColor.withAlphaComponent(0.4)
  private let paragraphSpacing: CGFloat = 20
  private let lineSpacing: CGFloat = 10

  // MARK: - State

  private var cues: [Subtitle.Cue] = []
  private var wordRanges: [WordRange] = []
  private var cueRanges: [CueRange] = []
  private var lastScrolledCueID: Int?
  private var lastSelectedText: String?

  // MARK: - Range Types

  struct WordRange {
    let nsRange: NSRange
    let startTime: Double
    let endTime: Double
    let cueID: Int
  }

  struct CueRange {
    let nsRange: NSRange
    let startTime: Double
    let endTime: Double
    let cueID: Int
  }

  // MARK: - Initialization

  override init(frame: CGRect, textContainer: NSTextContainer?) {
    // Create TextKit2 components
    let textLayoutManager = NSTextLayoutManager()
    let textContentStorage = NSTextContentStorage()
    let container = NSTextContainer()

    container.widthTracksTextView = true
    container.lineFragmentPadding = 12

    textContentStorage.addTextLayoutManager(textLayoutManager)
    textLayoutManager.textContainer = container

    super.init(frame: frame, textContainer: container)
    setupTextView()
  }

  convenience init() {
    self.init(frame: .zero, textContainer: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  private func setupTextView() {
    // Verify TextKit2 is being used (not fallback to TextKit1)
    if textLayoutManager == nil {
      assertionFailure(
        "KaraokeTextView requires TextKit2. textLayoutManager is nil, indicating fallback to TextKit1."
      )
      // Log for Release builds where assertions are disabled
      print("⚠️ [KaraokeTextView] WARNING: TextKit1 fallback detected. TextKit2 features will not work correctly.")
    }

    isEditable = false
    isScrollEnabled = true
    backgroundColor = .clear
    textContainerInset = UIEdgeInsets(top: 12, left: 0, bottom: 12, right: 0)
    textDragInteraction?.isEnabled = false
    showsVerticalScrollIndicator = true
    showsHorizontalScrollIndicator = false
    alwaysBounceVertical = true

    delegate = self

    // Set up global callback for CueActionView button taps
    CueActionCallback.handler = { [weak self] cueID, cueText in
      self?.onActionButton?(cueID, cueText)
    }

    // Single tap gesture for word/cue detection
    let tapGesture = UITapGestureRecognizer(
      target: self,
      action: #selector(handleTap(_:))
    )
    tapGesture.delegate = self

    // Make tap gesture require long press to fail first
    for gesture in gestureRecognizers ?? [] {
      if let longPress = gesture as? UILongPressGestureRecognizer {
        tapGesture.require(toFail: longPress)
      }
    }

    addGestureRecognizer(tapGesture)
  }

  // MARK: - Public API

  /// Set the cues to display
  func setCues(_ newCues: [Subtitle.Cue]) {
    guard cues != newCues else { return }

    cues = newCues
    wordRanges = buildWordRanges(from: cues)
    cueRanges = buildCueRanges(from: cues)
    lastScrolledCueID = nil

    // Build and set attributed string
    let attributedString = buildAttributedString(cues: cues, currentTime: 0)
    self.attributedText = attributedString
  }

  /// Update the current playback time (for highlighting)
  func updateCurrentTime(_ time: Double) {
    updateHighlighting(currentTime: time)
  }

  /// Scroll to a specific cue with animation
  func scrollToCue(id: Int, animated: Bool) {
    guard lastScrolledCueID != id else {
      return
    }

    guard let cueRange = cueRanges.first(where: { $0.cueID == id }) else {
      return
    }

    lastScrolledCueID = id

    // Ensure layout is up to date
    layoutIfNeeded()

    // Use UITextInput protocol to get rect in text view coordinates.
    // This is more reliable than NSTextLayoutManager.layoutFragmentFrame which returns
    // coordinates in the text container's coordinate space, requiring manual adjustment
    // for textContainerInset and other offsets.
    guard let startPosition = position(from: beginningOfDocument, offset: cueRange.nsRange.location),
          let endPosition = position(from: startPosition, offset: cueRange.nsRange.length),
          let textRange = textRange(from: startPosition, to: endPosition) else {
      return
    }

    let rect = firstRect(for: textRange)

    // Skip if rect is invalid
    guard !rect.isNull && !rect.isInfinite && rect.height > 0 else {
      lastScrolledCueID = nil
      return
    }

    // Skip if bounds not ready
    guard bounds.height > 0 else {
      lastScrolledCueID = nil
      return
    }

    // Calculate centered position
    let centeredY = rect.origin.y - (bounds.height - rect.height) / 2
    let maxY = max(0, contentSize.height - bounds.height)
    let clampedY = max(0, min(centeredY, maxY))
    let targetOffset = CGPoint(x: 0, y: clampedY)

    // Use UITextView's native animated scroll
    if animated {
      UIView.animate(withDuration: 0.3, delay: 0, options: .curveEaseInOut) {
        self.contentOffset = targetOffset
      }
    } else {
      contentOffset = targetOffset
    }
  }

  /// Reset scroll tracking (e.g., when re-enabling auto-tracking)
  func resetScrollTracking() {
    lastScrolledCueID = nil
  }

  // MARK: - Private Methods

  private func buildAttributedString(
    cues: [Subtitle.Cue],
    currentTime: Double
  ) -> NSAttributedString {

    let paragraphStyle = NSMutableParagraphStyle()
    paragraphStyle.lineSpacing = lineSpacing
    paragraphStyle.paragraphSpacing = paragraphSpacing

    let result = NSMutableAttributedString()

    for (cueIndex, cue) in cues.enumerated() {
      let cueText = cue.decodedText
      let cueAttr = NSMutableAttributedString(
        string: cueText,
        attributes: [
          .font: textFont,
          .paragraphStyle: paragraphStyle,
          .foregroundColor: unplayedTextColor,
          .cueID: cue.id,
          .cueStartTime: cue.startTime,
        ]
      )

      // Add word timing attributes if available
      if let wordTimings = cue.wordTimings, !wordTimings.isEmpty {
        var searchStartIndex = cueText.startIndex
        for timing in wordTimings {
          if let range = cueText.range(
            of: timing.text,
            range: searchStartIndex..<cueText.endIndex
          ) {
            let location = cueText.distance(from: cueText.startIndex, to: range.lowerBound)
            let length = cueText.distance(from: range.lowerBound, to: range.upperBound)
            let nsRange = NSRange(location: location, length: length)

            if nsRange.location + nsRange.length <= cueAttr.length {
              cueAttr.addAttributes([
                .wordStartTime: timing.startTime,
                .wordEndTime: timing.endTime,
              ], range: nsRange)
            }
            searchStartIndex = range.upperBound
          }
        }
      }

      result.append(cueAttr)

      // Add block-level action view attachment (on its own line)
      let attachment = CueActionAttachment(cueID: cue.id, cueText: cueText)
      let attachmentString = NSAttributedString(attachment: attachment)
      result.append(NSAttributedString(string: "\n"))
      result.append(attachmentString)

      // Add paragraph separator (except for last cue)
      if cueIndex < cues.count - 1 {
        result.append(NSAttributedString(string: "\n", attributes: [
          .font: textFont,
          .paragraphStyle: paragraphStyle,
        ]))
      }
    }

    // Apply initial highlighting
    applyHighlighting(
      to: result,
      currentTime: currentTime
    )

    return result
  }

  private func buildWordRanges(from cues: [Subtitle.Cue]) -> [WordRange] {
    var ranges: [WordRange] = []
    var globalLocation = 0

    for (cueIndex, cue) in cues.enumerated() {
      let cueText = cue.decodedText

      if let wordTimings = cue.wordTimings, !wordTimings.isEmpty {
        var searchStartIndex = cueText.startIndex
        for timing in wordTimings {
          if let range = cueText.range(
            of: timing.text,
            range: searchStartIndex..<cueText.endIndex
          ) {
            let localLocation = cueText.distance(from: cueText.startIndex, to: range.lowerBound)
            let length = cueText.distance(from: range.lowerBound, to: range.upperBound)

            ranges.append(WordRange(
              nsRange: NSRange(location: globalLocation + localLocation, length: length),
              startTime: timing.startTime,
              endTime: timing.endTime,
              cueID: cue.id
            ))
            searchStartIndex = range.upperBound
          }
        }
      }

      // Calculate offset: cue text + "\n" + attachment (1 char) + "\n" separator (except last)
      let separatorLength = cueIndex < cues.count - 1 ? 1 : 0
      globalLocation += cueText.count + 1 + 1 + separatorLength
    }

    return ranges
  }

  private func buildCueRanges(from cues: [Subtitle.Cue]) -> [CueRange] {
    var ranges: [CueRange] = []
    var globalLocation = 0

    for (cueIndex, cue) in cues.enumerated() {
      let length = cue.decodedText.count
      ranges.append(CueRange(
        nsRange: NSRange(location: globalLocation, length: length),
        startTime: cue.startTime,
        endTime: cue.endTime,
        cueID: cue.id
      ))

      // Calculate offset: cue text + "\n" + attachment (1 char) + "\n" separator (except last)
      let separatorLength = cueIndex < cues.count - 1 ? 1 : 0
      globalLocation += length + 1 + 1 + separatorLength
    }

    return ranges
  }

  private func applyHighlighting(
    to string: NSMutableAttributedString,
    currentTime: Double
  ) {
    // First, reset all text to unplayed color
    string.addAttribute(
      .foregroundColor,
      value: unplayedTextColor,
      range: NSRange(location: 0, length: string.length)
    )

    // If we have word timings, use per-word highlighting
    if !wordRanges.isEmpty {
      let currentWordIndex = binarySearchWord(in: wordRanges, for: currentTime)
      let lastPlayedIndex = wordRanges.lastIndex { currentTime >= $0.endTime }

      for (index, wordRange) in wordRanges.enumerated() {
        guard wordRange.nsRange.location + wordRange.nsRange.length <= string.length else { continue }

        let color: UIColor
        if let current = currentWordIndex, index <= current {
          color = playedTextColor
        } else if let lastPlayed = lastPlayedIndex, index <= lastPlayed {
          color = playedTextColor
        } else {
          color = unplayedTextColor
        }

        string.addAttribute(.foregroundColor, value: color, range: wordRange.nsRange)
      }
    } else {
      // No word timings - use cue-level highlighting
      for cueRange in cueRanges {
        guard cueRange.nsRange.location + cueRange.nsRange.length <= string.length else { continue }

        let color: UIColor = currentTime >= cueRange.startTime ? playedTextColor : unplayedTextColor
        string.addAttribute(.foregroundColor, value: color, range: cueRange.nsRange)
      }
    }
  }

  private func updateHighlighting(currentTime: Double) {
    let storage = textStorage
    let mutableStorage = NSMutableAttributedString(attributedString: storage)
    applyHighlighting(to: mutableStorage, currentTime: currentTime)
    self.attributedText = mutableStorage
  }

  private func binarySearchWord(in ranges: [WordRange], for time: Double) -> Int? {
    guard !ranges.isEmpty else { return nil }

    var low = 0
    var high = ranges.count - 1

    while low <= high {
      let mid = (low + high) / 2
      let range = ranges[mid]

      if time >= range.startTime && time < range.endTime {
        return mid
      } else if time < range.startTime {
        high = mid - 1
      } else {
        low = mid + 1
      }
    }

    return nil
  }

  // MARK: - Tap Handling

  @objc private func handleTap(_ gesture: UITapGestureRecognizer) {
    let point = gesture.location(in: self)

    guard let layoutManager = textLayoutManager,
          let textContentStorage = layoutManager.textContentManager as? NSTextContentStorage else {
      return
    }

    // Use TextKit2 to find the location
    var tappedLocation: (any NSTextLocation)?
    layoutManager.enumerateTextLayoutFragments(
      from: textContentStorage.documentRange.location,
      options: [.ensuresLayout]
    ) { fragment in
      let fragmentFrame = fragment.layoutFragmentFrame
      if fragmentFrame.contains(point) {
        for lineFragment in fragment.textLineFragments {
          let lineFrame = lineFragment.typographicBounds
          let lineOrigin = CGPoint(
            x: lineFrame.origin.x,
            y: fragmentFrame.origin.y + lineFragment.typographicBounds.origin.y
          )
          let adjustedLineFrame = CGRect(origin: lineOrigin, size: lineFrame.size)
          if adjustedLineFrame.contains(point) {
            let charIndex = lineFragment.characterIndex(for: CGPoint(x: point.x - lineOrigin.x, y: 0))
            if charIndex != NSNotFound {
              tappedLocation = textContentStorage.location(
                fragment.rangeInElement.location,
                offsetBy: charIndex
              )
            }
            break
          }
        }
        return false
      }
      return true
    }

    guard let location = tappedLocation else { return }

    let offset = textContentStorage.offset(
      from: textContentStorage.documentRange.location,
      to: location
    )

    // Check if tapped on an attachment (action button)
    let storage = textStorage
    if offset < storage.length {
      let attributes = storage.attributes(at: offset, effectiveRange: nil)
      if let attachment = attributes[.attachment] as? CueActionAttachment {
        onActionButton?(attachment.cueID, attachment.cueText)
        return
      }
    }

    // Check if tapped on a word with timing
    if let wordRange = wordRanges.first(where: { NSLocationInRange(offset, $0.nsRange) }) {
      onTapAtTime?(wordRange.startTime)
      return
    }

    // Check if tapped on a cue
    if let cueRange = cueRanges.first(where: { NSLocationInRange(offset, $0.nsRange) }) {
      onTapAtTime?(cueRange.startTime)
    }
  }

  // MARK: - Selection Helpers

  private func snapSelectionToWordBoundaries() {
    guard selectedRange.length > 0,
          let text = self.text else { return }

    let newRange = WordBoundary.snapToWordBoundaries(in: text, range: selectedRange)
    if newRange != selectedRange && newRange.length > 0 {
      self.selectedRange = newRange
    }
  }

  private func findCueContext(for range: NSRange) -> String {
    guard let text = self.text else { return "" }
    for cueRange in cueRanges {
      if NSIntersectionRange(range, cueRange.nsRange).length > 0 {
        if let swiftRange = Range(cueRange.nsRange, in: text) {
          return String(text[swiftRange])
        }
      }
    }
    return ""
  }
}

// MARK: - UITextViewDelegate

extension KaraokeTextView: UITextViewDelegate {

  func textViewDidChangeSelection(_ textView: UITextView) {
    let selectedRange = textView.selectedRange
    let hasSelection = selectedRange.length > 0

    if hasSelection {
      snapSelectionToWordBoundaries()
    }

    // Track selection
    let selectedText: String?
    if hasSelection,
       let text = textView.text,
       let swiftRange = Range(textView.selectedRange, in: text) {
      let extracted = String(text[swiftRange])
      selectedText = extracted.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : extracted
    } else {
      selectedText = nil
    }

    if selectedText != lastSelectedText {
      lastSelectedText = selectedText
    }
  }

  @available(iOS 16.0, *)
  func textView(
    _ textView: UITextView,
    editMenuForTextIn range: NSRange,
    suggestedActions: [UIMenuElement]
  ) -> UIMenu? {
    guard range.length > 0,
          let text = textView.text,
          let swiftRange = Range(range, in: text) else {
      return UIMenu(children: suggestedActions)
    }

    let selectedText = String(text[swiftRange])
      .trimmingCharacters(in: .whitespacesAndNewlines)

    guard !selectedText.isEmpty else {
      return UIMenu(children: suggestedActions)
    }

    let context = findCueContext(for: range)

    let actionsItem = UIAction(
      title: "Actions...",
      image: UIImage(systemName: "ellipsis.circle")
    ) { [weak self] _ in
      self?.onSelectText?(selectedText, context)
    }

    var allActions: [UIMenuElement] = [actionsItem]
    allActions.append(contentsOf: suggestedActions)

    return UIMenu(children: allActions)
  }
}

// MARK: - UIScrollViewDelegate

extension KaraokeTextView {

  override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
    super.touchesMoved(touches, with: event)
    // Detect manual scroll
    if panGestureRecognizer.state == .changed {
      onScroll?()
    }
  }
}

// MARK: - UIGestureRecognizerDelegate

extension KaraokeTextView: UIGestureRecognizerDelegate {

  func gestureRecognizer(
    _ gestureRecognizer: UIGestureRecognizer,
    shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
  ) -> Bool {
    true
  }
}
