//
//  TextKit2SubtitleLayoutLabView.swift
//  YouTubeSubtitle
//
//  Standalone TextKit2 subtitle layout surface for SwiftUI previews.
//

import SwiftUI
import UIKit

// MARK: - TextKit2SubtitleLayoutLabView

struct TextKit2SubtitleLayoutLabView: View {
  let cues: [Subtitle.Cue]

  @State private var currentTime: Double
  @State private var isTrackingEnabled: Bool = true
  @State private var showsDebugGeometry: Bool = true

  init(cues: [Subtitle.Cue]) {
    self.cues = cues
    _currentTime = State(initialValue: cues.first?.startTime ?? 0)
  }

  var body: some View {
    VStack(spacing: 0) {
      TextKit2SubtitleLayoutDebugRepresentable(
        cues: cues,
        currentTime: currentTime,
        isTrackingEnabled: $isTrackingEnabled,
        showsDebugGeometry: showsDebugGeometry
      )

      Divider()

      controlPanel
    }
    .background(Color(uiColor: .systemBackground))
  }

  private var controlPanel: some View {
    VStack(alignment: .leading, spacing: 12) {
      HStack {
        Text(timeLabel(currentTime))
          .font(.system(.caption, design: .monospaced))
          .foregroundStyle(.secondary)

        Spacer()

        Toggle("Track", isOn: $isTrackingEnabled)
          .toggleStyle(.switch)
          .font(.caption)

        Toggle("Debug", isOn: $showsDebugGeometry)
          .toggleStyle(.switch)
          .font(.caption)
      }

      Slider(
        value: $currentTime,
        in: 0...max(cues.last?.endTime ?? 1, 1),
        step: 0.05
      )
    }
    .padding(16)
  }

  private func timeLabel(_ time: Double) -> String {
    String(format: "%.2fs", time)
  }
}

// MARK: - TextKit2SubtitleLayoutDebugRepresentable

private struct TextKit2SubtitleLayoutDebugRepresentable: UIViewRepresentable {
  let cues: [Subtitle.Cue]
  let currentTime: Double
  @Binding var isTrackingEnabled: Bool
  let showsDebugGeometry: Bool

  func makeUIView(context: Context) -> TextKit2SubtitleLayoutDebugTextView {
    let textView = TextKit2SubtitleLayoutDebugTextView()
    textView.onUserScroll = {
      isTrackingEnabled = false
    }
    return textView
  }

  func updateUIView(_ textView: TextKit2SubtitleLayoutDebugTextView, context: Context) {
    textView.setCues(cues)
    textView.setShowsDebugGeometry(showsDebugGeometry)
    textView.setCurrentTime(currentTime, tracksCurrentCue: isTrackingEnabled)
  }
}

// MARK: - TextKit2SubtitleLayoutDebugTextView

private final class TextKit2SubtitleLayoutDebugTextView: UITextView {
  var onUserScroll: (() -> Void)?

  private let debugOverlayView = TextKit2SubtitleGeometryOverlayView()
  private let textFont = UIFont.systemFont(ofSize: 19, weight: .semibold)
  private let playedColor = UIColor.tintColor
  private let currentColor = UIColor.label
  private let unplayedColor = UIColor.secondaryLabel

  private var cues: [Subtitle.Cue] = []
  private var cueLayouts: [CueLayout] = []
  private var currentCueID: Int?
  private var showsDebugGeometry = true
  private var isUpdatingProgrammaticScroll = false

  override init(frame: CGRect, textContainer: NSTextContainer?) {
    super.init(frame: frame, textContainer: textContainer)
    setupTextView()
  }

