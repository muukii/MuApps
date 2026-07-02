@preconcurrency import AVFoundation
import AVKit
import CaptureBauhaus
import CaptureDoodle
import Foundation
import JournalModel
import MuColor
import SwiftUI
import UIKit

/// A pre-share review screen for one prepared card snapshot.
///
/// The context menu opens this screen first so the user can inspect the actual
/// generated PNG or mp4 before the system activity sheet appears.
struct CardSharePreviewScreen: View {

  let snapshot: CardShareSnapshot
  let palette: Palette

  @Environment(\.dismiss) private var dismiss
  @Environment(\.colorScheme) private var colorScheme
  @State private var selectedMode: CardSharePreviewMode
  @State private var previewArtifacts: [CardSharePreviewRenderRequest: CardSharePreviewArtifactState] = [:]
  @State private var renderingPreviewRequests: Set<CardSharePreviewRenderRequest> = []
  @State private var failedPreviewRequests: Set<CardSharePreviewRenderRequest> = []
  @State private var activityPresentation: CardShareActivityPresentation?
  @State private var isPreparingShareItem: Bool = false
  @State private var isShareFailurePresented: Bool = false

  private let videoContent: CardShareVideoContent?

  init(snapshot: CardShareSnapshot, palette: Palette = .default) {
    self.snapshot = snapshot
    self.palette = palette
    self.videoContent = CardShareVideoContent(snapshot: snapshot)
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

        CardSharePreviewArtifactFrame(state: currentPreviewState)
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
              .disabled(isShareActionDisabled)
          case .video:
            Button("Share Video", action: shareVideo)
              .disabled(isShareActionDisabled)
          }
        }
      }
      .task(id: previewRenderRequest) {
        await renderPreview(for: previewRenderRequest)
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
    videoContent != nil
  }

  private var isShareActionDisabled: Bool {
    isPreparingShareItem || previewArtifacts[previewRenderRequest]?.fileURL == nil
  }

  private var previewRenderRequest: CardSharePreviewRenderRequest {
    previewRenderRequest(for: selectedMode)
  }

  private func previewRenderRequest(
    for mode: CardSharePreviewMode
  ) -> CardSharePreviewRenderRequest {
    CardSharePreviewRenderRequest(
      snapshotID: snapshot.id,
      mode: mode,
      usesDarkAppearance: colorScheme == .dark
    )
  }

  private var currentPreviewState: CardSharePreviewArtifactState {
    let request = previewRenderRequest

    if let artifact = previewArtifacts[request] {
      return artifact
    }

    if renderingPreviewRequests.contains(request) {
      return .rendering
    }

    if failedPreviewRequests.contains(request) {
      return .failed
    }

    return .idle
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
    let request = previewRenderRequest(for: .image)
    guard let fileURL = previewArtifacts[request]?.fileURL else {
      isShareFailurePresented = true
      return
    }

    presentActivitySheet(for: fileURL)
  }

  private func shareVideo() {
    let request = previewRenderRequest(for: .video)
    guard let fileURL = previewArtifacts[request]?.fileURL else {
      isShareFailurePresented = true
      return
    }

    presentActivitySheet(for: fileURL)
  }

  private func presentActivitySheet(for fileURL: URL) {
    isPreparingShareItem = true
    defer { isPreparingShareItem = false }
    activityPresentation = CardShareActivityPresentation(fileURL: fileURL)
  }

  @MainActor
  private func renderPreview(for request: CardSharePreviewRenderRequest) async {
    guard previewArtifacts[request] == nil,
          renderingPreviewRequests.contains(request) == false
    else {
      return
    }

    renderingPreviewRequests.insert(request)
    failedPreviewRequests.remove(request)

    do {
      let directory = try Self.makePreviewDirectory(for: request)
      switch request.mode {
      case .image:
        let fileURL = try CardShareImageRenderer.pngFile(
          for: snapshot,
          palette: palette,
          colorScheme: request.colorScheme,
          directory: directory
        )
        try Task.checkCancellation()
        guard let image = UIImage(contentsOfFile: fileURL.path(percentEncoded: false)) else {
          throw CardSharePreviewRenderError.imageLoadFailed
        }
        previewArtifacts[request] = .image(fileURL: fileURL, image: image)
      case .video:
        let fileURL = try await renderVideoPreview(
          colorScheme: request.colorScheme,
          directory: directory
        )
        try Task.checkCancellation()
        previewArtifacts[request] = .video(fileURL: fileURL)
      }
      renderingPreviewRequests.remove(request)
    } catch is CancellationError {
      renderingPreviewRequests.remove(request)
    } catch {
      renderingPreviewRequests.remove(request)
      failedPreviewRequests.insert(request)
    }
  }

  @MainActor
  private func renderVideoPreview(
    colorScheme: ColorScheme,
    directory: URL
  ) async throws -> URL {
    guard let videoContent else {
      throw CardSharePreviewRenderError.missingVideoContent
    }

    await Task.yield()

    switch videoContent {
    case .doodle(let drawing):
      return try await CardShareVideoRenderer.mp4File(
        for: snapshot,
        drawing: drawing,
        palette: palette,
        colorScheme: colorScheme,
        directory: directory
      )
    case .bauhaus(let document):
      return try await CardShareVideoRenderer.mp4File(
        for: snapshot,
        bauhausDocument: document,
        palette: palette,
        colorScheme: colorScheme,
        directory: directory
      )
    }
  }

  private static func makePreviewDirectory(
    for request: CardSharePreviewRenderRequest
  ) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: "Journal-SharePreview-\(request.snapshotID.uuidString)-\(request.mode.rawValue)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
  }
}

