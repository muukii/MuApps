@preconcurrency import AVFoundation
import CaptureDoodle
import Foundation
import JournalModel
import MuColor
import SwiftUI
import UIKit

/// A pre-share review screen for one prepared card snapshot.
///
/// The context menu opens this screen first so the user can inspect the final
/// share appearance before the system activity sheet appears. Doodle cards also
/// expose a replay preview backed by their stored vector timeline.
struct CardSharePreviewScreen: View {

  let snapshot: CardShareSnapshot
  let palette: Palette

  @Environment(\.dismiss) private var dismiss
  @Environment(\.colorScheme) private var colorScheme
  @State private var selectedMode: CardSharePreviewMode
  @State private var activityPresentation: CardShareActivityPresentation?
  @State private var isPreparingShareItem: Bool = false
  @State private var isShareFailurePresented: Bool = false

  private let doodleDrawing: DoodleDrawing?

  init(snapshot: CardShareSnapshot, palette: Palette = .default) {
    self.snapshot = snapshot
    self.palette = palette
    self.doodleDrawing = Self.decodeDoodleDrawing(from: snapshot)
    _selectedMode = State(initialValue: .image)
  }

  var body: some View {
    NavigationStack {
      VStack(spacing: 0) {
        if showsModePicker {
          modePicker
            .padding(.horizontal, 16)
            .padding(.top, 14)
            .padding(.bottom, 10)
        }

        Divider()

        CardSharePreviewScaledFrame {
          switch selectedMode {
          case .image:
            CardShareImageView(snapshot: snapshot, palette: palette)
          case .video:
            if let doodleDrawing {
              CardShareDoodleReplayPreview(
                snapshot: snapshot,
                drawing: doodleDrawing,
                palette: palette
              )
            } else {
              CardShareImageView(snapshot: snapshot, palette: palette)
            }
          }
        }
      }
      .background(.background)
      .navigationTitle("Share Preview")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Done") {
            dismiss()
          }
          .disabled(isPreparingShareItem)
        }

        ToolbarItem(placement: .confirmationAction) {
          switch selectedMode {
          case .image:
            Button("Share Image", action: shareImage)
              .disabled(isPreparingShareItem)
          case .video:
            Button("Share Video", action: shareVideo)
              .disabled(doodleDrawing == nil || isPreparingShareItem)
          }
        }
      }
      .overlay(alignment: .center) {
        if isPreparingShareItem {
          ProgressView()
            .padding(18)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        }
      }
      .sheet(item: $activityPresentation) { presentation in
        ActivityView(activityItems: [presentation.fileURL])
      }
      .alert("Couldn't Share", isPresented: $isShareFailurePresented) {
        Button("OK", role: .cancel) {}
      }
    }
  }

  private var showsModePicker: Bool {
    doodleDrawing != nil
  }

  private var modePicker: some View {
    Picker("Preview", selection: $selectedMode) {
      ForEach(availableModes) { mode in
        Text(mode.title)
          .tag(mode)
      }
    }
    .pickerStyle(.segmented)
  }

  private var availableModes: [CardSharePreviewMode] {
    showsModePicker ? [.image, .video] : [.image]
  }

  private func shareImage() {
    do {
      isPreparingShareItem = true
      defer { isPreparingShareItem = false }
      let url = try CardShareImageRenderer.pngFile(
        for: snapshot,
        palette: palette,
        colorScheme: colorScheme
      )
      activityPresentation = CardShareActivityPresentation(fileURL: url)
    } catch {
      isShareFailurePresented = true
    }
  }

  private func shareVideo() {
    guard let doodleDrawing else { return }

    isPreparingShareItem = true
    Task {
      defer { isPreparingShareItem = false }
      do {
        await Task.yield()
        let url = try await CardShareVideoRenderer.mp4File(
          for: snapshot,
          drawing: doodleDrawing,
          palette: palette
        )
        activityPresentation = CardShareActivityPresentation(fileURL: url)
      } catch {
        isShareFailurePresented = true
      }
    }
  }

  private static func decodeDoodleDrawing(from snapshot: CardShareSnapshot) -> DoodleDrawing? {
    guard case .doodle(let drawingData, _) = snapshot.content,
      let drawingData
    else {
      return nil
    }

    return try? JSONDecoder().decode(DoodleDrawing.self, from: drawingData)
  }
}

