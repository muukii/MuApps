import Foundation
import SwiftUI
import UIKit

/// Persistable Bauhaus card content.
///
/// `artwork` is the canonical final grid for static rendering. `replay` is
/// optional because cards saved before replay support only contain the final
/// `BauhausGridArtwork` JSON and cannot truthfully reconstruct edit order.
public struct BauhausGridDocument: Codable, Equatable, Sendable {

  /// A blank document ready for a new capture session.
  public static let empty = BauhausGridDocument(
    artwork: .empty,
    replay: BauhausGridReplay()
  )

  /// The final grid state. Static thumbnails, editing, and fallback rendering
  /// should read this value even when replay data is absent.
  public var artwork: BauhausGridArtwork

  /// Authored edit timeline from an empty grid to `artwork`.
  public var replay: BauhausGridReplay?

  public init(
    artwork: BauhausGridArtwork,
    replay: BauhausGridReplay? = nil
  ) {
    self.artwork = artwork
    self.replay = replay
  }

  /// Whether the final artwork contains no tiles.
  public var isEmpty: Bool {
    artwork.isEmpty
  }

  private enum CodingKeys: String, CodingKey {
    case artwork
    case replay
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    if container.contains(.artwork) {
      artwork = try container.decode(BauhausGridArtwork.self, forKey: .artwork)
      replay = try container.decodeIfPresent(BauhausGridReplay.self, forKey: .replay)
    } else {
      artwork = try BauhausGridArtwork(from: decoder)
      replay = nil
    }
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(artwork, forKey: .artwork)
    try container.encodeIfPresent(replay, forKey: .replay)
  }

  /// Rasterizes the final artwork into a square image for explicit raster
  /// outputs. The document itself remains editable JSON; normal card UI should
  /// render `BauhausGridArtworkView` or `BauhausGridReplayView` directly.
  @MainActor
  public func image(
    colorScheme: ColorScheme = .light,
    colorPalette: BauhausColorPalette = .default,
    size: CGSize = CGSize(width: 512, height: 512),
    scale: CGFloat = 1
  ) -> UIImage? {
    artwork.image(
      colorScheme: colorScheme,
      colorPalette: colorPalette,
      size: size,
      scale: scale
    )
  }
}

/// Time-ordered Bauhaus edit operations for read-only replay.
///
/// Replay always starts from an empty grid. The final frame is expected to match
/// the owning document's `artwork`, while the document keeps that final state as
/// the authoritative value for editing and static rendering.
public struct BauhausGridReplay: Codable, Equatable, Sendable {

  /// Mutations in the order they were authored.
  public private(set) var events: [BauhausGridReplayEvent]

  /// Time of the final authored mutation, in seconds from replay start.
  public private(set) var duration: TimeInterval

  public init(
    events: [BauhausGridReplayEvent] = [],
    duration: TimeInterval = 0
  ) {
    self.events = events.sorted { $0.time < $1.time }
    self.duration = max(duration, self.events.last?.time ?? 0)
  }

  /// Whether the replay contains no visible operations.
  public var isEmpty: Bool {
    events.isEmpty
  }

  /// Appends an authored operation at the supplied timeline position.
  public mutating func append(
    action: BauhausGridReplayAction,
    at time: TimeInterval
  ) {
    let resolvedTime = max(time, duration)
    events.append(BauhausGridReplayEvent(time: resolvedTime, action: action))
    duration = resolvedTime
  }

  /// Reconstructs the grid visible at a point on this replay timeline.
  public func artwork(at time: TimeInterval) -> BauhausGridArtwork {
    var artwork = BauhausGridArtwork.empty
    for event in events where event.time <= time {
      event.action.apply(to: &artwork)
    }
    return artwork
  }
}

/// One timestamped mutation in a Bauhaus replay.
public struct BauhausGridReplayEvent: Codable, Equatable, Sendable {

  /// Seconds from the start of the replay.
  public var time: TimeInterval

  /// The mutation applied at `time`.
  public var action: BauhausGridReplayAction

  public init(time: TimeInterval, action: BauhausGridReplayAction) {
    self.time = time
    self.action = action
  }
}

/// A discrete Bauhaus grid edit that can be replayed from an empty artwork.
public enum BauhausGridReplayAction: Codable, Equatable, Sendable {
  /// Replaces one cell with a tile, or clears it when `tile` is `nil`.
  case setTile(position: BauhausGridPosition, tile: BauhausTile?)

  /// Clears every cell.
  case clear

  fileprivate func apply(to artwork: inout BauhausGridArtwork) {
    switch self {
    case .setTile(let position, let tile):
      artwork[position] = tile
    case .clear:
      artwork = .empty
    }
  }
}

public extension BauhausGridReplay {

  /// Returns a display-only replay that places every authored event on the same
  /// beat. The persisted authored timestamps remain unchanged.
  func presentationTimeline(eventInterval: TimeInterval) -> BauhausGridReplay {
    let resolvedEventInterval = max(eventInterval, 0)
    guard events.isEmpty == false, resolvedEventInterval > 0 else {
      return self
    }

    var adjustedEvents: [BauhausGridReplayEvent] = []
    adjustedEvents.reserveCapacity(events.count)

    for (index, event) in events.enumerated() {
      adjustedEvents.append(
        BauhausGridReplayEvent(
          time: TimeInterval(index) * resolvedEventInterval,
          action: event.action
        )
      )
    }

    return BauhausGridReplay(
      events: adjustedEvents,
      duration: adjustedEvents.last?.time ?? 0
    )
  }
}

/// A 5 x 5 Bauhaus-style composition made from one optional tile per grid cell.
///
/// The value is intentionally independent of SwiftUI views and Journal
/// persistence so the capture component can emit it like the other Journal
/// capture frameworks. Hosts can encode this value directly, or rasterize it in
/// their own layer when they need a thumbnail.
public struct BauhausGridArtwork: Codable, Equatable, Sendable {

  /// Number of rows and columns in the artwork grid.
  public static let dimension = 5

  /// All legal grid positions, ordered row-major for view rendering.
  public static let positions: [BauhausGridPosition] = (0..<dimension).flatMap { row in
    (0..<dimension).map { column in
      BauhausGridPosition(row: row, column: column)
    }
  }

  /// A blank 5 x 5 artwork.
  public static let empty = BauhausGridArtwork()

  /// Optional tile values in row-major order. `nil` represents an empty cell.
  public private(set) var tiles: [BauhausTile?]

  public init() {
    tiles = Array(repeating: nil, count: Self.dimension * Self.dimension)
  }

  public init(tiles: [BauhausTile?]) {
    let expectedCount = Self.dimension * Self.dimension
    self.tiles = Array(tiles.prefix(expectedCount))
    if self.tiles.count < expectedCount {
      self.tiles += Array(repeating: nil, count: expectedCount - self.tiles.count)
    }
  }

  /// Returns or replaces the tile at a grid position. Out-of-range positions
  /// read as empty and ignore writes.
  public subscript(position: BauhausGridPosition) -> BauhausTile? {
    get {
      guard let index = index(for: position) else { return nil }
      return tiles[index]
    }
    set {
      guard let index = index(for: position) else { return }
      tiles[index] = newValue
    }
  }

  /// Whether every cell in the artwork is empty.
  public var isEmpty: Bool {
    tiles.allSatisfy { $0 == nil }
  }

  /// Rasterizes the grid artwork into a square image while keeping the stored
  /// value as vector-like tile data.
  @MainActor
  public func image(
    colorScheme: ColorScheme = .light,
    colorPalette: BauhausColorPalette = .default,
    size: CGSize = CGSize(width: 512, height: 512),
    scale: CGFloat = 1
  ) -> UIImage? {
    guard size.width > 0, size.height > 0 else { return nil }
    let renderer = ImageRenderer(
      content: BauhausGridArtworkView(artwork: self, colorPalette: colorPalette)
        .environment(\.colorScheme, colorScheme)
        .frame(width: size.width, height: size.height)
    )
    renderer.scale = max(scale, 1)
    renderer.isOpaque = true
    return renderer.uiImage
  }

  private func index(for position: BauhausGridPosition) -> Int? {
    guard position.row >= 0,
          position.row < Self.dimension,
          position.column >= 0,
          position.column < Self.dimension
    else {
      return nil
    }
    return position.row * Self.dimension + position.column
  }
}

/// Read-only SwiftUI rendering for a saved `BauhausGridArtwork`.
///
/// This builds the grid as live SwiftUI content from the editable artwork value.
public struct BauhausGridArtworkView: View {

  @Environment(\.colorScheme) private var colorScheme

  public let artwork: BauhausGridArtwork
  public let colorPalette: BauhausColorPalette

  public init(
    artwork: BauhausGridArtwork,
    colorPalette: BauhausColorPalette = .default
  ) {
    self.artwork = artwork
    self.colorPalette = colorPalette
  }

  public var body: some View {
    BauhausArtworkRasterView(
      artwork: artwork,
      colors: colorPalette.colors(for: colorScheme)
    )
      .aspectRatio(1, contentMode: .fit)
  }
}

/// Read-only SwiftUI replay for a saved `BauhausGridDocument`.
///
/// The caller owns playback state through `isPlaying`; the view only maps the
/// document's optional replay timeline to a sequence of visible grid states.
/// Documents without replay data render their final artwork statically.
public struct BauhausGridReplayView: View {

  public let document: BauhausGridDocument
  public let colorPalette: BauhausColorPalette

  @Binding private var isPlaying: Bool
  @State private var replayStart: Date?

  public init(
    document: BauhausGridDocument,
    colorPalette: BauhausColorPalette = .default,
    isPlaying: Binding<Bool>
  ) {
    self.document = document
    self.colorPalette = colorPalette
    self._isPlaying = isPlaying
  }

