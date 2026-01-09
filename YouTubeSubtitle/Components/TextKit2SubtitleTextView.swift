//
//  TextKit2SubtitleTextView.swift
//  YouTubeSubtitle
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

// MARK: - Cue Action Attachment

/// Custom text attachment that displays an action icon at the end of each cue.
/// Uses image-based approach for reliability (NSTextAttachmentViewProvider has known issues).
final class CueActionAttachment: NSTextAttachment {
  /// Cue ID for identifying which cue this attachment belongs to
  nonisolated(unsafe) var cueID: Int = 0
  /// Original cue text for action handling
  nonisolated(unsafe) var cueText: String = ""

  convenience init(cueID: Int, cueText: String, font: UIFont) {
    self.init()
    self.cueID = cueID
    self.cueText = cueText

    // Create image from SF Symbol
    let iconSize = font.pointSize * 0.9
    let config = UIImage.SymbolConfiguration(pointSize: iconSize, weight: .medium)
    let image = UIImage(systemName: "ellipsis.circle", withConfiguration: config)?
      .withTintColor(.secondaryLabel, renderingMode: .alwaysOriginal)
    self.image = image

    // Adjust bounds to align with text baseline
    if let image {
      let yOffset = (font.capHeight - image.size.height) / 2
      self.bounds = CGRect(x: 0, y: yOffset, width: image.size.width, height: image.size.height)
    }
  }

  @available(*, unavailable)
  nonisolated required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  nonisolated override init(data contentData: Data?, ofType uti: String?) {
    super.init(data: contentData, ofType: uti)
  }
}

// MARK: - TextKit2 Subtitle Text View

/// UIViewRepresentable that displays all subtitles in a single UITextView using TextKit2.
/// Supports word-level karaoke highlighting, tap-to-seek, text selection, and auto-scroll.
struct TextKit2SubtitleTextView: UIViewRepresentable {

  // MARK: - Properties

  let cues: [Subtitle.Cue]
  let currentTimeValue: Double
  let currentCueID: Subtitle.Cue.ID?
  @Binding var isTrackingEnabled: Bool
  let onAction: (SubtitleAction) -> Void

  // MARK: - Styling

  private let font: UIFont = .systemFont(ofSize: 18, weight: .bold)
  private let playedTextColor: UIColor = .tintColor
  private let unplayedTextColor: UIColor = .tintColor.withAlphaComponent(0.4)
  private let paragraphSpacing: CGFloat = 20
  private let lineSpacing: CGFloat = 10

  // MARK: - UIViewRepresentable

  func makeUIView(context: Context) -> UIScrollView {
    // Create scroll view container
    let scrollView = UIScrollView()
    scrollView.showsVerticalScrollIndicator = true
    scrollView.showsHorizontalScrollIndicator = false
    scrollView.alwaysBounceVertical = true
    scrollView.delegate = context.coordinator

    // Create UITextView with TextKit2
    let textView = createTextView(context: context)
    textView.translatesAutoresizingMaskIntoConstraints = false
    scrollView.addSubview(textView)

    NSLayoutConstraint.activate([
      textView.topAnchor.constraint(equalTo: scrollView.topAnchor),
      textView.leadingAnchor.constraint(equalTo: scrollView.leadingAnchor),
      textView.trailingAnchor.constraint(equalTo: scrollView.trailingAnchor),
      textView.bottomAnchor.constraint(equalTo: scrollView.bottomAnchor),
      textView.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
    ])

    context.coordinator.textView = textView
    context.coordinator.scrollView = scrollView

    return scrollView
  }

  func updateUIView(_ scrollView: UIScrollView, context: Context) {
    let coordinator = context.coordinator

    // Update callbacks
    coordinator.onAction = onAction
    coordinator.isTrackingEnabledBinding = $isTrackingEnabled

    // Check if cues changed
    let cuesChanged = coordinator.lastCues != cues
    if cuesChanged {
      coordinator.lastCues = cues
      coordinator.wordRanges = buildWordRanges(from: cues)
      coordinator.cueRanges = buildCueRanges(from: cues)

      // Rebuild attributed string
      let attributedString = buildAttributedString(
        cues: cues,
        currentTime: currentTimeValue,
        wordRanges: coordinator.wordRanges,
        cueRanges: coordinator.cueRanges
      )
      coordinator.textView?.attributedText = attributedString
    } else {
      // Only update highlighting
      updateHighlighting(
        coordinator: coordinator,
        currentTime: currentTimeValue
      )
    }

    // Auto-scroll if tracking enabled and cue changed
    if isTrackingEnabled, let currentCueID {
      scrollToCue(cueID: currentCueID, coordinator: coordinator, animated: true)
    }
  }