  convenience init() {
    self.init(frame: .zero, textContainer: nil)
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func layoutSubviews() {
    super.layoutSubviews()

    let overlaySize = CGSize(
      width: max(contentSize.width, bounds.width),
      height: max(contentSize.height, bounds.height)
    )
    debugOverlayView.frame = CGRect(origin: .zero, size: overlaySize)
    updateGeometryOverlay()
  }

  func setCues(_ newCues: [Subtitle.Cue]) {
    guard cues != newCues else { return }

    cues = newCues
    let document = buildAttributedString(cues: newCues)
    cueLayouts = document.cueLayouts
    attributedText = document.attributedString
    currentCueID = nil

    setNeedsLayout()
  }

  func setCurrentTime(_ time: Double, tracksCurrentCue: Bool) {
    let nextCueID = currentCueID(at: time)
    let cueChanged = nextCueID != currentCueID
    currentCueID = nextCueID

    updateRenderingAttributes(currentTime: time)
    updateGeometryOverlay()

    if tracksCurrentCue, cueChanged, let nextCueID {
      scrollToCue(id: nextCueID, animated: true)
    }
  }

  func setShowsDebugGeometry(_ showsDebugGeometry: Bool) {
    guard self.showsDebugGeometry != showsDebugGeometry else { return }
    self.showsDebugGeometry = showsDebugGeometry
    debugOverlayView.isHidden = !showsDebugGeometry
    if showsDebugGeometry {
      updateGeometryOverlay()
    }
  }

  private func setupTextView() {
    if textLayoutManager == nil {
      assertionFailure("TextKit2 layout manager is unavailable.")
    }

    isEditable = false
    isSelectable = true
    isScrollEnabled = true
    backgroundColor = .clear
    textContainerInset = UIEdgeInsets(top: 28, left: 20, bottom: 120, right: 20)
    textContainer.lineFragmentPadding = 0
    alwaysBounceVertical = true
    showsVerticalScrollIndicator = true
    delegate = self

    debugOverlayView.isUserInteractionEnabled = false
    addSubview(debugOverlayView)
  }

  private func buildAttributedString(cues: [Subtitle.Cue]) -> SubtitleLayoutDocument {
    let result = NSMutableAttributedString()
    var layouts: [CueLayout] = []

    let paragraphStyle = NSMutableParagraphStyle()
    paragraphStyle.lineSpacing = 7
    paragraphStyle.paragraphSpacing = 18
    paragraphStyle.lineBreakMode = .byWordWrapping

    for (index, cue) in cues.enumerated() {
      let sectionID = index / 3
      let startLocation = result.length
      let cueText = cue.decodedText
      let cueRange = NSRange(location: startLocation, length: (cueText as NSString).length)

      result.append(NSAttributedString(
        string: cueText,
        attributes: [
          .font: textFont,
          .foregroundColor: unplayedColor,
          .paragraphStyle: paragraphStyle,
          .cueID: cue.id,
          .cueStartTime: cue.startTime,
          .debugSectionID: sectionID,
        ]
      ))

      layouts.append(CueLayout(
        cueID: cue.id,
        sectionID: sectionID,
        range: cueRange,
        startTime: cue.startTime,
        endTime: cue.endTime
      ))

      result.append(NSAttributedString(string: "\n"))
      result.append(NSAttributedString(attachment: CueActionAttachment(
        cueID: cue.id,
        cueText: cueText
      )))

      if index < cues.count - 1 {
        result.append(NSAttributedString(string: "\n"))
      }
    }

    return SubtitleLayoutDocument(attributedString: result, cueLayouts: layouts)
  }

  private func updateRenderingAttributes(currentTime: Double) {
    guard textStorage.length > 0 else { return }

    textStorage.beginEditing()
    defer { textStorage.endEditing() }

    for layout in cueLayouts {
      let color: UIColor
      if currentTime >= layout.startTime && currentTime < layout.endTime {
        color = currentColor
      } else if currentTime >= layout.endTime {
        color = playedColor
      } else {
        color = unplayedColor
      }

      guard NSMaxRange(layout.range) <= textStorage.length else { continue }
      textStorage.addAttribute(.foregroundColor, value: color, range: layout.range)
    }
  }

  private func updateGeometryOverlay() {
    guard showsDebugGeometry, bounds.width > 0 else { return }

    let cueRects = cueLayouts.reduce(into: [Int: [CGRect]]()) { result, layout in
      result[layout.cueID] = contentRects(for: layout.range)
    }

    let sectionRects = cueLayouts.reduce(into: [Int: CGRect]()) { result, layout in
      let union = cueRects[layout.cueID, default: []].reduce(CGRect.null) { partial, rect in
        partial.union(rect)
      }
      guard !union.isNull else { return }

      let padded = union.insetBy(dx: -12, dy: -8)
      if let existing = result[layout.sectionID] {
        result[layout.sectionID] = existing.union(padded)
      } else {
        result[layout.sectionID] = padded
      }
    }

    let currentRect = currentCueID.flatMap { cueRects[$0] }?.reduce(CGRect.null) { partial, rect in
      partial.union(rect)
    }

    debugOverlayView.geometry = TextKit2SubtitleGeometryOverlayView.Geometry(
      cueRects: cueRects,
      sectionRects: sectionRects,
      currentCueRect: currentRect?.isNull == false ? currentRect : nil
    )
  }

  private func scrollToCue(id: Int, animated: Bool) {
    guard let layout = cueLayouts.first(where: { $0.cueID == id }) else { return }

    layoutIfNeeded()

    let rects = contentRects(for: layout.range)
    let cueRect = rects.reduce(CGRect.null) { partial, rect in
      partial.union(rect)
    }
    guard !cueRect.isNull, cueRect.height > 0, bounds.height > 0 else { return }

    let targetY = cueRect.midY - bounds.height * 0.42
    let maxY = max(0, contentSize.height - bounds.height)
    let clampedY = min(max(targetY, 0), maxY)

    isUpdatingProgrammaticScroll = true
    setContentOffset(CGPoint(x: 0, y: clampedY), animated: animated)

    if animated {
      Task { @MainActor in
        try? await Task.sleep(for: .milliseconds(350))
        isUpdatingProgrammaticScroll = false
      }
    } else {
      isUpdatingProgrammaticScroll = false
    }
  }

  private func contentRects(for nsRange: NSRange) -> [CGRect] {
    guard let manager = textLayoutManager,
          let textRange = textRange(for: nsRange) else {
      return []
    }

    manager.ensureLayout(for: textRange)

    var rects: [CGRect] = []
    manager.enumerateTextSegments(in: textRange, type: .highlight, options: []) { _, rect, _, _ in
      rects.append(rect.offsetBy(dx: textContainerInset.left, dy: textContainerInset.top))
      return true
    }

    return rects
  }

  private func textRange(for nsRange: NSRange) -> NSTextRange? {
    guard let manager = textLayoutManager,
          let content = manager.textContentManager else {
      return nil
    }

    let documentStart = content.documentRange.location
    guard let start = content.location(documentStart, offsetBy: nsRange.location),
          let end = content.location(start, offsetBy: nsRange.length) else {
      return nil
    }

    return NSTextRange(location: start, end: end)
  }

  private func currentCueID(at time: Double) -> Int? {
    cues.last { cue in
      time >= cue.startTime && time < cue.endTime
    }?.id ?? cues.last { cue in
      time >= cue.startTime
    }?.id
  }
}

// MARK: - UITextViewDelegate

extension TextKit2SubtitleLayoutDebugTextView: UITextViewDelegate {
  func scrollViewWillBeginDragging(_ scrollView: UIScrollView) {
    guard !isUpdatingProgrammaticScroll else { return }
    onUserScroll?()
  }
}

// MARK: - Geometry Overlay

private final class TextKit2SubtitleGeometryOverlayView: UIView {
  struct Geometry {
    var cueRects: [Int: [CGRect]] = [:]
    var sectionRects: [Int: CGRect] = [:]
    var currentCueRect: CGRect?
  }