/// Identity for one asynchronously generated preview artifact.
private struct CardSharePreviewRenderRequest: Hashable {
  let snapshotID: UUID
  let mode: CardSharePreviewMode
  let usesDarkAppearance: Bool

  var colorScheme: ColorScheme {
    usesDarkAppearance ? .dark : .light
  }
}

/// Loading state for the actual file shown in the preview.
private enum CardSharePreviewArtifactState {
  case idle
  case rendering
  case image(fileURL: URL, image: UIImage)
  case video(fileURL: URL)
  case failed

  var fileURL: URL? {
    switch self {
    case .image(let fileURL, _), .video(let fileURL):
      return fileURL
    case .idle, .rendering, .failed:
      return nil
    }
  }
}

/// Failures while preparing the exact preview artifact.
private enum CardSharePreviewRenderError: Error {
  case imageLoadFailed
  case missingVideoContent
}

/// Decoded replay payload that can produce a share video.
private enum CardShareVideoContent: Sendable {
  case doodle(DoodleDrawing)
  case bauhaus(BauhausGridDocument)

  init?(snapshot: CardShareSnapshot) {
    switch snapshot.content {
    case .doodle(let drawingData, _):
      guard let drawingData,
            let drawing = try? JSONDecoder().decode(DoodleDrawing.self, from: drawingData)
      else {
        return nil
      }
      self = .doodle(drawing)
    case .bauhaus(let documentData, _):
      guard let documentData,
            let document = try? JSONDecoder().decode(BauhausGridDocument.self, from: documentData),
            document.replay?.isEmpty == false
      else {
        return nil
      }
      self = .bauhaus(document)
    default:
      return nil
    }
  }
}

/// The share formats the preview screen can render for visual confirmation.
private enum CardSharePreviewMode: String, Hashable, Identifiable {
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

/// Displays the actual generated share artifact in the preview sheet.
private struct CardSharePreviewArtifactFrame: View {

  let state: CardSharePreviewArtifactState