  func makeCoordinator() -> Coordinator {
    Coordinator(onAction: onAction)
  }

  // MARK: - Private Methods

  private func createTextView(context: Context) -> UITextView {
    // TextKit2 setup
    let textLayoutManager = NSTextLayoutManager()
    let textContentStorage = NSTextContentStorage()
    let textContainer = NSTextContainer()

    textContainer.widthTracksTextView = true
    textContainer.lineFragmentPadding = 12

    textContentStorage.addTextLayoutManager(textLayoutManager)
    textLayoutManager.textContainer = textContainer

    let textView = UITextView(frame: .zero, textContainer: textContainer)
    textView.isEditable = false
    textView.isScrollEnabled = false  // Scroll handled by parent UIScrollView
    textView.backgroundColor = .clear
    textView.textContainerInset = UIEdgeInsets(top: 12, left: 0, bottom: 12, right: 0)
    textView.delegate = context.coordinator

    // Single tap gesture for word/cue detection
    let tapGesture = UITapGestureRecognizer(
      target: context.coordinator,
      action: #selector(Coordinator.handleTap(_:))
    )
    tapGesture.delegate = context.coordinator

    // Make tap gesture require long press to fail first
    for gesture in textView.gestureRecognizers ?? [] {
      if let longPress = gesture as? UILongPressGestureRecognizer {
        tapGesture.require(toFail: longPress)
      }
    }

    textView.addGestureRecognizer(tapGesture)

    return textView
  }