  public var body: some View {
    if let replay = document.replay, replay.isEmpty == false, isPlaying {
      let playbackReplay = replay.presentationTimeline(
        eventInterval: BauhausGridReplayRecipe.eventInterval
      )
      let recipe = BauhausGridReplayRecipe(replay: playbackReplay)

      TimelineView(.animation) { timeline in
        let elapsed = elapsedTime(at: timeline.date, recipe: recipe)
        BauhausGridReplayFrameView(
          replay: playbackReplay,
          videoTime: elapsed,
          recipe: recipe,
          colorPalette: colorPalette
        )
        .onChange(of: elapsed >= recipe.totalDuration) { _, finished in
          if finished {
            isPlaying = false
          }
        }
      }
      .onAppear {
        synchronizeReplayStart()
      }
      .onChange(of: isPlaying) { _, _ in
        synchronizeReplayStart()
      }
      .onChange(of: document) { _, _ in
        synchronizeReplayStart()
      }
    } else {
      BauhausGridArtworkView(
        artwork: document.artwork,
        colorPalette: colorPalette
      )
      .onAppear {
        if document.replay?.isEmpty != false {
          isPlaying = false
        }
      }
    }
  }

  private func synchronizeReplayStart() {
    replayStart = isPlaying ? Date() : nil
  }

  private func elapsedTime(
    at date: Date,
    recipe: BauhausGridReplayRecipe
  ) -> TimeInterval {
    guard let replayStart else { return 0 }
    return min(max(date.timeIntervalSince(replayStart), 0), recipe.totalDuration)
  }
}

/// One rendered Bauhaus replay frame plus per-cell appearance timing.
///
/// This is a value description of a frame, not a view. Exporters can use it to
/// draw replay videos without depending on SwiftUI's live `TimelineView`.
public struct BauhausGridReplayFrame: Equatable, Sendable {

  /// Artwork reconstructed at the current replay source time.
  public var artwork: BauhausGridArtwork

  private var appearanceSourceTimes: [BauhausGridPosition: TimeInterval]

  public init(
    replay: BauhausGridReplay,
    sourceTime: TimeInterval
  ) {
    var artwork = BauhausGridArtwork.empty
    var appearanceSourceTimes: [BauhausGridPosition: TimeInterval] = [:]

    for event in replay.events where event.time <= sourceTime {
      switch event.action {
      case .setTile(let position, let tile):
        artwork[position] = tile
        if tile == nil {
          appearanceSourceTimes[position] = nil
        } else {
          appearanceSourceTimes[position] = event.time
        }
      case .clear:
        artwork = .empty
        appearanceSourceTimes.removeAll()
      }
    }

    self.artwork = artwork
    self.appearanceSourceTimes = appearanceSourceTimes
  }

  public func appearanceProgress(
    for position: BauhausGridPosition,
    atVideoTime videoTime: TimeInterval,
    recipe: BauhausGridReplayRecipe,
    duration: TimeInterval
  ) -> CGFloat {
    guard duration > 0,
          let appearanceSourceTime = appearanceSourceTimes[position]
    else {
      return 1
    }

    let appearanceVideoTime = recipe.videoTime(atSourceTime: appearanceSourceTime)
    let normalizedProgress = (videoTime - appearanceVideoTime) / duration
    return CGFloat(min(max(normalizedProgress, 0), 1))
  }

  /// Returns the sampled appearance values for a tile at the supplied video time.
  public func appearanceValues(
    for position: BauhausGridPosition,
    atVideoTime videoTime: TimeInterval,
    recipe: BauhausGridReplayRecipe
  ) -> BauhausTileAppearanceMotion.Values {
    guard let appearanceSourceTime = appearanceSourceTimes[position] else {
      return .visible
    }

    let appearanceVideoTime = recipe.videoTime(atSourceTime: appearanceSourceTime)
    return BauhausTileAppearanceMotion.values(
      atElapsedTime: videoTime - appearanceVideoTime
    )
  }
}

/// Read-only rendering for a single Bauhaus replay timestamp.
///
/// The caller supplies `videoTime` so previews, detail replay controls, and
/// export pipelines can all render the same deterministic frame sequence.
public struct BauhausGridReplayFrameView: View {

  @Environment(\.colorScheme) private var colorScheme

  public let replay: BauhausGridReplay
  public let videoTime: TimeInterval
  public let recipe: BauhausGridReplayRecipe
  public let colorPalette: BauhausColorPalette

  public init(
    replay: BauhausGridReplay,
    videoTime: TimeInterval,
    recipe: BauhausGridReplayRecipe,
    colorPalette: BauhausColorPalette = .default
  ) {
    self.replay = replay
    self.videoTime = videoTime
    self.recipe = recipe
    self.colorPalette = colorPalette
  }

  public var body: some View {
    let replayFrame = BauhausGridReplayFrame(
      replay: replay,
      sourceTime: recipe.sourceTime(atVideoTime: videoTime)
    )

    BauhausGridReplayRasterView(
      replayFrame: replayFrame,
      videoTime: videoTime,
      recipe: recipe,
      colors: colorPalette.colors(for: colorScheme)
    )
    .aspectRatio(1, contentMode: .fit)
  }
}

/// Raster surface for an in-progress Bauhaus replay frame.
///
/// Empty cells stay stable while newly visible tile colors fade in and their
/// shapes scale through a short overshooting bounce.
private struct BauhausGridReplayRasterView: View {

  let replayFrame: BauhausGridReplayFrame
  let videoTime: TimeInterval
  let recipe: BauhausGridReplayRecipe
  let colors: BauhausResolvedColors

  private let columns = Array(
    repeating: GridItem(.flexible(minimum: 0), spacing: 2),
    count: BauhausGridArtwork.dimension
  )

  var body: some View {
    LazyVGrid(columns: columns, spacing: 2) {
      ForEach(BauhausGridArtwork.positions) { position in
        ZStack {
          Rectangle()
            .fill(colors.chrome.emptyCell)

          if let tile = replayFrame.artwork[position] {
            let appearance = replayFrame.appearanceValues(
              for: position,
              atVideoTime: videoTime,
              recipe: recipe
            )

            Rectangle()
              .fill(tile.backgroundSwatch.color(in: colors))
              .opacity(Double(appearance.opacity))

            BauhausShape(kind: tile.shape)
              .fill(tile.shapeSwatch.color(in: colors))
              .scaleEffect(appearance.scale)
              .opacity(Double(appearance.opacity))
          }
        }
        .aspectRatio(1, contentMode: .fit)
      }
    }
    .padding(8)
    .background(
      Rectangle()
        .fill(colors.chrome.paper)
    )
  }

}

/// Shared motion sampler for a tile as it appears in a Bauhaus replay.
///
/// The live SwiftUI replay and the Core Graphics video exporter both call this
/// type with an elapsed time and apply the returned values in their own render
/// surfaces. Keeping the sampling here lets the exported mp4 match the on-screen
/// replay without recording SwiftUI view frames.
public struct BauhausTileAppearanceMotion: Equatable, Sendable {

  /// Render values for one sampled appearance frame.
  public struct Values: Equatable, Sendable {

    /// Fill opacity for the tile background and shape.
    public var opacity: CGFloat

    /// Scale applied to the tile shape around its cell center.
    public var scale: CGFloat

    public init(
      opacity: CGFloat,
      scale: CGFloat
    ) {
      self.opacity = opacity
      self.scale = scale
    }

    /// Values before the tile has started appearing.
    public static let hidden = Values(opacity: 0, scale: 0)

    /// Values after the appearance motion has completed.
    public static let visible = Values(opacity: 1, scale: 1)
  }

  /// Duration of the per-tile appearance motion.
  public static let duration: TimeInterval = 0.2

  private static let shapeScaleSpring = Spring.snappy(
    duration: duration,
    extraBounce: 0.18
  )

  /// Samples the tile appearance at `elapsedTime` seconds from tile insertion.
  public static func values(atElapsedTime elapsedTime: TimeInterval) -> Values {
    guard elapsedTime > 0 else { return .hidden }
    guard elapsedTime < duration else { return .visible }

    let progress = elapsedTime / duration
    let opacity = CGFloat(UnitCurve.easeOut.value(at: progress))
    let scale = CGFloat(shapeScaleSpring.value(
      fromValue: 0.0,
      toValue: 1.0,
      initialVelocity: 0.0,
      time: elapsedTime
    ))

    return Values(
      opacity: opacity,
      scale: max(scale, 0)
    )
  }
}

/// Playback timing policy for discrete Bauhaus replay events.
///
/// Bauhaus edits are authored as discrete operations. This recipe maps the
/// authored source timeline onto the short presentation timeline used by saved
/// entry replay and share-video export.
public struct BauhausGridReplayRecipe: Equatable, Sendable {

  /// Display beat between authored operations after presentation normalization.
  public static let eventInterval: TimeInterval = 0.16

  /// Duration of the per-tile appearance bounce.
  public static let bounceDuration: TimeInterval = BauhausTileAppearanceMotion.duration

  public let sourceDuration: TimeInterval
  public let replayDuration: TimeInterval
  public let leadInDuration: TimeInterval
  public let holdDuration: TimeInterval

  public init(
    replay: BauhausGridReplay,
    leadInDuration: TimeInterval = 0.2,
    minimumReplayDuration: TimeInterval = 0.16,
    holdDuration: TimeInterval = 0.28
  ) {
    sourceDuration = max(replay.duration, replay.events.last?.time ?? 0, Self.eventInterval)
    replayDuration = max(sourceDuration, minimumReplayDuration)
    self.leadInDuration = max(leadInDuration, 0)
    self.holdDuration = max(holdDuration, 0)
  }