/// The share formats the preview screen can render for visual confirmation.
private enum CardSharePreviewMode: String, Identifiable {
  case image
  case video

  var id: Self { self }

  var title: LocalizedStringResource {
    switch self {
    case .image:
      return "Image"
    case .video:
      return "Video"
    }
  }
}

/// Presentation payload for a nested system activity sheet.
private struct CardShareActivityPresentation: Identifiable {
  let id = UUID()
  let fileURL: URL
}

/// Scales the fixed export canvas into the preview sheet.
///
/// The content is laid out at the actual export pixel size first, then scaled
/// down for on-screen inspection. That keeps fixed typography and spacing from
/// being compressed by the smaller preview sheet layout.
private struct CardSharePreviewScaledFrame<Content: View>: View {

  private let content: Content

  init(@ViewBuilder content: () -> Content) {
    self.content = content()
  }

  var body: some View {
    GeometryReader { proxy in
      let size = fittedSize(in: proxy.size)
      let scale = previewScale(for: size)

      ScrollView {
        VStack {
          content
            .frame(width: exportSize.width, height: exportSize.height)
            .scaleEffect(scale, anchor: .topLeading)
            .frame(width: size.width, height: size.height, alignment: .topLeading)
            .clipShape(RoundedRectangle(cornerRadius: 24, style: .continuous))
            .shadow(color: .black.opacity(0.16), radius: 22, x: 0, y: 12)
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: proxy.size.height)
        .padding(.horizontal, 20)
        .padding(.vertical, 24)
      }
    }
  }

  private func fittedSize(in bounds: CGSize) -> CGSize {
    let aspectRatio = exportSize.width / exportSize.height
    let availableWidth = max(bounds.width - 40, 1)
    let availableHeight = max(bounds.height - 48, 1)
    let width = min(availableWidth, availableHeight * aspectRatio, 430)
    return CGSize(width: width, height: width / aspectRatio)
  }

  private func previewScale(for fittedSize: CGSize) -> CGFloat {
    min(
      fittedSize.width / exportSize.width,
      fittedSize.height / exportSize.height
    )
  }

  private var exportSize: CGSize {
    CardShareImageRenderer.defaultPixelSize
  }
}

/// Timing recipe shared by video preview and mp4 export.
///
/// The stored Doodle timeline is the source of truth, but share videos clamp very
/// long drawings to a compact replay length and stretch very short drawings so
/// they remain inspectable after export.
private struct CardShareVideoRecipe: Sendable, Equatable {

  /// Default export frame rate for Doodle replay videos.
  static let defaultFrameRate: Int32 = 60

  /// Frames per second used for generated replay videos.
  let frameRate: Int32

  /// Fixed export canvas size in pixels.
  let pixelSize: CGSize

  /// Original Doodle timeline length in seconds.
  let sourceDuration: TimeInterval

  /// Visible drawing segment length in the exported video.
  let replayDuration: TimeInterval

  /// Final hold after the full drawing has appeared.
  let holdDuration: TimeInterval

  init(
    drawing: DoodleDrawing,
    pixelSize: CGSize = CardShareImageRenderer.defaultPixelSize,
    frameRate: Int32 = defaultFrameRate,
    minimumReplayDuration: TimeInterval = 1.2,
    maximumReplayDuration: TimeInterval = 12,
    holdDuration: TimeInterval = 0.75
  ) {
    self.frameRate = max(frameRate, 1)
    self.pixelSize = pixelSize
    self.sourceDuration = max(Self.sourceDuration(for: drawing), 0.18)
    self.replayDuration = min(
      max(self.sourceDuration, minimumReplayDuration),
      maximumReplayDuration
    )
    self.holdDuration = max(holdDuration, 0)
  }

  nonisolated var totalDuration: TimeInterval {
    replayDuration + holdDuration
  }

  nonisolated var frameCount: Int {
    max(Int(ceil(totalDuration * Double(frameRate))) + 1, 2)
  }

  nonisolated func sourceTime(atVideoTime videoTime: TimeInterval) -> TimeInterval {
    guard replayDuration > 0 else { return sourceDuration }
    let visibleVideoTime = min(max(videoTime, 0), replayDuration)
    let progress = visibleVideoTime / replayDuration
    return min(sourceDuration * progress, sourceDuration)
  }

  nonisolated private static func sourceDuration(for drawing: DoodleDrawing) -> TimeInterval {
    var duration = drawing.duration
    for stroke in drawing.strokes {
      for point in stroke.points {
        duration = max(duration, point.time)
      }
    }
    return duration
  }
}

