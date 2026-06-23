import CoreGraphics

/// A committed stroke: stamp centers in canvas (view-point) space plus the brush
/// it was drawn with. Kept so the canvas can be rebuilt on undo/clear/resize.
struct InkStroke {
  var stamps: [CGPoint]
  var brush: InkBrush
}