  public var totalDuration: TimeInterval {
    leadInDuration + replayDuration + holdDuration
  }

  public func sourceTime(atVideoTime videoTime: TimeInterval) -> TimeInterval {
    guard replayDuration > 0 else { return sourceDuration }
    guard videoTime >= leadInDuration else { return -Double.ulpOfOne }

    let visibleVideoTime = min(max(videoTime - leadInDuration, 0), replayDuration)
    let progress = visibleVideoTime / replayDuration
    return min(sourceDuration * progress, sourceDuration)
  }

  public func videoTime(atSourceTime sourceTime: TimeInterval) -> TimeInterval {
    guard sourceDuration > 0 else { return leadInDuration }

    let clampedSourceTime = min(max(sourceTime, 0), sourceDuration)
    return leadInDuration + (clampedSourceTime / sourceDuration) * replayDuration
  }

  /// Overshooting scale curve used when a tile first appears.
  public static func bounceScale(_ progress: CGFloat) -> CGFloat {
    let progress = min(max(progress, 0), 1)
    return BauhausTileAppearanceMotion.values(
      atElapsedTime: TimeInterval(progress) * BauhausTileAppearanceMotion.duration
    ).scale
  }
}

/// A stable row/column coordinate inside a `BauhausGridArtwork`.
public struct BauhausGridPosition: Codable, Equatable, Hashable, Identifiable, Sendable {

  /// Zero-based row index.
  public let row: Int

  /// Zero-based column index.
  public let column: Int

  public var id: String { "\(row)-\(column)" }

  public init(row: Int, column: Int) {
    self.row = row
    self.column = column
  }
}

/// One authored mark in the Bauhaus grid.
public struct BauhausTile: Codable, Equatable, Sendable {

  /// The geometric primitive drawn inside the cell.
  public var shape: BauhausShapeKind

  /// The color token used to fill the primitive.
  public var shapeSwatch: BauhausSwatch

  /// The color token used to fill the cell behind the primitive.
  public var backgroundSwatch: BauhausSwatch

  public init(
    shape: BauhausShapeKind,
    shapeSwatch: BauhausSwatch,
    backgroundSwatch: BauhausSwatch = .slot3
  ) {
    self.shape = shape
    self.shapeSwatch = shapeSwatch
    self.backgroundSwatch = backgroundSwatch
  }

  public init(shape: BauhausShapeKind, swatch: BauhausSwatch) {
    self.init(shape: shape, shapeSwatch: swatch)
  }

  private enum CodingKeys: String, CodingKey {
    case shape
    case shapeSwatch
    case backgroundSwatch
    case swatch
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    shape = try container.decode(BauhausShapeKind.self, forKey: .shape)
    shapeSwatch = try container.decodeIfPresent(BauhausSwatch.self, forKey: .shapeSwatch)
      ?? container.decodeIfPresent(BauhausSwatch.self, forKey: .swatch)
      ?? .slot1
    backgroundSwatch = try container.decodeIfPresent(BauhausSwatch.self, forKey: .backgroundSwatch)
      ?? .slot3
  }

  public func encode(to encoder: any Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(shape, forKey: .shape)
    try container.encode(shapeSwatch, forKey: .shapeSwatch)
    try container.encode(backgroundSwatch, forKey: .backgroundSwatch)
  }
}

/// Bauhaus-inspired primitives that fit inside one square grid cell.
public enum BauhausShapeKind: String, CaseIterable, Codable, Identifiable, Sendable {
  case square
  /// A circle that fills the cell's available square.
  case circle
  /// A circle inset from the cell edges so the surrounding cell color remains
  /// visible.
  case paddedCircle
  case semicircleTop
  case semicircleTrailing
  case semicircleBottom
  case semicircleLeading
  /// A semicircle whose flat diameter is attached to the top cell edge.
  case semicircleFlatTop
  /// A semicircle whose flat diameter is attached to the trailing cell edge.
  case semicircleFlatTrailing
  /// A semicircle whose flat diameter is attached to the bottom cell edge.
  case semicircleFlatBottom
  /// A semicircle whose flat diameter is attached to the leading cell edge.
  case semicircleFlatLeading
  case quarterCircleTopLeading
  case quarterCircleTopTrailing
  case quarterCircleBottomTrailing
  case quarterCircleBottomLeading
  /// A triangle whose longest side is attached to the top cell edge.
  case triangleFlatTop
  /// A triangle whose longest side is attached to the trailing cell edge.
  case triangleFlatTrailing
  /// A triangle whose longest side is attached to the bottom cell edge.
  case triangleFlatBottom
  /// A triangle whose longest side is attached to the leading cell edge.
  case triangleFlatLeading
  case triangleTopLeading
  case triangleTopTrailing
  case triangleBottomTrailing
  case triangleBottomLeading

  public var id: String { rawValue }
}

/// A neutral authored color slot in the Bauhaus palette.
///
/// These are content-color tokens, not concrete color names. Keeping the slots
/// color-free lets future palettes map the same saved artwork to different
/// concrete colors without making the model names misleading.
public enum BauhausSwatch: String, CaseIterable, Codable, Identifiable, Sendable {
  case slot1
  case slot2
  case slot3
  case slot4
  case slot5
  case slot6
  case slot7

  public var id: String { rawValue }

  public var color: Color {
    BauhausColorPalette.default.light.color(for: self)
  }

  public func color(in colors: BauhausResolvedColors) -> Color {
    colors.color(for: self)
  }
}

/// Light and dark appearance palettes for Bauhaus artwork rendering.
///
/// `BauhausSwatch` remains the stable authored token stored in JSON, while this
/// palette owns the concrete colors used to draw those tokens in a particular
/// appearance. Hosts can provide a different Bauhaus palette without coupling
/// the capture component to app-level theme types.
public struct BauhausColorPalette: Sendable {

  public static let `default` = BauhausColorPalette(
    light: BauhausResolvedColors(
      swatches: BauhausSwatchColors(
        slot1: Color(.displayP3, red: 0.83, green: 0.22, blue: 0.12, opacity: 1),
        slot2: Color(.displayP3, red: 0.91, green: 0.66, blue: 0.31, opacity: 1),
        slot3: Color(.displayP3, red: 0.93, green: 0.90, blue: 0.84, opacity: 1),
        slot4: Color(.displayP3, red: 0.91, green: 0.63, blue: 0.64, opacity: 1),
        slot5: Color(.displayP3, red: 0.25, green: 0.50, blue: 0.68, opacity: 1),
        slot6: Color(.displayP3, red: 0.04, green: 0.27, blue: 0.18, opacity: 1),
        slot7: Color(.displayP3, red: 0.04, green: 0.04, blue: 0.05, opacity: 1)
      ),
      chrome: BauhausCanvasChrome(
        paper: Color(.displayP3, red: 0.96, green: 0.93, blue: 0.88, opacity: 1),
        emptyCell: Color(.displayP3, red: 0.91, green: 0.87, blue: 0.80, opacity: 1),
        gridLine: .white,
        boardBorder: .black.opacity(0.08),
        tileBorder: .white.opacity(0.72),
        thumbnailShadow: .black.opacity(0.12)
      )
    ),
    dark: BauhausResolvedColors(
      swatches: BauhausSwatchColors(
        slot1: Color(.displayP3, red: 1.00, green: 0.31, blue: 0.22, opacity: 1),
        slot2: Color(.displayP3, red: 0.98, green: 0.72, blue: 0.33, opacity: 1),
        slot3: Color(.displayP3, red: 0.18, green: 0.16, blue: 0.13, opacity: 1),
        slot4: Color(.displayP3, red: 0.98, green: 0.55, blue: 0.62, opacity: 1),
        slot5: Color(.displayP3, red: 0.35, green: 0.64, blue: 0.84, opacity: 1),
        slot6: Color(.displayP3, red: 0.10, green: 0.42, blue: 0.29, opacity: 1),
        slot7: Color(.displayP3, red: 0.94, green: 0.92, blue: 0.86, opacity: 1)
      ),
      chrome: BauhausCanvasChrome(
        paper: Color(.displayP3, red: 0.09, green: 0.08, blue: 0.07, opacity: 1),
        emptyCell: Color(.displayP3, red: 0.15, green: 0.14, blue: 0.12, opacity: 1),
        gridLine: Color(.displayP3, red: 0.26, green: 0.24, blue: 0.20, opacity: 1),
        boardBorder: .white.opacity(0.10),
        tileBorder: .white.opacity(0.18),
        thumbnailShadow: .black.opacity(0.34)
      )
    )
  )

  /// Concrete colors for light appearance.
  public var light: BauhausResolvedColors

  /// Concrete colors for dark appearance.
  public var dark: BauhausResolvedColors

  public init(light: BauhausResolvedColors, dark: BauhausResolvedColors) {
    self.light = light
    self.dark = dark
  }

  /// Returns the concrete resolved colors for the active SwiftUI appearance.
  public func colors(for colorScheme: ColorScheme) -> BauhausResolvedColors {
    switch colorScheme {
    case .light:
      light
    case .dark:
      dark
    @unknown default:
      light
    }
  }
}

/// Concrete Bauhaus colors resolved for one light or dark appearance.
///
/// Splitting authored `swatches` from non-authored canvas `chrome` keeps the
/// saved artwork palette from looking like it owns every UI decoration color.
public struct BauhausResolvedColors: Sendable {

  /// Colors selected by `BauhausSwatch` values stored in artwork JSON.
  public var swatches: BauhausSwatchColors