/// A sendable color representation for the Doodle mp4 overlay renderer.
private struct CardShareVideoRGBA: Sendable, Equatable {

  let red: CGFloat
  let green: CGFloat
  let blue: CGFloat
  let alpha: CGFloat

  @MainActor
  init(color: Color) {
    self.init(uiColor: UIColor(color))
  }

  @MainActor
  private init(uiColor: UIColor) {
    let resolved = uiColor.resolvedColor(with: .current)
    var red: CGFloat = 0
    var green: CGFloat = 0
    var blue: CGFloat = 0
    var alpha: CGFloat = 0

    if resolved.getRed(&red, green: &green, blue: &blue, alpha: &alpha) {
      self.init(red: red, green: green, blue: blue, alpha: alpha)
    } else {
      let components = resolved.cgColor.components ?? [0, 0, 0, 1]
      self.init(
        red: components[safe: 0] ?? 0,
        green: components[safe: 1] ?? components[safe: 0] ?? 0,
        blue: components[safe: 2] ?? components[safe: 0] ?? 0,
        alpha: components[safe: 3] ?? 1
      )
    }
  }

  private init(red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat) {
    self.red = red
    self.green = green
    self.blue = blue
    self.alpha = alpha
  }

  nonisolated func cgColor(opacity: CGFloat = 1) -> CGColor {
    CGColor(
      red: red,
      green: green,
      blue: blue,
      alpha: alpha * opacity
    )
  }
}

/// Immutable SwiftUI-rendered frame used as the static video background.
///
/// `CGImage` is immutable after rendering; this wrapper keeps the sendability
/// exception local to the video export boundary.
private struct CardShareVideoBaseFrame: @unchecked Sendable {
  let image: CGImage
}

/// Complete, sendable input for a background mp4 render.
private struct CardShareVideoRenderRequest: Sendable {
  let snapshotID: UUID
  let baseFrame: CardShareVideoBaseFrame
  let drawing: DoodleDrawing
  let recipe: CardShareVideoRecipe
  let inkColor: CardShareVideoRGBA
}

/// Replay preview using the same export chrome as the still-image share.
private struct CardShareDoodleReplayPreview: View {

  let snapshot: CardShareSnapshot
  let drawing: DoodleDrawing
  let palette: Palette

  @State private var replayStart = Date()

  var body: some View {
    CardShareExportFrame(snapshot: snapshot, palette: palette) {
      CardShareDoodleReplayContent(
        drawing: drawing,
        inkColor: palette.onSecondaryContainer,
        recipe: CardShareVideoRecipe(drawing: drawing),
        replayStart: replayStart
      )
    }
    .onAppear {
      replayStart = Date()
    }
  }
}

/// Animated Doodle body placed inside the shared export paper.
private struct CardShareDoodleReplayContent: View {

  let drawing: DoodleDrawing
  let inkColor: Color
  let recipe: CardShareVideoRecipe
  let replayStart: Date

  var body: some View {
    TimelineView(.animation) { timeline in
      CardShareDoodleReplayFrameContent(
        drawing: drawing,
        revealedTime: revealedTime(at: timeline.date),
        inkColor: inkColor
      )
    }
  }

  private func revealedTime(at date: Date) -> TimeInterval {
    let elapsed = max(date.timeIntervalSince(replayStart), 0)
    let cycleTime = elapsed.truncatingRemainder(dividingBy: recipe.totalDuration)
    return recipe.sourceTime(atVideoTime: cycleTime)
  }
}

/// One deterministic Doodle replay frame.
///
/// `revealedTime` is in the stored Doodle timeline, not video time. This makes
/// the preview and mp4 renderer share exactly the same drawing frame logic.
private struct CardShareDoodleReplayFrameContent: View {

  let drawing: DoodleDrawing
  let revealedTime: TimeInterval
  let inkColor: Color

  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 32, style: .continuous)
        .fill(.appOnSecondaryContainer.opacity(0.06))

      CardShareDoodleReplayCanvas(
        drawing: drawing,
        revealedTime: revealedTime,
        inkColor: inkColor
      )
      .padding(32)
    }
    .clipShape(RoundedRectangle(cornerRadius: 32, style: .continuous))
  }
}

/// Canvas renderer for a partially revealed doodle.
private struct CardShareDoodleReplayCanvas: View {