  var geometry = Geometry() {
    didSet { setNeedsDisplay() }
  }

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear
    isOpaque = false
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func draw(_ rect: CGRect) {
    guard let context = UIGraphicsGetCurrentContext() else { return }

    context.saveGState()
    defer { context.restoreGState() }

    for sectionRect in geometry.sectionRects.values {
      let path = UIBezierPath(roundedRect: sectionRect, cornerRadius: 10)
      UIColor.systemOrange.withAlphaComponent(0.10).setFill()
      UIColor.systemOrange.withAlphaComponent(0.45).setStroke()
      path.lineWidth = 1
      path.fill()
      path.stroke()
    }

    for rects in geometry.cueRects.values {
      for cueRect in rects {
        let path = UIBezierPath(roundedRect: cueRect.insetBy(dx: -3, dy: -2), cornerRadius: 5)
        UIColor.systemGreen.withAlphaComponent(0.22).setFill()
        UIColor.systemGreen.withAlphaComponent(0.70).setStroke()
        path.lineWidth = 1
        path.fill()
        path.stroke()
      }
    }

    if let currentCueRect = geometry.currentCueRect {
      let centerY = currentCueRect.midY
      let linePath = UIBezierPath()
      linePath.move(to: CGPoint(x: 0, y: centerY))
      linePath.addLine(to: CGPoint(x: bounds.width, y: centerY))
      UIColor.systemRed.withAlphaComponent(0.85).setStroke()
      linePath.lineWidth = 1
      linePath.stroke()
    }
  }
}

// MARK: - Supporting Types

private struct SubtitleLayoutDocument {
  let attributedString: NSAttributedString
  let cueLayouts: [CueLayout]
}

private struct CueLayout {
  let cueID: Int
  let sectionID: Int
  let range: NSRange
  let startTime: Double
  let endTime: Double
}

private extension NSAttributedString.Key {
  static let debugSectionID = NSAttributedString.Key("debugSectionID")
}

// MARK: - Preview Samples

private enum TextKit2SubtitlePreviewSamples {
  static let mixedLanguage: [Subtitle.Cue] = [
    Subtitle.Cue(
      id: 1,
      startTime: 0.0,
      endTime: 2.4,
      text: "TextKit 2 gives us fragments, line fragments, and segments."
    ),
    Subtitle.Cue(
      id: 2,
      startTime: 2.4,
      endTime: 5.1,
      text: "字幕の文字組に合わせて、下にボタンを置いてみる。"
    ),
    Subtitle.Cue(
      id: 3,
      startTime: 5.1,
      endTime: 8.0,
      text: "A long cue wraps into multiple lines so the green segment rects should become a stack, not a single naive bounding box."
    ),
    Subtitle.Cue(
      id: 4,
      startTime: 8.0,
      endTime: 10.3,
      text: "Section grouping is drawn behind three cues at a time."
    ),
    Subtitle.Cue(
      id: 5,
      startTime: 10.3,
      endTime: 13.2,
      text: "cafe\u{301}, emoji 🙂, and mixed scripts should keep NSRange math honest."
    ),
    Subtitle.Cue(
      id: 6,
      startTime: 13.2,
      endTime: 16.0,
      text: "مرحبا بالعالم — right-to-left text should still produce usable segments."
    ),
    Subtitle.Cue(
      id: 7,
      startTime: 16.0,
      endTime: 19.5,
      text: "最後は scroll tracking。赤い線が現在 cue の中心に追従する。"
    ),
  ]
}

private struct TextKit2SubtitleLayoutLabPreview: View {
  var body: some View {
    TextKit2SubtitleLayoutLabView(cues: TextKit2SubtitlePreviewSamples.mixedLanguage)
  }
}

#Preview("TextKit2 Subtitle Layout Lab") {
  TextKit2SubtitleLayoutLabPreview()
}