  /// Structural colors for the Bauhaus board, grid separators, borders, and
  /// thumbnail affordances. These are rendering chrome, not authored swatches.
  public var chrome: BauhausCanvasChrome

  public init(swatches: BauhausSwatchColors, chrome: BauhausCanvasChrome) {
    self.swatches = swatches
    self.chrome = chrome
  }

  /// The fill color for a saved Bauhaus swatch token.
  public func color(for swatch: BauhausSwatch) -> Color {
    swatches.color(for: swatch)
  }
}

/// Concrete colors for the persisted `BauhausSwatch` token set.
public struct BauhausSwatchColors: Sendable {

  /// Fill color for `.slot1`.
  public var slot1: Color
  /// Fill color for `.slot2`.
  public var slot2: Color
  /// Fill color for `.slot3`.
  public var slot3: Color
  /// Fill color for `.slot4`.
  public var slot4: Color
  /// Fill color for `.slot5`.
  public var slot5: Color
  /// Fill color for `.slot6`.
  public var slot6: Color
  /// Fill color for `.slot7`.
  public var slot7: Color

  public init(
    slot1: Color,
    slot2: Color,
    slot3: Color,
    slot4: Color,
    slot5: Color,
    slot6: Color,
    slot7: Color
  ) {
    self.slot1 = slot1
    self.slot2 = slot2
    self.slot3 = slot3
    self.slot4 = slot4
    self.slot5 = slot5
    self.slot6 = slot6
    self.slot7 = slot7
  }

  /// The fill color for a saved Bauhaus swatch token.
  public func color(for swatch: BauhausSwatch) -> Color {
    switch swatch {
    case .slot1:
      slot1
    case .slot2:
      slot2
    case .slot3:
      slot3
    case .slot4:
      slot4
    case .slot5:
      slot5
    case .slot6:
      slot6
    case .slot7:
      slot7
    }
  }
}

/// Non-authored colors for the Bauhaus board and thumbnail chrome.
public struct BauhausCanvasChrome: Sendable {

  /// Outer paper color behind the 5 x 5 grid.
  public var paper: Color
  /// Fill color for cells without an authored tile.
  public var emptyCell: Color
  /// Separator color between grid cells.
  public var gridLine: Color
  /// Hairline border color around the board.
  public var boardBorder: Color
  /// Border color around shape-picker preview tiles.
  public var tileBorder: Color
  /// Drop-shadow color for small floating thumbnails.
  public var thumbnailShadow: Color

  public init(
    paper: Color,
    emptyCell: Color,
    gridLine: Color,
    boardBorder: Color,
    tileBorder: Color,
    thumbnailShadow: Color
  ) {
    self.paper = paper
    self.emptyCell = emptyCell
    self.gridLine = gridLine
    self.boardBorder = boardBorder
    self.tileBorder = tileBorder
    self.thumbnailShadow = thumbnailShadow
  }

}

/// Interactive 5 x 5 Bauhaus grid editor.
///
/// Users tap a grid cell, pick one of the prepared shapes, and the selected
/// shape, primitive color, and cell background color are applied to that cell.
/// The component reports every edit through `onChange` and can expose an
/// explicit export action when a host supplies `onExport`.
public struct BauhausGridCaptureView: View {

  @Environment(\.colorScheme) private var colorScheme

  @State private var document: BauhausGridDocument
  @State private var focusedPosition: BauhausGridPosition?
  @State private var selectedShape: BauhausShapeKind = .square
  @State private var selectedShapeSwatch: BauhausSwatch = .slot1
  @State private var selectedBackgroundSwatch: BauhausSwatch = .slot3
  @State private var isErasing = false
  @State private var undoStack: [BauhausGridEditSnapshot] = []
  @State private var redoStack: [BauhausGridEditSnapshot] = []
  @State private var selectionFeedbackTrigger = 0
  @State private var editFeedbackTrigger = 0
  @State private var completionFeedbackTrigger = 0
  @State private var replayStart: Date?

  private let colorPalette: BauhausColorPalette
  private let onChange: (@MainActor @Sendable (BauhausGridDocument) -> Void)?
  private let onExport: (@MainActor @Sendable (BauhausGridDocument) -> Void)?

  @MainActor
  public init(
    initialDocument: BauhausGridDocument = .empty,
    colorPalette: BauhausColorPalette = .default,
    onChange: (@MainActor @Sendable (BauhausGridDocument) -> Void)? = nil,
    onExport: (@MainActor @Sendable (BauhausGridDocument) -> Void)? = nil
  ) {
    let document = Self.captureReadyDocument(from: initialDocument)
    _document = State(initialValue: document)
    self.colorPalette = colorPalette
    self.onChange = onChange
    self.onExport = onExport
  }

  @MainActor
  public init(
    initialArtwork: BauhausGridArtwork = .empty,
    colorPalette: BauhausColorPalette = .default,
    onChange: (@MainActor @Sendable (BauhausGridArtwork) -> Void)? = nil,
    onExport: (@MainActor @Sendable (BauhausGridArtwork) -> Void)? = nil
  ) {
    let document = Self.captureReadyDocument(from: BauhausGridDocument(artwork: initialArtwork))
    _document = State(initialValue: document)
    self.colorPalette = colorPalette
    self.onChange = { document in
      onChange?(document.artwork)
    }
    self.onExport = { document in
      onExport?(document.artwork)
    }
  }

  public var body: some View {
    let colors = colorPalette.colors(for: colorScheme)

    ScrollView {
      VStack(spacing: 20) {
        BauhausArtworkBoard(
          artwork: document.artwork,
          selectedPosition: focusedPosition,
          colors: colors,
          onSelect: applySelectedTool
        )
        .padding(.horizontal, BauhausCaptureLayout.boardHorizontalInset)

        BauhausCaptureControls(
          selectedShape: $selectedShape,
          selectedShapeSwatch: $selectedShapeSwatch,
          selectedBackgroundSwatch: $selectedBackgroundSwatch,
          isErasing: $isErasing,
          canUndo: undoStack.isEmpty == false,
          canRedo: redoStack.isEmpty == false,
          isClearDisabled: document.artwork.isEmpty,
          isExportDisabled: document.artwork.isEmpty,
          showsExport: onExport != nil,
          colors: colors,
          onUndo: undo,
          onRedo: redo,
          onClear: clear,
          onExport: export,
          onSelectSwatch: triggerSelectionFeedback
        )
      }
      .padding(16)
      .frame(maxWidth: 560)
      .frame(maxWidth: .infinity)
    }
    .background(.background)
    .navigationTitle("Bauhaus")
    .navigationBarTitleDisplayMode(.inline)
    .sensoryFeedback(.selection, trigger: selectionFeedbackTrigger)
    .sensoryFeedback(.impact(weight: .light), trigger: editFeedbackTrigger)
    .sensoryFeedback(.success, trigger: completionFeedbackTrigger)
  }

  private func applySelectedTool(to position: BauhausGridPosition) {
    focusedPosition = position

    let nextTile: BauhausTile? = isErasing
      ? nil
      : BauhausTile(
        shape: selectedShape,
        shapeSwatch: selectedShapeSwatch,
        backgroundSwatch: selectedBackgroundSwatch
      )

    guard document.artwork[position] != nextTile else {
      triggerSelectionFeedback()
      return
    }

    apply(nextTile, at: position)
  }

  private func apply(_ tile: BauhausTile?, at position: BauhausGridPosition) {
    pushUndoSnapshot()
    withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
      document.artwork[position] = tile
      recordReplayAction(.setTile(position: position, tile: tile))
    }
    focusedPosition = position
    triggerEditFeedback()
    onChange?(document)
  }

  private func clear() {
    guard document.artwork.isEmpty == false else { return }
    pushUndoSnapshot()
    withAnimation(.spring(response: 0.32, dampingFraction: 0.9)) {
      document.artwork = .empty
      focusedPosition = nil
      if document.replay == nil {
        document.replay = BauhausGridReplay()
        replayStart = nil
      } else {
        recordReplayAction(.clear)
      }
    }
    triggerEditFeedback()
    onChange?(document)
  }

  private func undo() {
    guard let previous = undoStack.popLast() else { return }
    redoStack.append(snapshot())
    restore(previous)
  }

  private func redo() {
    guard let next = redoStack.popLast() else { return }
    undoStack.append(snapshot())
    restore(next)
  }

  private func export() {
    guard document.artwork.isEmpty == false else { return }
    triggerCompletionFeedback()
    onExport?(document)
  }

  private func recordReplayAction(_ action: BauhausGridReplayAction) {
    guard document.replay != nil else { return }
    document.replay?.append(action: action, at: replayTime())
  }

  private func replayTime() -> TimeInterval {
    let existingDuration = document.replay?.duration ?? 0
    if replayStart == nil {
      replayStart = Date().addingTimeInterval(-existingDuration)
    }
    return replayStart.map { Date().timeIntervalSince($0) } ?? existingDuration
  }

  private func triggerSelectionFeedback() {
    selectionFeedbackTrigger += 1
  }

  private func triggerEditFeedback() {
    editFeedbackTrigger += 1
  }

  private func triggerCompletionFeedback() {
    completionFeedbackTrigger += 1
  }

  private static func captureReadyDocument(
    from document: BauhausGridDocument
  ) -> BauhausGridDocument {
    guard document.replay == nil, document.artwork.isEmpty else {
      return document
    }
    return BauhausGridDocument(artwork: document.artwork, replay: BauhausGridReplay())
  }

  private func pushUndoSnapshot() {
    undoStack.append(snapshot())
    redoStack.removeAll()
  }

  private func snapshot() -> BauhausGridEditSnapshot {
    BauhausGridEditSnapshot(
      document: document,
      focusedPosition: focusedPosition,
      replayStart: replayStart
    )
  }

  private func restore(_ snapshot: BauhausGridEditSnapshot) {
    withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
      document = snapshot.document
      focusedPosition = snapshot.focusedPosition
      replayStart = snapshot.replayStart
    }
    triggerEditFeedback()
    onChange?(document)
  }
}