  let drawing: DoodleDrawing
  let revealedTime: TimeInterval
  let inkColor: Color

  var body: some View {
    Canvas(opaque: false, rendersAsynchronously: true) { context, size in
      guard drawing.canvasSize.width > 0, drawing.canvasSize.height > 0 else {
        return
      }

      let transform = drawingTransform(in: size)
      var context = context
      context.translateBy(x: transform.origin.x, y: transform.origin.y)
      context.scaleBy(x: transform.scale, y: transform.scale)

      for stroke in drawing.strokes {
        CardShareDoodleStrokeRenderer.draw(
          stroke,
          upTo: revealedTime,
          inkColor: inkColor,
          in: context
        )
      }
    }
  }

  private func drawingTransform(in size: CGSize) -> (origin: CGPoint, scale: CGFloat) {
    let scale = min(
      size.width / drawing.canvasSize.width,
      size.height / drawing.canvasSize.height
    )
    let fittedSize = CGSize(
      width: drawing.canvasSize.width * scale,
      height: drawing.canvasSize.height * scale
    )
    let origin = CGPoint(
      x: (size.width - fittedSize.width) / 2,
      y: (size.height - fittedSize.height) / 2
    )
    return (origin, scale)
  }
}

/// Stroke drawing helpers scoped to share previews.
private enum CardShareDoodleStrokeRenderer {

  static func draw(
    _ stroke: DoodleStroke,
    upTo limit: TimeInterval?,
    inkColor: Color,
    in context: GraphicsContext
  ) {
    let points = stroke.visibleSharePoints(upTo: limit)
    guard let first = points.first else { return }

    guard points.count > 1 else {
      let radius = first.width / 2
      context.fill(
        Path(ellipseIn: CGRect(
          x: first.location.x - radius,
          y: first.location.y - radius,
          width: first.width,
          height: first.width
        )),
        with: .color(inkColor)
      )
      return
    }

    if points.contains(where: \.hasExplicitWidth) {
      drawVariableWidth(points, inkColor: inkColor, in: context)
    } else {
      context.stroke(
        Path(cardShareSmooth: points.map(\.location)),
        with: .color(inkColor),
        style: StrokeStyle(lineWidth: CGFloat(stroke.width), lineCap: .round, lineJoin: .round)
      )
    }
  }

  private static func drawVariableWidth(
    _ points: [CardShareDoodleRenderPoint],
    inkColor: Color,
    in context: GraphicsContext
  ) {
    let points = points.removingNearDuplicates()
    guard points.count > 1 else { return }

    for index in 1..<points.count {
      let previous = points[index - 1]
      let point = points[index]
      let width = (previous.width + point.width) / 2
      var segment = Path()
      segment.move(to: previous.location)
      segment.addLine(to: point.location)
      context.stroke(
        segment,
        with: .color(inkColor),
        style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round)
      )
    }
  }
}

/// A resolved doodle point ready for Canvas drawing.
private struct CardShareDoodleRenderPoint {
  var location: CGPoint
  var width: CGFloat
  var hasExplicitWidth: Bool

  nonisolated init(location: CGPoint, width: CGFloat, hasExplicitWidth: Bool) {
    self.location = location
    self.width = width
    self.hasExplicitWidth = hasExplicitWidth
  }

  nonisolated init(point: DoodlePoint, fallbackWidth: Double) {
    self.init(
      location: point.shareLocation,
      width: CGFloat(point.resolvedShareWidth(fallback: fallbackWidth)),
      hasExplicitWidth: point.width != nil
    )
  }
}

private extension DoodleStroke {

  /// The stroke polyline truncated at `limit`, with a synthesized endpoint for
  /// the currently revealing segment.
  nonisolated func visibleSharePoints(upTo limit: TimeInterval?) -> [CardShareDoodleRenderPoint] {
    guard let first = points.first else { return [] }

    guard let limit else {
      return points.map { CardShareDoodleRenderPoint(point: $0, fallbackWidth: width) }
    }

    guard first.time <= limit else { return [] }

    var result = [CardShareDoodleRenderPoint(point: first, fallbackWidth: width)]
    for index in 1..<points.count {
      let point = points[index]
      if point.time <= limit {
        result.append(CardShareDoodleRenderPoint(point: point, fallbackWidth: width))
        continue
      }

      let previous = points[index - 1]
      let span = point.time - previous.time
      let progress = CGFloat(span > 0 ? (limit - previous.time) / span : 1)
        .clamped(to: 0...1)
      result.append(CardShareDoodleRenderPoint(
        location: previous.shareLocation.interpolate(to: point.shareLocation, progress: progress),
        width: CGFloat(previous.resolvedShareWidth(fallback: width))
          + (CGFloat(point.resolvedShareWidth(fallback: width))
            - CGFloat(previous.resolvedShareWidth(fallback: width))) * progress,
        hasExplicitWidth: previous.width != nil || point.width != nil
      ))
      break
    }
    return result
  }
}