  /// Builds the complete attributed string for all cues
  private func buildAttributedString(
    cues: [Subtitle.Cue],
    currentTime: Double,
    wordRanges: [WordRange],
    cueRanges: [CueRange]
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
          .font: font,
          .paragraphStyle: paragraphStyle,
          .foregroundColor: unplayedTextColor,  // Initial color
          .cueID: cue.id,
          .cueStartTime: cue.startTime,
        ]
      )

      // Add word timing attributes if available
      if let wordTimings = cue.wordTimings, !wordTimings.isEmpty {
        var location = 0
        for timing in wordTimings {
          let length = timing.text.count
          let range = NSRange(location: location, length: length)
          if range.location + range.length <= cueAttr.length {
            cueAttr.addAttributes([
              .wordStartTime: timing.startTime,
              .wordEndTime: timing.endTime,
            ], range: range)
          }
          location += length + 1  // +1 for space
        }
      }

      result.append(cueAttr)

      // Add action button attachment after cue text
      let attachment = CueActionAttachment(cueID: cue.id, cueText: cueText, font: font)
      let attachmentString = NSAttributedString(attachment: attachment)
      result.append(NSAttributedString(string: " "))  // Space before button
      result.append(attachmentString)

      // Add paragraph separator (except for last cue)
      if cueIndex < cues.count - 1 {
        result.append(NSAttributedString(string: "\n\n", attributes: [
          .font: font,
          .paragraphStyle: paragraphStyle,
        ]))
      }
    }

    // Apply initial highlighting
    applyHighlighting(
      to: result,
      currentTime: currentTime,
      wordRanges: wordRanges,
      cueRanges: cueRanges
    )

    return result
  }

  /// Builds word ranges for efficient lookup
  private func buildWordRanges(from cues: [Subtitle.Cue]) -> [WordRange] {
    var ranges: [WordRange] = []
    var globalLocation = 0

    for cue in cues {
      if let wordTimings = cue.wordTimings, !wordTimings.isEmpty {
        var localLocation = 0
        for timing in wordTimings {
          let length = timing.text.count
          ranges.append(WordRange(
            nsRange: NSRange(location: globalLocation + localLocation, length: length),
            startTime: timing.startTime,
            endTime: timing.endTime,
            cueID: cue.id
          ))
          localLocation += length + 1
        }
      }
      globalLocation += cue.decodedText.count + 2  // +2 for "\n\n"
    }

    return ranges
  }

  /// Builds cue ranges for efficient lookup
  private func buildCueRanges(from cues: [Subtitle.Cue]) -> [CueRange] {
    var ranges: [CueRange] = []
    var globalLocation = 0

    for cue in cues {
      let length = cue.decodedText.count
      ranges.append(CueRange(
        nsRange: NSRange(location: globalLocation, length: length),
        startTime: cue.startTime,
        endTime: cue.endTime,
        cueID: cue.id
      ))
      globalLocation += length + 2  // +2 for "\n\n"
    }

    return ranges
  }

  /// Applies karaoke-style highlighting to the attributed string
  private func applyHighlighting(
    to string: NSMutableAttributedString,
    currentTime: Double,
    wordRanges: [WordRange],
    cueRanges: [CueRange]
  ) {
    // First, reset all text to unplayed color
    string.addAttribute(
      .foregroundColor,
      value: unplayedTextColor,
      range: NSRange(location: 0, length: string.length)
    )

    // If we have word timings, use per-word highlighting
    if !wordRanges.isEmpty {
      // Find current word index using binary search
      let currentWordIndex = binarySearchWord(in: wordRanges, for: currentTime)

      // Find last played word for gap handling
      let lastPlayedIndex = wordRanges.lastIndex { currentTime >= $0.endTime }

      // Apply colors to words
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

  /// Updates highlighting without rebuilding the entire attributed string
  private func updateHighlighting(coordinator: Coordinator, currentTime: Double) {
    guard let textView = coordinator.textView else { return }

    let storage = textView.textStorage
    let mutableStorage = NSMutableAttributedString(attributedString: storage)
    applyHighlighting(
      to: mutableStorage,
      currentTime: currentTime,
      wordRanges: coordinator.wordRanges,
      cueRanges: coordinator.cueRanges
    )
    textView.attributedText = mutableStorage
  }

  /// Binary search to find the word containing the given time
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

  /// Scrolls to make the specified cue visible
  private func scrollToCue(cueID: Subtitle.Cue.ID, coordinator: Coordinator, animated: Bool) {
    guard let textView = coordinator.textView,
          let scrollView = coordinator.scrollView,
          let cueRange = coordinator.cueRanges.first(where: { $0.cueID == cueID }),
          let layoutManager = textView.textLayoutManager,
          let textContentStorage = layoutManager.textContentManager as? NSTextContentStorage else {
      return
    }

    // Convert NSRange to NSTextRange
    guard let start = textContentStorage.location(
            textContentStorage.documentRange.location,
            offsetBy: cueRange.nsRange.location),
          let end = textContentStorage.location(start, offsetBy: cueRange.nsRange.length),
          let textRange = NSTextRange(location: start, end: end) else {
      return
    }

    // Get the layout fragment for this range
    var targetRect: CGRect?
    layoutManager.enumerateTextLayoutFragments(
      from: textRange.location,
      options: [.ensuresLayout]
    ) { fragment in
      targetRect = fragment.layoutFragmentFrame
      return false  // Stop after first fragment
    }

    guard let rect = targetRect else { return }

    // Convert to scroll view coordinates and scroll
    let convertedRect = textView.convert(rect, to: scrollView)
    let centeredRect = CGRect(
      x: convertedRect.origin.x,
      y: convertedRect.origin.y - (scrollView.bounds.height - convertedRect.height) / 2,
      width: convertedRect.width,
      height: scrollView.bounds.height
    )

    scrollView.scrollRectToVisible(centeredRect, animated: animated)
  }

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

  // MARK: - Coordinator

  class Coordinator: NSObject, UITextViewDelegate, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    var onAction: (SubtitleAction) -> Void
    var isTrackingEnabledBinding: Binding<Bool>?
    var textView: UITextView?
    var scrollView: UIScrollView?
    var lastCues: [Subtitle.Cue] = []
    var wordRanges: [WordRange] = []
    var cueRanges: [CueRange] = []

    private var lastSelectedText: String?

    init(onAction: @escaping (SubtitleAction) -> Void) {
      self.onAction = onAction
      super.init()
    }

    // MARK: - Tap Handling

    @objc func handleTap(_ gesture: UITapGestureRecognizer) {
      guard let textView = gesture.view as? UITextView else { return }
      let point = gesture.location(in: textView)

      // Find character index at tap point
      guard let layoutManager = textView.textLayoutManager,
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
          // Find text location within fragment
          for lineFragment in fragment.textLineFragments {
            let lineFrame = lineFragment.typographicBounds
            let lineOrigin = CGPoint(x: lineFrame.origin.x, y: fragmentFrame.origin.y + lineFragment.typographicBounds.origin.y)
            let adjustedLineFrame = CGRect(origin: lineOrigin, size: lineFrame.size)
            if adjustedLineFrame.contains(point) {
              let charIndex = lineFragment.characterIndex(for: CGPoint(x: point.x - lineOrigin.x, y: 0))
              if charIndex != NSNotFound {
                tappedLocation = textContentStorage.location(fragment.rangeInElement.location, offsetBy: charIndex)
              }
              break
            }
          }
          return false
        }
        return true
      }

      guard let location = tappedLocation else { return }

      // Convert to offset
      let offset = textContentStorage.offset(from: textContentStorage.documentRange.location, to: location)

      // Check if tapped on an attachment (action button)
      let storage = textView.textStorage
      if offset < storage.length {
        let attributes = storage.attributes(at: offset, effectiveRange: nil)
        if let attachment = attributes[.attachment] as? CueActionAttachment {
          // Tapped on action button - show actions for this cue
          onAction(.showSelectionActions(text: attachment.cueText, context: attachment.cueText))
          return
        }
      }

      // Check if tapped on a word with timing
      if let wordRange = wordRanges.first(where: { NSLocationInRange(offset, $0.nsRange) }) {
        onAction(.tap(time: wordRange.startTime))
        return
      }

      // Check if tapped on a cue
      if let cueRange = cueRanges.first(where: { NSLocationInRange(offset, $0.nsRange) }) {
        onAction(.tap(time: cueRange.startTime))
      }
    }

    // MARK: - UIScrollViewDelegate

    func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
      isTrackingEnabledBinding?.wrappedValue = false
    }

    // MARK: - UITextViewDelegate

    func textViewDidChangeSelection(_ textView: UITextView) {
      let selectedRange = textView.selectedRange
      let hasSelection = selectedRange.length > 0

      // Snap to word boundaries
      if hasSelection {
        snapSelectionToWordBoundaries(textView)
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

    private func snapSelectionToWordBoundaries(_ textView: UITextView) {
      let selectedRange = textView.selectedRange
      guard selectedRange.length > 0,
            let text = textView.text else { return }

      let newRange = WordBoundary.snapToWordBoundaries(in: text, range: selectedRange)
      if newRange != selectedRange && newRange.length > 0 {
        textView.selectedRange = newRange
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

      // Find context (the cue containing the selection)
      let context = findCueContext(for: range, in: text)

      let actionsItem = UIAction(
        title: "Actions...",
        image: UIImage(systemName: "ellipsis.circle")
      ) { [weak self] _ in
        self?.onAction(.showSelectionActions(text: selectedText, context: context))
      }

      var allActions: [UIMenuElement] = [actionsItem]
      allActions.append(contentsOf: suggestedActions)

      return UIMenu(children: allActions)
    }

    private func findCueContext(for range: NSRange, in text: String) -> String {
      // Find the cue that contains this range
      for cueRange in cueRanges {
        if NSIntersectionRange(range, cueRange.nsRange).length > 0 {
          if let swiftRange = Range(cueRange.nsRange, in: text) {
            return String(text[swiftRange])
          }
        }
      }
      return ""
    }

    // MARK: - UIGestureRecognizerDelegate

    func gestureRecognizer(
      _ gestureRecognizer: UIGestureRecognizer,
      shouldRecognizeSimultaneouslyWith otherGestureRecognizer: UIGestureRecognizer
    ) -> Bool {
      true
    }
  }
}