fileprivate enum BauhausCaptureLayout {
  static let boardHorizontalInset: CGFloat = 12
}

/// One reversible editor state for the in-session Bauhaus undo stack.
fileprivate struct BauhausGridEditSnapshot: Equatable, Sendable {

  /// The full document at the captured edit point, including replay data.
  var document: BauhausGridDocument

  /// The cell that was visually focused when this snapshot was captured.
  var focusedPosition: BauhausGridPosition?

  /// Replay timing origin used so redo keeps future authored timestamps stable.
  var replayStart: Date?
}

/// Standalone demo harness for `BauhausGridCaptureView`.
public struct BauhausGridCaptureDemoView: View {

  @State private var lastArtwork: BauhausGridArtwork?

  public init() {}

  public var body: some View {
    BauhausGridCaptureView(
      onChange: { artwork in
        lastArtwork = artwork
      },
      onExport: { artwork in
        lastArtwork = artwork
      }
    )
    .overlay(alignment: .topTrailing) {
      if let lastArtwork, lastArtwork.isEmpty == false {
        BauhausArtworkThumbnail(artwork: lastArtwork)
          .frame(width: 76, height: 76)
          .padding()
      }
    }
  }
}

// MARK: - Board

fileprivate struct BauhausArtworkBoard: View {

  let artwork: BauhausGridArtwork
  let selectedPosition: BauhausGridPosition?
  let colors: BauhausResolvedColors
  let onSelect: @MainActor @Sendable (BauhausGridPosition) -> Void

  private let columns = Array(
    repeating: GridItem(.flexible(minimum: 0), spacing: 2),
    count: BauhausGridArtwork.dimension
  )

  var body: some View {
    VStack(spacing: 0) {
      LazyVGrid(columns: columns, spacing: 2) {
        ForEach(BauhausGridArtwork.positions) { position in
          BauhausGridCellButton(
            tile: artwork[position],
            isSelected: position == selectedPosition,
            colors: colors,
            onSelect: {
              onSelect(position)
            }
          )
        }
      }
      .padding(2)
      .background(colors.chrome.gridLine)
      .aspectRatio(1, contentMode: .fit)
      .overlay {
        Rectangle()
          .strokeBorder(colors.chrome.gridLine, lineWidth: 2)
      }
    }
    .padding(12)
    .background {
      Rectangle()
        .fill(colors.chrome.paper)
    }
    .overlay {
      Rectangle()
        .strokeBorder(colors.chrome.boardBorder, lineWidth: 1)
    }
  }
}

fileprivate struct BauhausGridCellButton: View {

  let tile: BauhausTile?
  let isSelected: Bool
  let colors: BauhausResolvedColors
  let onSelect: @MainActor @Sendable () -> Void

  var body: some View {
    Button(action: onSelect) {
      ZStack {
        Rectangle()
          .fill(tile?.backgroundSwatch.color(in: colors) ?? colors.chrome.emptyCell)

        if let tile {
          BauhausShape(kind: tile.shape)
            .fill(tile.shapeSwatch.color(in: colors))
            .transition(.scale(scale: 0.82).combined(with: .opacity))
        }

        if isSelected {
          Rectangle()
            .strokeBorder(.tint, lineWidth: 3)
        }
      }
      .aspectRatio(1, contentMode: .fit)
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
    .accessibilityLabel(tile == nil ? "Empty cell" : "Bauhaus shape cell")
  }
}

// MARK: - Picker

fileprivate struct BauhausShapeLibrary: View {

  @Binding var selectedShape: BauhausShapeKind

  let selectedShapeSwatch: BauhausSwatch
  let selectedBackgroundSwatch: BauhausSwatch
  let colors: BauhausResolvedColors
  let onSelect: @MainActor @Sendable () -> Void

  var body: some View {
    VStack(alignment: .leading, spacing: 18) {
      BauhausShapePickerSection(
        title: "Basic",
        shapes: BauhausShapeLibraryOrder.basic,
        selectedShape: $selectedShape,
        selectedShapeSwatch: selectedShapeSwatch,
        selectedBackgroundSwatch: selectedBackgroundSwatch,
        colors: colors,
        onSelect: onSelect
      )
      BauhausShapePickerSection(
        title: "Triangle Edge",
        shapes: BauhausShapeLibraryOrder.edgeTriangles,
        selectedShape: $selectedShape,
        selectedShapeSwatch: selectedShapeSwatch,
        selectedBackgroundSwatch: selectedBackgroundSwatch,
        colors: colors,
        onSelect: onSelect
      )
      BauhausShapePickerSection(
        title: "Triangle Corner",
        shapes: BauhausShapeLibraryOrder.cornerTriangles,
        selectedShape: $selectedShape,
        selectedShapeSwatch: selectedShapeSwatch,
        selectedBackgroundSwatch: selectedBackgroundSwatch,
        colors: colors,
        onSelect: onSelect
      )
      BauhausShapePickerSection(
        title: "Semicircle Arc",
        shapes: BauhausShapeLibraryOrder.arcSemicircles,
        selectedShape: $selectedShape,
        selectedShapeSwatch: selectedShapeSwatch,
        selectedBackgroundSwatch: selectedBackgroundSwatch,
        colors: colors,
        onSelect: onSelect
      )
      BauhausShapePickerSection(
        title: "Semicircle Flat",
        shapes: BauhausShapeLibraryOrder.flatSemicircles,
        selectedShape: $selectedShape,
        selectedShapeSwatch: selectedShapeSwatch,
        selectedBackgroundSwatch: selectedBackgroundSwatch,
        colors: colors,
        onSelect: onSelect
      )
      BauhausShapePickerSection(
        title: "Quarter Circle",
        shapes: BauhausShapeLibraryOrder.quarterCircles,
        selectedShape: $selectedShape,
        selectedShapeSwatch: selectedShapeSwatch,
        selectedBackgroundSwatch: selectedBackgroundSwatch,
        colors: colors,
        onSelect: onSelect
      )
    }
    .frame(maxWidth: BauhausShapePickerMetrics.libraryWidth)
    .frame(maxWidth: .infinity)
  }
}

fileprivate struct BauhausShapePickerSection: View {

  let title: LocalizedStringKey
  let shapes: [BauhausShapeKind]
  @Binding var selectedShape: BauhausShapeKind
  let selectedShapeSwatch: BauhausSwatch
  let selectedBackgroundSwatch: BauhausSwatch
  let colors: BauhausResolvedColors
  let onSelect: @MainActor @Sendable () -> Void

  private static let columns = Array(
    repeating: GridItem(
      .fixed(BauhausShapePickerMetrics.tileSide),
      spacing: BauhausShapePickerMetrics.columnSpacing
    ),
    count: 4
  )

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title)
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)

      LazyVGrid(columns: Self.columns, alignment: .leading, spacing: BauhausShapePickerMetrics.rowSpacing) {
        ForEach(shapes) { shape in
          let tile = BauhausTile(
            shape: shape,
            shapeSwatch: selectedShapeSwatch,
            backgroundSwatch: selectedBackgroundSwatch
          )

          Button {
            guard selectedShape != shape else { return }
            selectedShape = shape
            onSelect()
          } label: {
            BauhausShapeLibraryTile(
              tile: tile,
              isSelected: selectedShape == shape,
              colors: colors
            )
          }
          .buttonStyle(.plain)
          .accessibilityLabel(shape.accessibilityLabel)
        }
      }
    }
  }
}

fileprivate enum BauhausShapePickerMetrics {
  static let tileSide: CGFloat = 44
  static let columnSpacing: CGFloat = 10
  static let rowSpacing: CGFloat = 10
  static let libraryWidth = tileSide * 4 + columnSpacing * 3
}

/// Fixed picker ordering for quickly comparing shape variants.
///
/// Directional shapes are grouped by family and kept in spatial order. The
/// picker section uses four columns, so each family can stay on a single row
/// instead of wrapping differently across device widths.
fileprivate enum BauhausShapeLibraryOrder {
  static let basic: [BauhausShapeKind] = [
    .square,
    .circle,
    .paddedCircle,
  ]

  static let arcSemicircles: [BauhausShapeKind] = [
    .semicircleTop,
    .semicircleTrailing,
    .semicircleBottom,
    .semicircleLeading,
  ]

  static let flatSemicircles: [BauhausShapeKind] = [
    .semicircleFlatTop,
    .semicircleFlatTrailing,
    .semicircleFlatBottom,
    .semicircleFlatLeading,
  ]

  static let quarterCircles: [BauhausShapeKind] = [
    .quarterCircleTopLeading,
    .quarterCircleTopTrailing,
    .quarterCircleBottomTrailing,
    .quarterCircleBottomLeading,
  ]

  static let edgeTriangles: [BauhausShapeKind] = [
    .triangleFlatTop,
    .triangleFlatTrailing,
    .triangleFlatBottom,
    .triangleFlatLeading,
  ]

  static let cornerTriangles: [BauhausShapeKind] = [
    .triangleTopLeading,
    .triangleTopTrailing,
    .triangleBottomTrailing,
    .triangleBottomLeading,
  ]
}