private extension DoodlePoint {

  nonisolated var shareLocation: CGPoint {
    CGPoint(x: x, y: y)
  }

  nonisolated func resolvedShareWidth(fallback: Double) -> Double {
    width ?? fallback
  }
}

private extension Path {

  /// Smooth open path used for fixed-width share preview strokes.
  init(cardShareSmooth points: [CGPoint]) {
    self.init()
    guard let first = points.first else { return }
    move(to: first)
    guard points.count > 2 else {
      for point in points.dropFirst() {
        addLine(to: point)
      }
      return
    }

    func midpoint(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
      CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
    }

    for index in 1..<(points.count - 1) {
      addQuadCurve(to: midpoint(points[index], points[index + 1]), control: points[index])
    }
    addQuadCurve(to: points[points.count - 1], control: points[points.count - 2])
  }
}

private enum CardShareCGPathFactory {

  /// CoreGraphics equivalent of the SwiftUI smooth path used by replay preview.
  nonisolated static func smoothPath(points: [CGPoint]) -> CGPath {
    let path = CGMutablePath()
    guard let first = points.first else { return path }
    path.move(to: first)
    guard points.count > 2 else {
      for point in points.dropFirst() {
        path.addLine(to: point)
      }
      return path
    }

    func midpoint(_ a: CGPoint, _ b: CGPoint) -> CGPoint {
      CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
    }

    for index in 1..<(points.count - 1) {
      path.addQuadCurve(to: midpoint(points[index], points[index + 1]), control: points[index])
    }
    path.addQuadCurve(to: points[points.count - 1], control: points[points.count - 2])
    return path
  }
}

private extension CGPoint {

  nonisolated func interpolate(to point: CGPoint, progress: CGFloat) -> CGPoint {
    CGPoint(
      x: x + (point.x - x) * progress,
      y: y + (point.y - y) * progress
    )
  }

  nonisolated func distance(to point: CGPoint) -> CGFloat {
    hypot(x - point.x, y - point.y)
  }
}

private extension Array where Element == CardShareDoodleRenderPoint {

  nonisolated func removingNearDuplicates() -> [CardShareDoodleRenderPoint] {
    var result: [CardShareDoodleRenderPoint] = []
    for point in self {
      guard let previous = result.last else {
        result.append(point)
        continue
      }

      if previous.location.distance(to: point.location) > 0.2 {
        result.append(point)
      }
    }
    return result
  }
}

private extension Array {

  nonisolated subscript(safe index: Int) -> Element? {
    indices.contains(index) ? self[index] : nil
  }
}

/// Generates a shareable mp4 from a Doodle card replay.
///
/// This MainActor boundary resolves UI-owned inputs once: the static SwiftUI
/// share frame and the Doodle ink color. The heavy frame loop is handed to
/// `CardShareVideoRenderWorker`, which composites the moving Doodle layer and
/// appends frames to `AVAssetWriter` off the main actor.
@MainActor
enum CardShareVideoRenderer {

  /// Writes a replay mp4 for a Doodle snapshot into a temporary file.
  static func mp4File(
    for snapshot: CardShareSnapshot,
    palette: Palette = .default,
    pixelSize: CGSize = CardShareImageRenderer.defaultPixelSize,
    frameRate: Int32 = CardShareVideoRecipe.defaultFrameRate,
    directory: URL = FileManager.default.temporaryDirectory
  ) async throws -> URL {
    guard case .doodle(let drawingData, _) = snapshot.content,
      let drawingData,
      let drawing = try? JSONDecoder().decode(DoodleDrawing.self, from: drawingData)
    else {
      throw CardShareVideoRendererError.missingDoodleDrawing
    }

    return try await mp4File(
      for: snapshot,
      drawing: drawing,
      palette: palette,
      pixelSize: pixelSize,
      frameRate: frameRate,
      directory: directory
    )
  }

