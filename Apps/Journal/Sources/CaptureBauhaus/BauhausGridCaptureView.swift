import SwiftUI
import UIKit

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

  /// Rasterizes the artwork into a square image suitable for thumbnails and
  /// share previews. Empty artwork returns `nil` so callers can keep their
  /// "missing payload" checks simple.
  @MainActor
  public func image(
    size: CGSize = CGSize(width: 1024, height: 1024),
    scale: CGFloat = 1
  ) -> UIImage? {
    guard isEmpty == false else { return nil }
    let renderer = ImageRenderer(
      content: BauhausArtworkRasterView(artwork: self)
        .frame(width: size.width, height: size.height)
    )
    renderer.scale = scale
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
/// Use `BauhausGridArtwork.image(...)` only when a flattened export image is
/// explicitly needed.
public struct BauhausGridArtworkView: View {

  public let artwork: BauhausGridArtwork

  public init(artwork: BauhausGridArtwork) {
    self.artwork = artwork
  }

  public var body: some View {
    BauhausArtworkRasterView(artwork: artwork)
      .aspectRatio(1, contentMode: .fit)
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
    backgroundSwatch: BauhausSwatch = .porcelain
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
      ?? .vermilion
    backgroundSwatch = try container.decodeIfPresent(BauhausSwatch.self, forKey: .backgroundSwatch)
      ?? .porcelain
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
  case circle
  case semicircleTop
  case semicircleTrailing
  case semicircleBottom
  case semicircleLeading
  case quarterCircleTopLeading
  case quarterCircleTopTrailing
  case quarterCircleBottomTrailing
  case quarterCircleBottomLeading
  case triangleTopLeading
  case triangleTopTrailing
  case triangleBottomTrailing
  case triangleBottomLeading

  public var id: String { rawValue }
}

/// A compact fixed palette for authored Bauhaus artwork.
///
/// These are content colors, not Journal theme colors. Keeping them as tokens
/// instead of raw `Color` values makes saved artwork stable and Codable.
public enum BauhausSwatch: String, CaseIterable, Codable, Identifiable, Sendable {
  case vermilion
  case ochre
  case porcelain
  case blush
  case cobalt
  case forest
  case ink

  public var id: String { rawValue }

  public var color: Color {
    switch self {
    case .vermilion:
      Color(.displayP3, red: 0.83, green: 0.22, blue: 0.12, opacity: 1)
    case .ochre:
      Color(.displayP3, red: 0.91, green: 0.66, blue: 0.31, opacity: 1)
    case .porcelain:
      Color(.displayP3, red: 0.93, green: 0.90, blue: 0.84, opacity: 1)
    case .blush:
      Color(.displayP3, red: 0.91, green: 0.63, blue: 0.64, opacity: 1)
    case .cobalt:
      Color(.displayP3, red: 0.25, green: 0.50, blue: 0.68, opacity: 1)
    case .forest:
      Color(.displayP3, red: 0.04, green: 0.27, blue: 0.18, opacity: 1)
    case .ink:
      Color(.displayP3, red: 0.04, green: 0.04, blue: 0.05, opacity: 1)
    }
  }
}

/// Interactive 5 x 5 Bauhaus grid editor.
///
/// Users tap a grid cell, pick one of the prepared shapes, and the selected
/// shape, primitive color, and cell background color are applied to that cell.
/// The component reports every edit through `onChange` and can expose an
/// explicit export action when a host supplies `onExport`.
public struct BauhausGridCaptureView: View {

  @State private var artwork: BauhausGridArtwork
  @State private var selectedPosition: BauhausGridPosition?
  @State private var selectedShapeSwatch: BauhausSwatch = .vermilion
  @State private var selectedBackgroundSwatch: BauhausSwatch = .porcelain
  @State private var selectionFeedbackTrigger = 0
  @State private var editFeedbackTrigger = 0
  @State private var completionFeedbackTrigger = 0

  private let onChange: (@MainActor @Sendable (BauhausGridArtwork) -> Void)?
  private let onExport: (@MainActor @Sendable (BauhausGridArtwork) -> Void)?

  @MainActor
  public init(
    initialArtwork: BauhausGridArtwork = .empty,
    onChange: (@MainActor @Sendable (BauhausGridArtwork) -> Void)? = nil,
    onExport: (@MainActor @Sendable (BauhausGridArtwork) -> Void)? = nil
  ) {
    _artwork = State(initialValue: initialArtwork)
    self.onChange = onChange
    self.onExport = onExport
  }

  public var body: some View {
    ScrollView {
      VStack(spacing: 20) {
        BauhausArtworkBoard(
          artwork: artwork,
          selectedPosition: selectedPosition,
          onSelect: selectCell
        )
        .padding(.horizontal, 20)
        .padding(.top, 18)

        BauhausCaptureControls(
          selectedShapeSwatch: $selectedShapeSwatch,
          selectedBackgroundSwatch: $selectedBackgroundSwatch,
          isClearDisabled: artwork.isEmpty,
          isExportDisabled: artwork.isEmpty,
          showsExport: onExport != nil,
          onClear: clear,
          onExport: export,
          onSelectSwatch: triggerSelectionFeedback
        )
        .padding(.horizontal, 20)
        .padding(.bottom, 24)
      }
      .frame(maxWidth: 560)
      .frame(maxWidth: .infinity)
    }
    .background(.background)
    .navigationTitle("Bauhaus")
    .navigationBarTitleDisplayMode(.inline)
    .sheet(item: $selectedPosition) { position in
      BauhausShapePickerSheet(
        selectedShapeSwatch: $selectedShapeSwatch,
        selectedBackgroundSwatch: $selectedBackgroundSwatch,
        currentTile: artwork[position],
        onApply: { tile in
          apply(tile, at: position)
        },
        onClear: {
          apply(nil, at: position)
        },
        onSelectSwatch: triggerSelectionFeedback
      )
      .presentationDetents([.height(420), .medium])
      .presentationDragIndicator(.visible)
      .presentationBackground(.background)
    }
    .sensoryFeedback(.selection, trigger: selectionFeedbackTrigger)
    .sensoryFeedback(.impact(weight: .light), trigger: editFeedbackTrigger)
    .sensoryFeedback(.success, trigger: completionFeedbackTrigger)
  }

  private func selectCell(_ position: BauhausGridPosition) {
    triggerSelectionFeedback()
    if let tile = artwork[position] {
      selectedShapeSwatch = tile.shapeSwatch
      selectedBackgroundSwatch = tile.backgroundSwatch
    }
    selectedPosition = position
  }

  private func apply(_ tile: BauhausTile?, at position: BauhausGridPosition) {
    withAnimation(.spring(response: 0.32, dampingFraction: 0.86)) {
      artwork[position] = tile
    }
    selectedPosition = nil
    triggerEditFeedback()
    onChange?(artwork)
  }

  private func clear() {
    guard artwork.isEmpty == false else { return }
    withAnimation(.spring(response: 0.32, dampingFraction: 0.9)) {
      artwork = .empty
    }
    triggerEditFeedback()
    onChange?(artwork)
  }

  private func export() {
    guard artwork.isEmpty == false else { return }
    triggerCompletionFeedback()
    onExport?(artwork)
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

fileprivate enum BauhausGridStyle {

  static let paperColor = Color(.displayP3, red: 0.96, green: 0.93, blue: 0.88, opacity: 1)
  static let emptyCellColor = Color(.displayP3, red: 0.91, green: 0.87, blue: 0.80, opacity: 1)
}

fileprivate struct BauhausArtworkBoard: View {

  let artwork: BauhausGridArtwork
  let selectedPosition: BauhausGridPosition?
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
            onSelect: {
              onSelect(position)
            }
          )
        }
      }
      .padding(2)
      .background(.white)
      .aspectRatio(1, contentMode: .fit)
      .overlay {
        Rectangle()
          .strokeBorder(.white, lineWidth: 2)
      }
    }
    .padding(12)
    .background(
      Rectangle()
        .fill(BauhausGridStyle.paperColor)
    )
    .overlay {
      Rectangle()
        .strokeBorder(.primary.opacity(0.08), lineWidth: 1)
    }
  }
}