fileprivate extension BauhausShapeKind {

  var nextBrushVariant: BauhausShapeKind? {
    guard let cycleGroup,
          let currentIndex = cycleGroup.firstIndex(of: self)
    else {
      return nil
    }

    let nextIndex = cycleGroup.index(after: currentIndex)
    return cycleGroup[nextIndex == cycleGroup.endIndex ? cycleGroup.startIndex : nextIndex]
  }

  private var cycleGroup: [BauhausShapeKind]? {
    switch self {
    case .square, .circle, .paddedCircle:
      BauhausShapeLibraryOrder.basic
    case .semicircleTop, .semicircleTrailing, .semicircleBottom, .semicircleLeading:
      BauhausShapeLibraryOrder.arcSemicircles
    case .semicircleFlatTop, .semicircleFlatTrailing, .semicircleFlatBottom, .semicircleFlatLeading:
      BauhausShapeLibraryOrder.flatSemicircles
    case .quarterCircleTopLeading, .quarterCircleTopTrailing, .quarterCircleBottomTrailing, .quarterCircleBottomLeading:
      BauhausShapeLibraryOrder.quarterCircles
    case .triangleFlatTop, .triangleFlatTrailing, .triangleFlatBottom, .triangleFlatLeading:
      BauhausShapeLibraryOrder.edgeTriangles
    case .triangleTopLeading, .triangleTopTrailing, .triangleBottomTrailing, .triangleBottomLeading:
      BauhausShapeLibraryOrder.cornerTriangles
    }
  }
}

fileprivate struct BauhausSwatchStrip: View {

  var title: LocalizedStringKey?
  @Binding var selectedSwatch: BauhausSwatch
  let colors: BauhausResolvedColors
  var dotSize: CGFloat = 28
  var onSelect: @MainActor @Sendable () -> Void = {}

  var body: some View {
    HStack(spacing: 8) {
      if let title {
        Text(title)
          .font(.caption.weight(.semibold))
          .foregroundStyle(.secondary)
          .frame(width: 76, alignment: .leading)
      }

      ForEach(BauhausSwatch.allCases) { swatch in
        Button {
          guard selectedSwatch != swatch else { return }
          selectedSwatch = swatch
          onSelect()
        } label: {
          Circle()
            .fill(swatch.color(in: colors))
            .frame(width: dotSize, height: dotSize)
            .overlay {
              Circle()
                .strokeBorder(.primary.opacity(swatch == selectedSwatch ? 0.64 : 0.14), lineWidth: 2)
            }
            .overlay {
              if swatch == selectedSwatch {
                Circle()
                  .strokeBorder(.background, lineWidth: 3)
                  .padding(4)
              }
            }
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Select color")
      }
    }
    .frame(maxWidth: .infinity, alignment: .center)
  }
}

fileprivate struct BauhausShapeLibraryTile: View {

  let tile: BauhausTile
  let isSelected: Bool
  let colors: BauhausResolvedColors

  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 8)
        .fill(tile.backgroundSwatch.color(in: colors))

      BauhausShape(kind: tile.shape)
        .fill(tile.shapeSwatch.color(in: colors))
        .padding(8)
    }
    .frame(width: BauhausShapePickerMetrics.tileSide, height: BauhausShapePickerMetrics.tileSide)
    .overlay {
      RoundedRectangle(cornerRadius: 8)
        .strokeBorder(colors.chrome.tileBorder, lineWidth: 1)
    }
    .overlay {
      RoundedRectangle(cornerRadius: 8)
        .strokeBorder(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary.opacity(0.12)), lineWidth: isSelected ? 2 : 1)
    }
  }
}

fileprivate struct BauhausCaptureControls: View {

  @Binding var selectedShape: BauhausShapeKind
  @Binding var selectedShapeSwatch: BauhausSwatch
  @Binding var selectedBackgroundSwatch: BauhausSwatch
  @Binding var isErasing: Bool

  let canUndo: Bool
  let canRedo: Bool
  let isClearDisabled: Bool
  let isExportDisabled: Bool
  let showsExport: Bool
  let colors: BauhausResolvedColors
  let onUndo: @MainActor @Sendable () -> Void
  let onRedo: @MainActor @Sendable () -> Void
  let onClear: @MainActor @Sendable () -> Void
  let onExport: @MainActor @Sendable () -> Void
  let onSelectSwatch: @MainActor @Sendable () -> Void

  private var selectedTile: BauhausTile {
    BauhausTile(
      shape: selectedShape,
      shapeSwatch: selectedShapeSwatch,
      backgroundSwatch: selectedBackgroundSwatch
    )
  }

  private var canCycleBrush: Bool {
    isErasing == false && selectedShape.nextBrushVariant != nil
  }

  var body: some View {
    VStack(spacing: 14) {
      HStack(spacing: 12) {
        BauhausCurrentToolPreview(
          tile: selectedTile,
          isErasing: isErasing,
          showsCycleCue: canCycleBrush,
          colors: colors
        )
        .contentShape(Rectangle())
        .onTapGesture(perform: cycleBrush)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(
          isErasing ? "Current eraser" : canCycleBrush ? "Next brush" : "Current brush"
        )
        .accessibilityAddTraits(.isButton)

        Spacer(minLength: 0)
      }

      HStack(spacing: 8) {
        Button(action: onUndo) {
          Image(systemName: "arrow.uturn.backward")
        }
        .disabled(canUndo == false)
        .accessibilityLabel("Undo")

        Button(action: onRedo) {
          Image(systemName: "arrow.uturn.forward")
        }
        .disabled(canRedo == false)
        .accessibilityLabel("Redo")

        Spacer(minLength: 0)

        Button {
          isErasing.toggle()
          onSelectSwatch()
        } label: {
          Image(systemName: isErasing ? "eraser.fill" : "eraser")
        }
        .accessibilityLabel(isErasing ? "Use brush" : "Erase cells")

        if showsExport {
          Button(action: onExport) {
            Image(systemName: "checkmark")
          }
          .disabled(isExportDisabled)
          .accessibilityLabel("Finish artwork")
        }

        Button(role: .destructive, action: onClear) {
          Image(systemName: "trash")
        }
        .disabled(isClearDisabled)
        .accessibilityLabel("Clear artwork")
      }

      VStack(spacing: 10) {
        BauhausSwatchStrip(
          title: "Shape",
          selectedSwatch: $selectedShapeSwatch,
          colors: colors,
          dotSize: 26,
          onSelect: selectPaintTool
        )
        BauhausSwatchStrip(
          title: "Background",
          selectedSwatch: $selectedBackgroundSwatch,
          colors: colors,
          dotSize: 26,
          onSelect: selectPaintTool
        )
      }

      BauhausShapeLibrary(
        selectedShape: $selectedShape,
        selectedShapeSwatch: selectedShapeSwatch,
        selectedBackgroundSwatch: selectedBackgroundSwatch,
        colors: colors,
        onSelect: selectPaintTool
      )
    }
    .padding(14)
    .background {
      RoundedRectangle(cornerRadius: 8, style: .continuous)
        .fill(colors.chrome.paper)
    }
    .buttonStyle(.bordered)
    .controlSize(.regular)
  }

  private func selectPaintTool() {
    isErasing = false
    onSelectSwatch()
  }

  private func cycleBrush() {
    guard isErasing == false,
          let nextShape = selectedShape.nextBrushVariant
    else {
      onSelectSwatch()
      return
    }

    selectedShape = nextShape
    onSelectSwatch()
  }
}

fileprivate struct BauhausCurrentToolPreview: View {

  let tile: BauhausTile
  let isErasing: Bool
  let showsCycleCue: Bool
  let colors: BauhausResolvedColors

  var body: some View {
    HStack(spacing: 10) {
      ZStack {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .fill(tile.backgroundSwatch.color(in: colors))

        if isErasing {
          Image(systemName: "eraser.fill")
            .font(.title3.weight(.semibold))
            .foregroundStyle(.secondary)
        } else {
          BauhausShape(kind: tile.shape)
            .fill(tile.shapeSwatch.color(in: colors))
            .padding(10)
        }
      }
      .frame(width: 52, height: 52)
      .overlay(alignment: .bottomTrailing) {
        if showsCycleCue {
          Image(systemName: "chevron.forward")
            .font(.caption2.weight(.bold))
            .foregroundStyle(.secondary)
            .padding(4)
            .background {
              Circle()
                .fill(.background.opacity(0.92))
            }
            .offset(x: 4, y: 4)
        }
      }
      .overlay {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
          .strokeBorder(colors.chrome.tileBorder, lineWidth: 1)
      }

      Text(isErasing ? "Erase" : "Brush")
        .font(.headline.weight(.semibold))
        .frame(minWidth: 64, alignment: .leading)
    }
  }
}

// MARK: - Rendering

fileprivate struct BauhausArtworkThumbnail: View {

  @Environment(\.colorScheme) private var colorScheme

  let artwork: BauhausGridArtwork
  var colorPalette: BauhausColorPalette = .default

  private let columns = Array(
    repeating: GridItem(.flexible(minimum: 0), spacing: 1),
    count: BauhausGridArtwork.dimension
  )

  var body: some View {
    let colors = colorPalette.colors(for: colorScheme)

    LazyVGrid(columns: columns, spacing: 1) {
      ForEach(BauhausGridArtwork.positions) { position in
        ZStack {
          Rectangle()
            .fill(artwork[position]?.backgroundSwatch.color(in: colors) ?? colors.chrome.emptyCell)

          if let tile = artwork[position] {
            BauhausShape(kind: tile.shape)
              .fill(tile.shapeSwatch.color(in: colors))
          }
        }
        .aspectRatio(1, contentMode: .fit)
      }
    }
    .padding(2)
    .background(colors.chrome.gridLine)
    .overlay {
      Rectangle()
        .strokeBorder(colors.chrome.gridLine, lineWidth: 2)
    }
    .shadow(color: colors.chrome.thumbnailShadow, radius: 10, x: 0, y: 6)
  }
}