  /// Writes a replay mp4 for an already-decoded Doodle drawing.
  static func mp4File(
    for snapshot: CardShareSnapshot,
    drawing: DoodleDrawing,
    palette: Palette = .default,
    pixelSize: CGSize = CardShareImageRenderer.defaultPixelSize,
    frameRate: Int32 = CardShareVideoRecipe.defaultFrameRate,
    directory: URL = FileManager.default.temporaryDirectory
  ) async throws -> URL {
    guard let baseFrameImage = CardShareImageRenderer.doodleVideoBaseImage(
      for: snapshot,
      palette: palette,
      pixelSize: pixelSize
    )?.cgImage
    else {
      throw CardShareVideoRendererError.renderingFailed
    }

    let recipe = CardShareVideoRecipe(
      drawing: drawing,
      pixelSize: pixelSize,
      frameRate: frameRate
    )
    let request = CardShareVideoRenderRequest(
      snapshotID: snapshot.id,
      baseFrame: CardShareVideoBaseFrame(image: baseFrameImage),
      drawing: drawing,
      recipe: recipe,
      inkColor: CardShareVideoRGBA(color: palette.onSecondaryContainer)
    )

    return try await CardShareVideoRenderWorker().mp4File(
      request: request,
      directory: directory
    )
  }
}