  var body: some View {
    GeometryReader { proxy in
      let size = fittedSize(in: proxy.size)

      ScrollView {
        VStack {
          CardSharePreviewArtifactContent(state: state)
            .frame(width: size.width, height: size.height)
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

  private var exportSize: CGSize {
    CardShareImageRenderer.defaultPixelSize
  }
}

/// Visual body for one preview artifact state.
private struct CardSharePreviewArtifactContent: View {

  let state: CardSharePreviewArtifactState

  var body: some View {
    ZStack {
      Rectangle()
        .fill(Color.secondary.opacity(0.08))

      switch state {
      case .idle, .rendering:
        ProgressView()
      case .image(_, let image):
        Image(uiImage: image)
          .resizable()
          .interpolation(.high)
          .scaledToFit()
      case .video(let fileURL):
        CardSharePreviewVideoPlayer(fileURL: fileURL)
      case .failed:
        Image(systemName: "exclamationmark.triangle")
          .font(.system(size: 44, weight: .semibold))
          .foregroundStyle(.secondary)
      }
    }
  }
}

/// Looped playback for the generated mp4 preview file.
private struct CardSharePreviewVideoPlayer: View {

  let fileURL: URL

  @State private var player: AVQueuePlayer
  @State private var looper: AVPlayerLooper?
  @State private var loadedURL: URL?

  init(fileURL: URL) {
    let player = AVQueuePlayer()
    player.isMuted = true
    _player = State(initialValue: player)
    self.fileURL = fileURL
  }

  var body: some View {
    VideoPlayer(player: player)
      .onAppear {
        configurePlayerIfNeeded()
        player.play()
      }
      .onChange(of: fileURL) { _, _ in
        configurePlayerIfNeeded()
        player.play()
      }
      .onDisappear {
        player.pause()
      }
  }

  private func configurePlayerIfNeeded() {
    guard loadedURL != fileURL else { return }

    player.removeAllItems()
    let item = AVPlayerItem(url: fileURL)
    looper = AVPlayerLooper(player: player, templateItem: item)
    loadedURL = fileURL
  }
}

/// Timing recipe shared by video preview and mp4 export.
///
/// The stored Doodle timeline is the source of truth, but share videos clamp very
/// long drawings to a compact replay length and stretch very short drawings so
/// they remain inspectable after export.
private struct CardShareVideoRecipe: Sendable, Equatable {

  /// Default export frame rate for replay videos.
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

/// A sendable color representation for Core Graphics mp4 overlay renderers.
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

/// Timing and size settings for a Bauhaus share-video render.
private struct CardShareBauhausVideoRecipe: Sendable, Equatable {

  let frameRate: Int32
  let pixelSize: CGSize
  let replayRecipe: BauhausGridReplayRecipe

  init(
    replay: BauhausGridReplay,
    pixelSize: CGSize = CardShareImageRenderer.defaultPixelSize,
    frameRate: Int32 = CardShareVideoRecipe.defaultFrameRate
  ) {
    self.frameRate = max(frameRate, 1)
    self.pixelSize = pixelSize
    self.replayRecipe = BauhausGridReplayRecipe(replay: replay)
  }

  nonisolated var frameCount: Int {
    max(Int(ceil(replayRecipe.totalDuration * Double(frameRate))) + 1, 2)
  }
}

/// Complete, sendable input for a Bauhaus background mp4 render.
private struct CardShareBauhausVideoRenderRequest: Sendable {
  let snapshotID: UUID
  let baseFrame: CardShareVideoBaseFrame
  let replay: BauhausGridReplay
  let recipe: CardShareBauhausVideoRecipe
  let colors: CardShareBauhausVideoColors
}

/// Resolved Bauhaus colors for Core Graphics video drawing.
private struct CardShareBauhausVideoColors: Sendable, Equatable {
  let swatches: CardShareBauhausVideoSwatchColors
  let paper: CardShareVideoRGBA
  let emptyCell: CardShareVideoRGBA

  @MainActor
  init(colors: BauhausResolvedColors) {
    self.swatches = CardShareBauhausVideoSwatchColors(colors: colors.swatches)
    self.paper = CardShareVideoRGBA(color: colors.chrome.paper)
    self.emptyCell = CardShareVideoRGBA(color: colors.chrome.emptyCell)
  }
}

/// Resolved Bauhaus swatch colors for Core Graphics video drawing.
private struct CardShareBauhausVideoSwatchColors: Sendable, Equatable {
  let slot1: CardShareVideoRGBA
  let slot2: CardShareVideoRGBA
  let slot3: CardShareVideoRGBA
  let slot4: CardShareVideoRGBA
  let slot5: CardShareVideoRGBA
  let slot6: CardShareVideoRGBA
  let slot7: CardShareVideoRGBA

  @MainActor
  init(colors: BauhausSwatchColors) {
    self.slot1 = CardShareVideoRGBA(color: colors.slot1)
    self.slot2 = CardShareVideoRGBA(color: colors.slot2)
    self.slot3 = CardShareVideoRGBA(color: colors.slot3)
    self.slot4 = CardShareVideoRGBA(color: colors.slot4)
    self.slot5 = CardShareVideoRGBA(color: colors.slot5)
    self.slot6 = CardShareVideoRGBA(color: colors.slot6)
    self.slot7 = CardShareVideoRGBA(color: colors.slot7)
  }

  nonisolated func color(for swatch: BauhausSwatch) -> CardShareVideoRGBA {
    switch swatch {
    case .slot1:
      return slot1
    case .slot2:
      return slot2
    case .slot3:
      return slot3
    case .slot4:
      return slot4
    case .slot5:
      return slot5
    case .slot6:
      return slot6
    case .slot7:
      return slot7
    }
  }
}

/// A resolved doodle point ready for Core Graphics video drawing.
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

private enum CardShareCGPathFactory {

  /// Core Graphics smooth path used by the Doodle video renderer.
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

private extension CGRect {

  nonisolated func scaledAboutCenter(by scale: CGFloat) -> CGRect {
    insetBy(
      dx: width * (1 - scale) / 2,
      dy: height * (1 - scale) / 2
    )
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

/// Generates shareable mp4 files from replay-capable cards.
///
/// This MainActor boundary resolves UI-owned inputs once: the static SwiftUI
/// share frame and render colors. The heavy frame loop is handed to
/// `CardShareVideoRenderWorker`, which composites the moving replay layer and
/// appends frames to `AVAssetWriter` off the main actor.
@MainActor
enum CardShareVideoRenderer {

  /// Writes a replay mp4 for a Doodle snapshot into a temporary file.
  static func mp4File(
    for snapshot: CardShareSnapshot,
    palette: Palette = .default,
    colorScheme: ColorScheme = .light,
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
      colorScheme: colorScheme,
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
    colorScheme: ColorScheme = .light,
    pixelSize: CGSize = CardShareImageRenderer.defaultPixelSize,
    frameRate: Int32 = CardShareVideoRecipe.defaultFrameRate,
    directory: URL = FileManager.default.temporaryDirectory
  ) async throws -> URL {
    guard let baseFrameImage = CardShareImageRenderer.doodleVideoBaseImage(
      for: snapshot,
      palette: palette,
      colorScheme: colorScheme,
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

  /// Writes a replay mp4 for an already-decoded Bauhaus document.
  static func mp4File(
    for snapshot: CardShareSnapshot,
    bauhausDocument document: BauhausGridDocument,
    palette: Palette = .default,
    colorScheme: ColorScheme = .light,
    pixelSize: CGSize = CardShareImageRenderer.defaultPixelSize,
    frameRate: Int32 = CardShareVideoRecipe.defaultFrameRate,
    directory: URL = FileManager.default.temporaryDirectory
  ) async throws -> URL {
    guard let replay = document.replay, replay.isEmpty == false else {
      throw CardShareVideoRendererError.missingBauhausReplay
    }

    guard let baseFrameImage = CardShareImageRenderer.bauhausVideoBaseImage(
      for: snapshot,
      palette: palette,
      colorScheme: colorScheme,
      pixelSize: pixelSize
    )?.cgImage
    else {
      throw CardShareVideoRendererError.renderingFailed
    }

    let playbackReplay = replay.presentationTimeline(
      eventInterval: BauhausGridReplayRecipe.eventInterval
    )
    let request = CardShareBauhausVideoRenderRequest(
      snapshotID: snapshot.id,
      baseFrame: CardShareVideoBaseFrame(image: baseFrameImage),
      replay: playbackReplay,
      recipe: CardShareBauhausVideoRecipe(
        replay: playbackReplay,
        pixelSize: pixelSize,
        frameRate: frameRate
      ),
      colors: CardShareBauhausVideoColors(
        colors: BauhausColorPalette.default.colors(for: colorScheme)
      )
    )

    return try await CardShareVideoRenderWorker().mp4File(
      request: request,
      directory: directory
    )
  }
}

/// Background writer for replay mp4 files.
///
/// This actor keeps the expensive frame loop and `AVAssetWriter` work away from
/// the main actor. The preview and static video chrome stay SwiftUI-native;
/// export only redraws the moving replay layer for each video frame.
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

  func mp4File(
    request: CardShareBauhausVideoRenderRequest,
    directory: URL
  ) async throws -> URL {
    let recipe = request.recipe
    let outputURL = directory.appending(path: "Journal-\(request.snapshotID.uuidString)-Bauhaus-Replay.mp4")
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
      let pixelBuffer = try pixelBuffer(pixelSize: recipe.pixelSize, pool: adaptor.pixelBufferPool)
      try drawFrame(request: request, videoTime: videoTime, into: pixelBuffer)

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
      in: Self.shareContentRect(in: pixelSize),
      context: context
    )
  }

  private func drawFrame(
    request: CardShareBauhausVideoRenderRequest,
    videoTime: TimeInterval,
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
    drawBauhausFrame(
      replay: request.replay,
      videoTime: videoTime,
      recipe: request.recipe.replayRecipe,
      colors: request.colors,
      in: Self.shareContentRect(in: pixelSize),
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

  /// Content rect that mirrors the media well in `CardShareExportFrame`.
  private nonisolated static func shareContentRect(in pixelSize: CGSize) -> CGRect {
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

  private func drawBauhausFrame(
    replay: BauhausGridReplay,
    videoTime: TimeInterval,
    recipe: BauhausGridReplayRecipe,
    colors: CardShareBauhausVideoColors,
    in rect: CGRect,
    context: CGContext
  ) {
    let contentPath = CGPath(
      roundedRect: rect,
      cornerWidth: 32,
      cornerHeight: 32,
      transform: nil
    )

    let drawingRect = rect.insetBy(dx: 32, dy: 32)
    let boardSide = min(drawingRect.width, drawingRect.height)
    guard boardSide > 0 else { return }

    let boardRect = CGRect(
      x: drawingRect.midX - boardSide / 2,
      y: drawingRect.midY - boardSide / 2,
      width: boardSide,
      height: boardSide
    )
    let replayFrame = BauhausGridReplayFrame(
      replay: replay,
      sourceTime: recipe.sourceTime(atVideoTime: videoTime)
    )

    context.saveGState()
    context.addPath(contentPath)
    context.clip()
    context.setFillColor(colors.paper.cgColor())
    context.fill(boardRect)
    drawBauhausGrid(
      replayFrame: replayFrame,
      videoTime: videoTime,
      recipe: recipe,
      colors: colors,
      in: boardRect.insetBy(dx: 8, dy: 8),
      context: context
    )
    context.restoreGState()
  }

  private func drawBauhausGrid(
    replayFrame: BauhausGridReplayFrame,
    videoTime: TimeInterval,
    recipe: BauhausGridReplayRecipe,
    colors: CardShareBauhausVideoColors,
    in rect: CGRect,
    context: CGContext
  ) {
    let spacing: CGFloat = 2
    let dimension = CGFloat(BauhausGridArtwork.dimension)
    let cellSide = (min(rect.width, rect.height) - spacing * (dimension - 1)) / dimension
    guard cellSide > 0 else { return }

    for position in BauhausGridArtwork.positions {
      let cellRect = CGRect(
        x: rect.minX + CGFloat(position.column) * (cellSide + spacing),
        y: rect.minY + CGFloat(position.row) * (cellSide + spacing),
        width: cellSide,
        height: cellSide
      )

      context.setFillColor(colors.emptyCell.cgColor())
      context.fill(cellRect)

      guard let tile = replayFrame.artwork[position] else { continue }

      let appearance = replayFrame.appearanceValues(
        for: position,
        atVideoTime: videoTime,
        recipe: recipe
      )
      let shapeRect = cellRect.scaledAboutCenter(by: appearance.scale)

      context.setFillColor(
        colors.swatches.color(for: tile.backgroundSwatch).cgColor(opacity: appearance.opacity)
      )
      context.fill(cellRect)

      context.saveGState()
      context.addPath(tile.shape.path(in: shapeRect).cgPath)
      context.setFillColor(
        colors.swatches.color(for: tile.shapeSwatch).cgColor(opacity: appearance.opacity)
      )
      context.fillPath()
      context.restoreGState()
    }
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

  /// The Bauhaus document did not contain an authored replay timeline.
  case missingBauhausReplay

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