fileprivate struct BauhausArtworkRasterView: View {

  let artwork: BauhausGridArtwork
  let colors: BauhausResolvedColors

  private let columns = Array(
    repeating: GridItem(.flexible(minimum: 0), spacing: 2),
    count: BauhausGridArtwork.dimension
  )

  var body: some View {
    LazyVGrid(columns: columns, spacing: 2) {
      ForEach(BauhausGridArtwork.positions) { position in
        ZStack {
          Rectangle()
            .fill(artwork[position]?.backgroundSwatch.color(in: colors) ?? colors.chrome.emptyCell)

          if let tile = artwork[position] {
            BauhausShape(kind: tile.shape)
              .fill(tile.shapeSwatch.color(in: colors))
          }
        }
        .aspectRatio(1, contentMode: .fit)
      }
    }
    .padding(8)
    .background(
      Rectangle()
        .fill(colors.chrome.paper)
    )
  }
}

fileprivate struct BauhausShape: Shape {

  let kind: BauhausShapeKind

  func path(in rect: CGRect) -> Path {
    kind.path(in: rect)
  }
}

public extension BauhausShapeKind {

  private static let paddedCircleInsetRatio: CGFloat = 0.25

  fileprivate var accessibilityLabel: Text {
    switch self {
    case .square:
      Text("Square")
    case .circle:
      Text("Filled circle")
    case .paddedCircle:
      Text("Padded circle")
    case .semicircleTop:
      Text("Top arc semicircle")
    case .semicircleTrailing:
      Text("Trailing arc semicircle")
    case .semicircleBottom:
      Text("Bottom arc semicircle")
    case .semicircleLeading:
      Text("Leading arc semicircle")
    case .semicircleFlatTop:
      Text("Top flat semicircle")
    case .semicircleFlatTrailing:
      Text("Trailing flat semicircle")
    case .semicircleFlatBottom:
      Text("Bottom flat semicircle")
    case .semicircleFlatLeading:
      Text("Leading flat semicircle")
    case .quarterCircleTopLeading:
      Text("Top-leading quarter circle")
    case .quarterCircleTopTrailing:
      Text("Top-trailing quarter circle")
    case .quarterCircleBottomTrailing:
      Text("Bottom-trailing quarter circle")
    case .quarterCircleBottomLeading:
      Text("Bottom-leading quarter circle")
    case .triangleFlatTop:
      Text("Top-edge triangle")
    case .triangleFlatTrailing:
      Text("Trailing-edge triangle")
    case .triangleFlatBottom:
      Text("Bottom-edge triangle")
    case .triangleFlatLeading:
      Text("Leading-edge triangle")
    case .triangleTopLeading:
      Text("Top-leading triangle")
    case .triangleTopTrailing:
      Text("Top-trailing triangle")
    case .triangleBottomTrailing:
      Text("Bottom-trailing triangle")
    case .triangleBottomLeading:
      Text("Bottom-leading triangle")
    }
  }

  /// Returns the vector path for this primitive inside `rect`.
  ///
  /// The shape definitions are shared by the SwiftUI renderer and video export
  /// code so persisted Bauhaus artwork keeps one geometry contract.
  func path(in rect: CGRect) -> Path {
    switch self {
    case .square:
      return Path(rect)
    case .circle:
      return Path(ellipseIn: rect)
    case .paddedCircle:
      return paddedCirclePath(in: rect)
    case .semicircleTop:
      return semicirclePath(in: rect, edge: .top)
    case .semicircleTrailing:
      return semicirclePath(in: rect, edge: .trailing)
    case .semicircleBottom:
      return semicirclePath(in: rect, edge: .bottom)
    case .semicircleLeading:
      return semicirclePath(in: rect, edge: .leading)
    case .semicircleFlatTop:
      return flatSemicirclePath(in: rect, edge: .top)
    case .semicircleFlatTrailing:
      return flatSemicirclePath(in: rect, edge: .trailing)
    case .semicircleFlatBottom:
      return flatSemicirclePath(in: rect, edge: .bottom)
    case .semicircleFlatLeading:
      return flatSemicirclePath(in: rect, edge: .leading)
    case .quarterCircleTopLeading:
      return quarterCirclePath(in: rect, corner: .topLeading)
    case .quarterCircleTopTrailing:
      return quarterCirclePath(in: rect, corner: .topTrailing)
    case .quarterCircleBottomTrailing:
      return quarterCirclePath(in: rect, corner: .bottomTrailing)
    case .quarterCircleBottomLeading:
      return quarterCirclePath(in: rect, corner: .bottomLeading)
    case .triangleFlatTop:
      return edgeTrianglePath(in: rect, edge: .top)
    case .triangleFlatTrailing:
      return edgeTrianglePath(in: rect, edge: .trailing)
    case .triangleFlatBottom:
      return edgeTrianglePath(in: rect, edge: .bottom)
    case .triangleFlatLeading:
      return edgeTrianglePath(in: rect, edge: .leading)
    case .triangleTopLeading:
      return trianglePath(in: rect, corner: .topLeading)
    case .triangleTopTrailing:
      return trianglePath(in: rect, corner: .topTrailing)
    case .triangleBottomTrailing:
      return trianglePath(in: rect, corner: .bottomTrailing)
    case .triangleBottomLeading:
      return trianglePath(in: rect, corner: .bottomLeading)
    }
  }

  private func paddedCirclePath(in rect: CGRect) -> Path {
    let inset = min(rect.width, rect.height) * Self.paddedCircleInsetRatio
    return Path(ellipseIn: rect.insetBy(dx: inset, dy: inset))
  }

  private enum Edge {
    case top
    case trailing
    case bottom
    case leading
  }

  private enum Corner {
    case topLeading
    case topTrailing
    case bottomTrailing
    case bottomLeading
  }

  private func semicirclePath(in rect: CGRect, edge: Edge) -> Path {
    let radius = min(rect.width, rect.height) / 2
    var path = Path()

    switch edge {
    case .top:
      path.move(to: CGPoint(x: rect.minX, y: rect.midY))
      path.addArc(center: CGPoint(x: rect.midX, y: rect.midY), radius: radius, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
      path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
    case .trailing:
      path.move(to: CGPoint(x: rect.midX, y: rect.minY))
      path.addArc(center: CGPoint(x: rect.midX, y: rect.midY), radius: radius, startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: false)
      path.addLine(to: CGPoint(x: rect.midX, y: rect.minY))
    case .bottom:
      path.move(to: CGPoint(x: rect.maxX, y: rect.midY))
      path.addArc(center: CGPoint(x: rect.midX, y: rect.midY), radius: radius, startAngle: .degrees(0), endAngle: .degrees(180), clockwise: false)
      path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
    case .leading:
      path.move(to: CGPoint(x: rect.midX, y: rect.maxY))
      path.addArc(center: CGPoint(x: rect.midX, y: rect.midY), radius: radius, startAngle: .degrees(90), endAngle: .degrees(270), clockwise: false)
      path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
    }

    path.closeSubpath()
    return path
  }

  private func flatSemicirclePath(in rect: CGRect, edge: Edge) -> Path {
    let radius = min(rect.width, rect.height) / 2
    var path = Path()

    switch edge {
    case .top:
      path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
      path.addArc(center: CGPoint(x: rect.midX, y: rect.minY), radius: radius, startAngle: .degrees(0), endAngle: .degrees(180), clockwise: false)
      path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
    case .trailing:
      path.move(to: CGPoint(x: rect.maxX, y: rect.maxY))
      path.addArc(center: CGPoint(x: rect.maxX, y: rect.midY), radius: radius, startAngle: .degrees(90), endAngle: .degrees(270), clockwise: false)
      path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
    case .bottom:
      path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
      path.addArc(center: CGPoint(x: rect.midX, y: rect.maxY), radius: radius, startAngle: .degrees(180), endAngle: .degrees(0), clockwise: false)
      path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
    case .leading:
      path.move(to: CGPoint(x: rect.minX, y: rect.minY))
      path.addArc(center: CGPoint(x: rect.minX, y: rect.midY), radius: radius, startAngle: .degrees(-90), endAngle: .degrees(90), clockwise: false)
      path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
    }

    path.closeSubpath()
    return path
  }

  private func quarterCirclePath(in rect: CGRect, corner: Corner) -> Path {
    let radius = min(rect.width, rect.height)
    var path = Path()

    switch corner {
    case .topLeading:
      path.move(to: CGPoint(x: rect.minX, y: rect.minY))
      path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
      path.addArc(center: CGPoint(x: rect.minX, y: rect.minY), radius: radius, startAngle: .degrees(0), endAngle: .degrees(90), clockwise: false)
    case .topTrailing:
      path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
      path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
      path.addArc(center: CGPoint(x: rect.maxX, y: rect.minY), radius: radius, startAngle: .degrees(90), endAngle: .degrees(180), clockwise: false)
    case .bottomTrailing:
      path.move(to: CGPoint(x: rect.maxX, y: rect.maxY))
      path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
      path.addArc(center: CGPoint(x: rect.maxX, y: rect.maxY), radius: radius, startAngle: .degrees(180), endAngle: .degrees(270), clockwise: false)
    case .bottomLeading:
      path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
      path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
      path.addArc(center: CGPoint(x: rect.minX, y: rect.maxY), radius: radius, startAngle: .degrees(270), endAngle: .degrees(360), clockwise: false)
    }

    path.closeSubpath()
    return path
  }

  private func edgeTrianglePath(in rect: CGRect, edge: Edge) -> Path {
    var path = Path()

    switch edge {
    case .top:
      path.move(to: CGPoint(x: rect.minX, y: rect.minY))
      path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
      path.addLine(to: CGPoint(x: rect.midX, y: rect.midY))
    case .trailing:
      path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
      path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
      path.addLine(to: CGPoint(x: rect.midX, y: rect.midY))
    case .bottom:
      path.move(to: CGPoint(x: rect.maxX, y: rect.maxY))
      path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
      path.addLine(to: CGPoint(x: rect.midX, y: rect.midY))
    case .leading:
      path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
      path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
      path.addLine(to: CGPoint(x: rect.midX, y: rect.midY))
    }

    path.closeSubpath()
    return path
  }

  private func trianglePath(in rect: CGRect, corner: Corner) -> Path {
    var path = Path()

    switch corner {
    case .topLeading:
      path.move(to: CGPoint(x: rect.minX, y: rect.minY))
      path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
      path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
    case .topTrailing:
      path.move(to: CGPoint(x: rect.maxX, y: rect.minY))
      path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
      path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
    case .bottomTrailing:
      path.move(to: CGPoint(x: rect.maxX, y: rect.maxY))
      path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
      path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY))
    case .bottomLeading:
      path.move(to: CGPoint(x: rect.minX, y: rect.maxY))
      path.addLine(to: CGPoint(x: rect.minX, y: rect.minY))
      path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
    }