/// Background writer for Doodle replay mp4 files.
///
/// This actor keeps the expensive frame loop and `AVAssetWriter` work away from
/// the main actor. The preview and static video chrome stay SwiftUI-native;
/// export only redraws the moving Doodle vector layer for each video frame.
private actor CardShareVideoRenderWorker {

  /// Number of generated frames between cooperative scheduler yields.
  private static let cooperativeYieldFrameInterval = 4

  func mp4File(
    request: CardShareVideoRenderRequest,
    directory: URL
  ) async throws -> URL {
    let recipe = request.recipe
    let outputURL = directory.appending(path: "Journal-\(request.snapshotID.uuidString)-Replay.mp4")
    try? FileManager.default.removeItem(at: outputURL)

    let writer = try AVAssetWriter(outputURL: outputURL, fileType: .mp4)
    let input = AVAssetWriterInput(
      mediaType: .video,
      outputSettings: outputSettings(for: recipe.pixelSize)
    )
    input.expectsMediaDataInRealTime = false

    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
      assetWriterInput: input,
      sourcePixelBufferAttributes: pixelBufferAttributes(for: recipe.pixelSize)
    )

    guard writer.canAdd(input) else {
      throw CardShareVideoRendererError.cannotAddVideoInput
    }

    writer.add(input)

    guard writer.startWriting() else {
      throw CardShareVideoRendererError.startWritingFailed
    }
    writer.startSession(atSourceTime: .zero)
    var didCompleteWriting = false
    defer {
      if !didCompleteWriting {
        writer.cancelWriting()
        try? FileManager.default.removeItem(at: outputURL)
      }
    }

    for frameIndex in 0..<recipe.frameCount {
      try Task.checkCancellation()

      while !input.isReadyForMoreMediaData {
        try Task.checkCancellation()
        try await Task.sleep(for: .milliseconds(8))
      }

      let presentationTime = CMTime(value: Int64(frameIndex), timescale: recipe.frameRate)
      let videoTime = TimeInterval(frameIndex) / TimeInterval(recipe.frameRate)
      let sourceTime = recipe.sourceTime(atVideoTime: videoTime)
      let pixelBuffer = try pixelBuffer(pixelSize: recipe.pixelSize, pool: adaptor.pixelBufferPool)
      try drawFrame(request: request, sourceTime: sourceTime, into: pixelBuffer)

      guard adaptor.append(pixelBuffer, withPresentationTime: presentationTime) else {
        throw CardShareVideoRendererError.appendFailed
      }

      if (frameIndex + 1).isMultiple(of: Self.cooperativeYieldFrameInterval) {
        await Task.yield()
        try Task.checkCancellation()
      }
    }

    input.markAsFinished()
    try await writer.finishWritingChecked()
    didCompleteWriting = true
    return outputURL
  }

  private func outputSettings(for pixelSize: CGSize) -> [String: Any] {
    [
      AVVideoCodecKey: AVVideoCodecType.h264,
      AVVideoWidthKey: Int(pixelSize.width.rounded()),
      AVVideoHeightKey: Int(pixelSize.height.rounded()),
      AVVideoCompressionPropertiesKey: [
        AVVideoAverageBitRateKey: 8_000_000,
        AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
      ],
    ]
  }

  private func pixelBufferAttributes(for pixelSize: CGSize) -> [String: Any] {
    [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
      kCVPixelBufferWidthKey as String: Int(pixelSize.width.rounded()),
      kCVPixelBufferHeightKey as String: Int(pixelSize.height.rounded()),
      kCVPixelBufferCGImageCompatibilityKey as String: true,
      kCVPixelBufferCGBitmapContextCompatibilityKey as String: true,
      kCVPixelBufferIOSurfacePropertiesKey as String: [:],
    ]
  }

  private func pixelBuffer(
    pixelSize: CGSize,
    pool: CVPixelBufferPool?
  ) throws -> CVPixelBuffer {
    var pixelBuffer: CVPixelBuffer?
    let status: CVReturn
    if let pool {
      status = CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
    } else {
      status = CVPixelBufferCreate(
        nil,
        Int(pixelSize.width.rounded()),
        Int(pixelSize.height.rounded()),
        kCVPixelFormatType_32BGRA,
        pixelBufferAttributes(for: pixelSize) as CFDictionary,
        &pixelBuffer
      )
    }

    guard status == kCVReturnSuccess, let pixelBuffer else {
      throw CardShareVideoRendererError.pixelBufferCreationFailed
    }

    return pixelBuffer
  }

  private func drawFrame(
    request: CardShareVideoRenderRequest,
    sourceTime: TimeInterval,
    into pixelBuffer: CVPixelBuffer
  ) throws {
    let pixelSize = request.recipe.pixelSize
    CVPixelBufferLockBaseAddress(pixelBuffer, [])
    defer {
      CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
    }

    guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer),
      let context = CGContext(
        data: baseAddress,
        width: Int(pixelSize.width.rounded()),
        height: Int(pixelSize.height.rounded()),
        bitsPerComponent: 8,
        bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue
          | CGImageAlphaInfo.premultipliedFirst.rawValue
      )
    else {
      throw CardShareVideoRendererError.bitmapContextCreationFailed
    }

    context.clear(CGRect(origin: .zero, size: pixelSize))
    context.translateBy(x: 0, y: pixelSize.height)
    context.scaleBy(x: 1, y: -1)

    let frameRect = CGRect(origin: .zero, size: pixelSize)
    context.interpolationQuality = .high
    drawBaseFrame(request.baseFrame.image, in: frameRect, context: context)
    drawDoodleFrame(
      drawing: request.drawing,
      sourceTime: sourceTime,
      inkColor: request.inkColor,
      in: Self.doodleContentRect(in: pixelSize),
      context: context
    )
  }

  private func drawBaseFrame(
    _ image: CGImage,
    in rect: CGRect,
    context: CGContext
  ) {
    context.saveGState()
    // `drawFrame` flips the bitmap context into SwiftUI-style coordinates for
    // vector drawing. `CGImage` drawing has the opposite vertical convention, so
    // flip only the static SwiftUI snapshot back before compositing strokes.
    context.translateBy(x: rect.minX, y: rect.maxY)
    context.scaleBy(x: 1, y: -1)
    context.draw(image, in: CGRect(origin: .zero, size: rect.size))
    context.restoreGState()
  }

  /// Content rect that mirrors the Doodle well in `CardShareExportFrame`.
  private nonisolated static func doodleContentRect(in pixelSize: CGSize) -> CGRect {
    let frameRect = CGRect(origin: .zero, size: pixelSize)
    let paperRect = frameRect.insetBy(dx: 72, dy: 72)
    let innerRect = paperRect.insetBy(dx: 56, dy: 56)
    let headerHeight: CGFloat = 42
    let footerHeight: CGFloat = 30
    let verticalSpacing: CGFloat = 36
    let contentMinY = innerRect.minY + headerHeight + verticalSpacing
    let contentMaxY = innerRect.maxY - footerHeight - verticalSpacing
    return CGRect(
      x: innerRect.minX,
      y: contentMinY,
      width: innerRect.width,
      height: contentMaxY - contentMinY
    )
  }

  private func drawDoodleFrame(
    drawing: DoodleDrawing,
    sourceTime: TimeInterval,
    inkColor: CardShareVideoRGBA,
    in rect: CGRect,
    context: CGContext
  ) {
    let contentPath = CGPath(
      roundedRect: rect,
      cornerWidth: 32,
      cornerHeight: 32,
      transform: nil
    )

    guard drawing.canvasSize.width > 0, drawing.canvasSize.height > 0 else {
      return
    }

    let drawingRect = rect.insetBy(dx: 32, dy: 32)
    let scale = min(
      drawingRect.width / drawing.canvasSize.width,
      drawingRect.height / drawing.canvasSize.height
    )
    let fittedSize = CGSize(
      width: drawing.canvasSize.width * scale,
      height: drawing.canvasSize.height * scale
    )
    let origin = CGPoint(
      x: drawingRect.minX + (drawingRect.width - fittedSize.width) / 2,
      y: drawingRect.minY + (drawingRect.height - fittedSize.height) / 2
    )

    context.saveGState()
    context.addPath(contentPath)
    context.clip()
    context.translateBy(x: origin.x, y: origin.y)
    context.scaleBy(x: scale, y: scale)

    for stroke in drawing.strokes {
      drawStroke(
        stroke,
        upTo: sourceTime,
        inkColor: inkColor,
        context: context
      )
    }
    context.restoreGState()
  }

  private func drawStroke(
    _ stroke: DoodleStroke,
    upTo limit: TimeInterval,
    inkColor: CardShareVideoRGBA,
    context: CGContext
  ) {
    let points = stroke.visibleSharePoints(upTo: limit)
    guard let first = points.first else { return }

    context.setFillColor(inkColor.cgColor())
    context.setStrokeColor(inkColor.cgColor())

    guard points.count > 1 else {
      let radius = first.width / 2
      context.fillEllipse(in: CGRect(
        x: first.location.x - radius,
        y: first.location.y - radius,
        width: first.width,
        height: first.width
      ))
      return
    }

    context.setLineCap(.round)
    context.setLineJoin(.round)

    if points.contains(where: \.hasExplicitWidth) {
      for index in 1..<points.count {
        let previous = points[index - 1]
        let point = points[index]
        context.setLineWidth((previous.width + point.width) / 2)
        context.beginPath()
        context.move(to: previous.location)
        context.addLine(to: point.location)
        context.strokePath()
      }
    } else {
      context.setLineWidth(CGFloat(stroke.width))
      context.addPath(CardShareCGPathFactory.smoothPath(points: points.map(\.location)))
      context.strokePath()
    }
  }
}

