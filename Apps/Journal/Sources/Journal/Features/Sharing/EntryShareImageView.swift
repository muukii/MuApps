import AppUIComponents
import MuColor
import SwiftUI

/// Export-only composition for one detached entry snapshot.
///
/// The share feature owns only the vertical frame. Authored content keeps its
/// ordinary read-only presentation and is centered without receiving an
/// export-specific style.
struct EntryShareImageView: View {

  let snapshot: EntryShareSnapshot
  let palette: Palette

  init(snapshot: EntryShareSnapshot, palette: Palette = .default) {
    self.snapshot = snapshot
    self.palette = palette
  }

  var body: some View {
    EntryShareFrame(palette: palette) {
      EntryContentView(content: snapshot.content)
    }
  }
}

/// Static background shared by Doodle and Bauhaus replay-video frames.
///
/// The video writer composites animated authored content into the bounds from
/// `EntryShareFrameLayout`; the SwiftUI base therefore renders only the frame.
struct EntryShareVideoBaseFrameView: View {

  let palette: Palette

  init(palette: Palette = .default) {
    self.palette = palette
  }

  var body: some View {
    EntryShareFrame(palette: palette) {
      Color.clear
    }
  }
}

/// A vertical share canvas that centers ordinary authored content.
///
/// Layout, safe inset, theme, and raster scale belong to this boundary. The
/// child content does not know whether it is being displayed or exported.
struct EntryShareFrame<Content: View>: View {

  let palette: Palette

  private let content: Content

  init(
    palette: Palette = .default,
    @ViewBuilder content: () -> Content
  ) {
    self.palette = palette
    self.content = content()
  }

  var body: some View {
    PrimaryContainer(palette: palette) {
      ZStack {
        Rectangle()
          .fill(.appSecondaryContainer)

        content
          .frame(maxWidth: .infinity)
          .foregroundStyle(.appOnSecondaryContainer)
          .padding(EntryShareFrameLayout.contentInset)
      }
      .clipped()
    }
  }
}

/// Geometry contract shared by SwiftUI stills and Core Graphics video frames.
///
/// The logical frame uses phone-sized points. Raster output scales the complete
/// hierarchy uniformly, so content typography and spacing stay identical to the
/// normal Cell presentation instead of carrying share-only enlarged values.
enum EntryShareFrameLayout {

  /// Logical 9:16 canvas rendered by SwiftUI before raster scaling.
  nonisolated static let pointSize = CGSize(width: 360, height: 640)

  /// Safe distance between the canvas edge and centered authored content.
  nonisolated static let contentInset: CGFloat = 32

  /// Corner radius inherited from the ordinary `EntryContentView` presentation.
  nonisolated static let contentCornerRadius: CGFloat = 24

  /// Padding used by the ordinary Bauhaus Cell renderer around its grid.
  nonisolated static let bauhausGridPadding: CGFloat = 20

  /// Returns the uniform raster scale required for an output pixel size.
  ///
  /// Non-9:16 sizes return `nil` because stretching one axis would make still
  /// and video content disagree about geometry.
  nonisolated static func rasterScale(for pixelSize: CGSize) -> CGFloat? {
    guard pixelSize.width.isFinite,
      pixelSize.height.isFinite,
      pixelSize.width > 0,
      pixelSize.height > 0
    else {
      return nil
    }

    let horizontalScale = pixelSize.width / pointSize.width
    let verticalScale = pixelSize.height / pointSize.height
    let tolerance = max(horizontalScale, verticalScale) * 0.000_1
    guard abs(horizontalScale - verticalScale) <= tolerance else {
      return nil
    }

    return (horizontalScale + verticalScale) / 2
  }

  /// Returns the safe content bounds in output-pixel coordinates.
  nonisolated static func contentBounds(in pixelSize: CGSize) -> CGRect? {
    guard let scale = rasterScale(for: pixelSize) else { return nil }
    return CGRect(origin: .zero, size: pixelSize)
      .insetBy(dx: contentInset * scale, dy: contentInset * scale)
  }

  /// Aspect-fits authored content into `bounds` while keeping it centered.
  nonisolated static func aspectFitRect(
    aspectRatio: CGFloat,
    in bounds: CGRect
  ) -> CGRect {
    guard aspectRatio.isFinite,
      aspectRatio > 0,
      bounds.width > 0,
      bounds.height > 0
    else {
      return .zero
    }

    let boundsAspectRatio = bounds.width / bounds.height
    let fittedSize: CGSize
    if aspectRatio > boundsAspectRatio {
      fittedSize = CGSize(
        width: bounds.width,
        height: bounds.width / aspectRatio
      )
    } else {
      fittedSize = CGSize(
        width: bounds.height * aspectRatio,
        height: bounds.height
      )
    }

    return CGRect(
      x: bounds.midX - fittedSize.width / 2,
      y: bounds.midY - fittedSize.height / 2,
      width: fittedSize.width,
      height: fittedSize.height
    )
  }
}

#Preview("Entry Share Text") {
  EntryShareImageView(
    snapshot: EntryShareSnapshot(
      id: UUID(uuidString: "D86B20CE-D183-47D8-9795-552F6B00C40B")!,
      content: .text("A quiet morning, warm light, and a thought worth keeping.")
    )
  )
  .frame(
    width: EntryShareFrameLayout.pointSize.width,
    height: EntryShareFrameLayout.pointSize.height
  )
}
