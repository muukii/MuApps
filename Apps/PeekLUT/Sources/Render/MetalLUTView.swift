import CoreImage
import MetalKit
import SwiftUI

struct MetalLUTView: UIViewRepresentable {

  let frameSource: FrameSource?
  let lut: LUT?
  let isPeeking: Bool

  func makeCoordinator() -> Coordinator {
    Coordinator()
  }

  func makeUIView(context: Context) -> MTKView {
    let view = MTKView()
    view.device = LUTRenderer.shared.device ?? MTLCreateSystemDefaultDevice()
    view.framebufferOnly = false
    view.colorPixelFormat = .bgra8Unorm
    view.isOpaque = true
    view.backgroundColor = .black
    view.contentMode = .scaleAspectFit
    view.isUserInteractionEnabled = false
    view.delegate = context.coordinator
    view.preferredFramesPerSecond = 60
    context.coordinator.attach(view: view)
    apply(state: context)
    return view
  }

  func updateUIView(_ uiView: MTKView, context: Context) {
    apply(state: context)
    if !uiView.isPaused {
      // free-running already; nothing to do
    } else {
      uiView.setNeedsDisplay()
    }
  }

  private func apply(state context: Context) {
    let coord = context.coordinator
    coord.frameSource = frameSource
    coord.lut = lut
    coord.isPeeking = isPeeking
    if let view = coord.mtkView {
      let continuous = frameSource?.isContinuous == true
      view.enableSetNeedsDisplay = !continuous
      view.isPaused = !continuous
    }
  }

  @MainActor
  final class Coordinator: NSObject, MTKViewDelegate {
    let renderer = LUTRenderer.shared
    weak var mtkView: MTKView?
    var frameSource: FrameSource?
    var lut: LUT?
    var isPeeking: Bool = false

    func attach(view: MTKView) {
      self.mtkView = view
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
      guard
        let drawable = view.currentDrawable,
        let queue = renderer.commandQueue,
        let commandBuffer = queue.makeCommandBuffer(),
        let frame = frameSource?.nextFrame()
      else {
        return
      }

      let processed = isPeeking ? frame : renderer.apply(lut: lut, to: frame)
      let drawableSize = view.drawableSize
      let fitted = aspectFit(processed, in: drawableSize)

      let destination = CIRenderDestination(
        width: Int(drawableSize.width),
        height: Int(drawableSize.height),
        pixelFormat: view.colorPixelFormat,
        commandBuffer: commandBuffer,
        mtlTextureProvider: { drawable.texture }
      )
      destination.colorSpace = renderer.workingColorSpace

      // Clear background
      let clear = CIImage(color: .black).cropped(to: CGRect(origin: .zero, size: drawableSize))
      let composited = fitted.composited(over: clear)
      _ = try? renderer.context.startTask(toRender: composited, to: destination)

      commandBuffer.present(drawable)
      commandBuffer.commit()
    }

    private func aspectFit(_ image: CIImage, in size: CGSize) -> CIImage {
      let extent = image.extent
      guard extent.width > 0, extent.height > 0, size.width > 0, size.height > 0 else {
        return image
      }
      let scale = min(size.width / extent.width, size.height / extent.height)
      let scaled = image.transformed(by: .init(scaleX: scale, y: scale))
      let scaledExtent = scaled.extent
      let tx = (size.width - scaledExtent.width) / 2 - scaledExtent.origin.x
      let ty = (size.height - scaledExtent.height) / 2 - scaledExtent.origin.y
      return scaled.transformed(by: .init(translationX: tx, y: ty))
    }
  }
}