/// Failures produced while creating a share video.
enum CardShareVideoRendererError: Error {
  /// The card did not contain decodable `DoodleDrawing` JSON.
  case missingDoodleDrawing

  /// `AVAssetWriter` rejected the configured video input.
  case cannotAddVideoInput

  /// `AVAssetWriter` could not start writing the output file.
  case startWritingFailed

  /// SwiftUI did not produce a frame image.
  case renderingFailed

  /// Core Video could not allocate a frame buffer.
  case pixelBufferCreationFailed

  /// Core Graphics could not draw into the allocated frame buffer.
  case bitmapContextCreationFailed

  /// The frame buffer could not be appended to the video stream.
  case appendFailed

  /// `AVAssetWriter` finished in a failed or cancelled state.
  case finishFailed
}

/// Sendability shim for legacy Objective-C callbacks.
///
/// `AVAssetWriter` is not `Sendable`, but `finishWriting` invokes a sendable
/// completion handler. The renderer only reads `status` and `error` after
/// AVFoundation finishes, so this box keeps that boundary explicit and local.
private final class CardShareAssetWriterBox: @unchecked Sendable {
  nonisolated(unsafe) let writer: AVAssetWriter

  nonisolated init(_ writer: AVAssetWriter) {
    self.writer = writer
  }
}

private extension AVAssetWriter {

  nonisolated func finishWritingChecked() async throws {
    let writerBox = CardShareAssetWriterBox(self)
    try await withCheckedThrowingContinuation { continuation in
      finishWriting {
        if writerBox.writer.status == .completed {
          continuation.resume()
        } else {
          continuation.resume(throwing: writerBox.writer.error ?? CardShareVideoRendererError.finishFailed)
        }
      }
    }
  }
}

private extension Comparable {

  nonisolated func clamped(to range: ClosedRange<Self>) -> Self {
    min(max(self, range.lowerBound), range.upperBound)
  }
}