    path.closeSubpath()
    return path
  }
}

#Preview("Bauhaus Capture") {
  NavigationStack {
    BauhausGridCaptureDemoView()
  }
}

#Preview("Bauhaus Board") {
  BauhausPreviewCanvas {
    BauhausArtworkBoard(
      artwork: BauhausPreviewFixtures.allShapeArtwork,
      selectedPosition: BauhausGridPosition(row: 0, column: 1),
      colors: BauhausColorPalette.default.colors(for: .light),
      onSelect: { _ in }
    )
    .frame(width: 320)
  }
}

#Preview("Bauhaus Shape Parts") {
  BauhausShapePartsPreview()
}

#Preview("Bauhaus Shape Library") {
  BauhausShapeLibraryPreview()
}

#Preview("Bauhaus Controls") {
  BauhausCaptureControlsPreview()
}

#Preview("Bauhaus Replay") {
  BauhausReplayPreview()
}

// MARK: - Previews

fileprivate enum BauhausPreviewFixtures {

  static let primaryShapeSwatch: BauhausSwatch = .slot1
  static let primaryBackgroundSwatch: BauhausSwatch = .slot3

  static var allShapeArtwork: BauhausGridArtwork {
    let tiles: [BauhausTile?] = BauhausShapeKind.allCases.enumerated().map {
      index, shape in
      let pair = swatchPairs[index % swatchPairs.count]
      return BauhausTile(
        shape: shape,
        shapeSwatch: pair.shape,
        backgroundSwatch: pair.background
      )
    }

    return BauhausGridArtwork(tiles: tiles)
  }

  static var replayDocument: BauhausGridDocument {
    let placements: [(BauhausGridPosition, BauhausShapeKind)] = [
      (BauhausGridPosition(row: 0, column: 0), .square),
      (BauhausGridPosition(row: 0, column: 1), .circle),
      (BauhausGridPosition(row: 0, column: 2), .paddedCircle),
      (BauhausGridPosition(row: 1, column: 2), .semicircleTop),
      (BauhausGridPosition(row: 2, column: 2), .quarterCircleBottomTrailing),
      (BauhausGridPosition(row: 3, column: 3), .triangleTopLeading),
      (BauhausGridPosition(row: 4, column: 4), .semicircleFlatLeading),
    ]

    var artwork = BauhausGridArtwork()
    var replay = BauhausGridReplay()

    for (index, placement) in placements.enumerated() {
      let pair = swatchPairs[index % swatchPairs.count]
      let tile = BauhausTile(
        shape: placement.1,
        shapeSwatch: pair.shape,
        backgroundSwatch: pair.background
      )
      artwork[placement.0] = tile
      replay.append(
        action: .setTile(position: placement.0, tile: tile),
        at: Double(index) * 0.35
      )
    }

    return BauhausGridDocument(artwork: artwork, replay: replay)
  }

  private static let swatchPairs: [
    (shape: BauhausSwatch, background: BauhausSwatch)
  ] = [
    (.slot1, .slot3),
    (.slot5, .slot2),
    (.slot7, .slot4),
    (.slot2, .slot6),
  ]
}

fileprivate struct BauhausPreviewCanvas<Content: View>: View {

  private let content: Content

  init(@ViewBuilder content: () -> Content) {
    self.content = content()
  }

  var body: some View {
    ScrollView {
      content
        .padding(20)
        .frame(maxWidth: 560)
        .frame(maxWidth: .infinity)
    }
    .background(.background)
  }
}

fileprivate struct BauhausShapePartsPreview: View {

  @Environment(\.colorScheme) private var colorScheme

  var body: some View {
    let colors = BauhausColorPalette.default.colors(for: colorScheme)

    BauhausPreviewCanvas {
      VStack(alignment: .leading, spacing: 18) {
        BauhausShapePartPreviewSection(
          title: "Basic",
          shapes: BauhausShapeLibraryOrder.basic,
          colors: colors
        )
        BauhausShapePartPreviewSection(
          title: "Triangle Edge",
          shapes: BauhausShapeLibraryOrder.edgeTriangles,
          colors: colors
        )
        BauhausShapePartPreviewSection(
          title: "Triangle Corner",
          shapes: BauhausShapeLibraryOrder.cornerTriangles,
          colors: colors
        )
        BauhausShapePartPreviewSection(
          title: "Semicircle Arc",
          shapes: BauhausShapeLibraryOrder.arcSemicircles,
          colors: colors
        )
        BauhausShapePartPreviewSection(
          title: "Semicircle Flat",
          shapes: BauhausShapeLibraryOrder.flatSemicircles,
          colors: colors
        )
        BauhausShapePartPreviewSection(
          title: "Quarter Circle",
          shapes: BauhausShapeLibraryOrder.quarterCircles,
          colors: colors
        )
      }
    }
  }
}

fileprivate struct BauhausShapePartPreviewSection: View {

  let title: LocalizedStringKey
  let shapes: [BauhausShapeKind]
  let colors: BauhausResolvedColors

  private static let columns = Array(
    repeating: GridItem(.fixed(56), spacing: 12),
    count: 4
  )

  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Text(title)
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)

      LazyVGrid(columns: Self.columns, alignment: .leading, spacing: 12) {
        ForEach(shapes) { shape in
          BauhausShapePartPreviewTile(
            shape: shape,
            colors: colors
          )
        }
      }
    }
  }
}

fileprivate struct BauhausShapePartPreviewTile: View {

  let shape: BauhausShapeKind
  let colors: BauhausResolvedColors

  var body: some View {
    ZStack {
      Rectangle()
        .fill(BauhausPreviewFixtures.primaryBackgroundSwatch.color(in: colors))

      BauhausShape(kind: shape)
        .fill(BauhausPreviewFixtures.primaryShapeSwatch.color(in: colors))
    }
    .frame(width: 56, height: 56)
    .overlay {
      Rectangle()
        .strokeBorder(colors.chrome.gridLine, lineWidth: 1)
    }
    .accessibilityLabel(shape.accessibilityLabel)
  }
}

fileprivate struct BauhausShapeLibraryPreview: View {

  @Environment(\.colorScheme) private var colorScheme
  @State private var selectedShape = BauhausShapeKind.circle
  @State private var selectedShapeSwatch = BauhausPreviewFixtures.primaryShapeSwatch
  @State private var selectedBackgroundSwatch = BauhausPreviewFixtures.primaryBackgroundSwatch

  var body: some View {
    let colors = BauhausColorPalette.default.colors(for: colorScheme)

    BauhausPreviewCanvas {
      BauhausShapeLibrary(
        selectedShape: $selectedShape,
        selectedShapeSwatch: selectedShapeSwatch,
        selectedBackgroundSwatch: selectedBackgroundSwatch,
        colors: colors,
        onSelect: {}
      )
    }
  }
}

fileprivate struct BauhausCaptureControlsPreview: View {

  @Environment(\.colorScheme) private var colorScheme
  @State private var selectedShape = BauhausShapeKind.circle
  @State private var selectedShapeSwatch = BauhausPreviewFixtures.primaryShapeSwatch
  @State private var selectedBackgroundSwatch = BauhausPreviewFixtures.primaryBackgroundSwatch
  @State private var isErasing = false

  var body: some View {
    let colors = BauhausColorPalette.default.colors(for: colorScheme)

    BauhausPreviewCanvas {
      BauhausCaptureControls(
        selectedShape: $selectedShape,
        selectedShapeSwatch: $selectedShapeSwatch,
        selectedBackgroundSwatch: $selectedBackgroundSwatch,
        isErasing: $isErasing,
        canUndo: true,
        canRedo: true,
        isClearDisabled: false,
        isExportDisabled: false,
        showsExport: true,
        colors: colors,
        onUndo: {},
        onRedo: {},
        onClear: {},
        onExport: {},
        onSelectSwatch: {}
      )
    }
  }
}

fileprivate struct BauhausReplayPreview: View {

  @State private var isPlaying = true

  var body: some View {
    BauhausPreviewCanvas {
      BauhausGridReplayView(
        document: BauhausPreviewFixtures.replayDocument,
        isPlaying: $isPlaying
      )
      .frame(width: 320, height: 320)
    }
  }
}