fileprivate struct BauhausGridCellButton: View {

  let tile: BauhausTile?
  let isSelected: Bool
  let onSelect: @MainActor @Sendable () -> Void

  var body: some View {
    Button(action: onSelect) {
      ZStack {
        Rectangle()
          .fill(tile?.backgroundSwatch.color ?? BauhausGridStyle.emptyCellColor)

        if let tile {
          BauhausShape(kind: tile.shape)
            .fill(tile.shapeSwatch.color)
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

fileprivate struct BauhausShapePickerSheet: View {

  @Binding var selectedShapeSwatch: BauhausSwatch
  @Binding var selectedBackgroundSwatch: BauhausSwatch

  let currentTile: BauhausTile?
  let onApply: @MainActor @Sendable (BauhausTile) -> Void
  let onClear: @MainActor @Sendable () -> Void
  let onSelectSwatch: @MainActor @Sendable () -> Void

  private let columns = [
    GridItem(.adaptive(minimum: 56, maximum: 56), spacing: 12)
  ]

  var body: some View {
    NavigationStack {
      ScrollView {
        VStack(spacing: 18) {
          VStack(spacing: 10) {
            BauhausSwatchStrip(
              title: "Shape",
              selectedSwatch: $selectedShapeSwatch,
              onSelect: onSelectSwatch
            )
            BauhausSwatchStrip(
              title: "Background",
              selectedSwatch: $selectedBackgroundSwatch,
              onSelect: onSelectSwatch
            )
          }

          LazyVGrid(columns: columns, spacing: 12) {
            ForEach(BauhausShapeKind.allCases) { shape in
              let tile = BauhausTile(
                shape: shape,
                shapeSwatch: selectedShapeSwatch,
                backgroundSwatch: selectedBackgroundSwatch
              )
              Button {
                onApply(tile)
              } label: {
                BauhausShapeLibraryTile(
                  tile: tile,
                  isSelected: currentTile == tile
                )
              }
              .buttonStyle(.plain)
              .accessibilityLabel("Apply Bauhaus shape")
            }
          }
        }
        .padding(.horizontal, 20)
        .padding(.top, 14)
        .padding(.bottom, 20)
      }
      .navigationTitle("Shape")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .topBarTrailing) {
          Button(role: .destructive, action: onClear) {
            Image(systemName: "eraser")
          }
          .disabled(currentTile == nil)
          .accessibilityLabel("Clear cell")
        }
      }
    }
  }
}

fileprivate struct BauhausSwatchStrip: View {

  var title: LocalizedStringKey?
  @Binding var selectedSwatch: BauhausSwatch
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
            .fill(swatch.color)
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

  var body: some View {
    ZStack {
      RoundedRectangle(cornerRadius: 8)
        .fill(tile.backgroundSwatch.color)

      BauhausShape(kind: tile.shape)
        .fill(tile.shapeSwatch.color)
        .padding(8)
    }
    .frame(width: 56, height: 56)
    .overlay {
      RoundedRectangle(cornerRadius: 8)
        .strokeBorder(.white.opacity(0.72), lineWidth: 1)
    }
    .overlay {
      RoundedRectangle(cornerRadius: 8)
        .strokeBorder(isSelected ? AnyShapeStyle(.tint) : AnyShapeStyle(.primary.opacity(0.12)), lineWidth: isSelected ? 2 : 1)
    }
  }
}

fileprivate struct BauhausCaptureControls: View {

  @Binding var selectedShapeSwatch: BauhausSwatch
  @Binding var selectedBackgroundSwatch: BauhausSwatch

  let isClearDisabled: Bool
  let isExportDisabled: Bool
  let showsExport: Bool
  let onClear: @MainActor @Sendable () -> Void
  let onExport: @MainActor @Sendable () -> Void
  let onSelectSwatch: @MainActor @Sendable () -> Void

  var body: some View {
    HStack(spacing: 14) {
      Button(role: .destructive, action: onClear) {
        Image(systemName: "trash")
      }
      .disabled(isClearDisabled)
      .accessibilityLabel("Clear artwork")

      Spacer(minLength: 0)

      VStack(spacing: 8) {
        BauhausSwatchStrip(
          title: "Shape",
          selectedSwatch: $selectedShapeSwatch,
          dotSize: 24,
          onSelect: onSelectSwatch
        )
        BauhausSwatchStrip(
          title: "Background",
          selectedSwatch: $selectedBackgroundSwatch,
          dotSize: 24,
          onSelect: onSelectSwatch
        )
      }
      .frame(maxWidth: 360)

      Spacer(minLength: 0)

      if showsExport {
        Button(action: onExport) {
          Image(systemName: "checkmark")
        }
        .disabled(isExportDisabled)
        .accessibilityLabel("Finish artwork")
      }
    }
    .buttonStyle(.bordered)
    .controlSize(.large)
  }
}

// MARK: - Rendering

fileprivate struct BauhausArtworkThumbnail: View {

  let artwork: BauhausGridArtwork

  private let columns = Array(
    repeating: GridItem(.flexible(minimum: 0), spacing: 1),
    count: BauhausGridArtwork.dimension
  )

  var body: some View {
    LazyVGrid(columns: columns, spacing: 1) {
      ForEach(BauhausGridArtwork.positions) { position in
        ZStack {
          Rectangle()
            .fill(artwork[position]?.backgroundSwatch.color ?? BauhausGridStyle.emptyCellColor)

          if let tile = artwork[position] {
            BauhausShape(kind: tile.shape)
              .fill(tile.shapeSwatch.color)
          }
        }
        .aspectRatio(1, contentMode: .fit)
      }
    }
    .padding(2)
    .background(.white)
    .overlay {
      Rectangle()
        .strokeBorder(.white, lineWidth: 2)
    }
    .shadow(color: .black.opacity(0.12), radius: 10, x: 0, y: 6)
  }
}

fileprivate struct BauhausArtworkRasterView: View {

  let artwork: BauhausGridArtwork

  private let columns = Array(
    repeating: GridItem(.flexible(minimum: 0), spacing: 2),
    count: BauhausGridArtwork.dimension
  )

  var body: some View {
    LazyVGrid(columns: columns, spacing: 2) {
      ForEach(BauhausGridArtwork.positions) { position in
        ZStack {
          Rectangle()
            .fill(artwork[position]?.backgroundSwatch.color ?? BauhausGridStyle.emptyCellColor)

          if let tile = artwork[position] {
            BauhausShape(kind: tile.shape)
              .fill(tile.shapeSwatch.color)
          }
        }
        .aspectRatio(1, contentMode: .fit)
      }
    }
    .padding(8)
    .background(
      Rectangle()
        .fill(BauhausGridStyle.paperColor)
    )
  }
}

fileprivate struct BauhausShape: Shape {

  let kind: BauhausShapeKind

  func path(in rect: CGRect) -> Path {
    kind.path(in: rect)
  }
}

fileprivate extension BauhausShapeKind {

  func path(in rect: CGRect) -> Path {
    switch self {
    case .square:
      return Path(rect)
    case .circle:
      return Path(ellipseIn: rect.insetBy(dx: rect.width * 0.12, dy: rect.height * 0.12))
    case .semicircleTop:
      return semicirclePath(in: rect, edge: .top)
    case .semicircleTrailing:
      return semicirclePath(in: rect, edge: .trailing)
    case .semicircleBottom:
      return semicirclePath(in: rect, edge: .bottom)
    case .semicircleLeading:
      return semicirclePath(in: rect, edge: .leading)
    case .quarterCircleTopLeading:
      return quarterCirclePath(in: rect, corner: .topLeading)
    case .quarterCircleTopTrailing:
      return quarterCirclePath(in: rect, corner: .topTrailing)
    case .quarterCircleBottomTrailing:
      return quarterCirclePath(in: rect, corner: .bottomTrailing)
    case .quarterCircleBottomLeading:
      return quarterCirclePath(in: rect, corner: .bottomLeading)
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

#Preview {
  NavigationStack {
    BauhausGridCaptureDemoView()
  }
}
