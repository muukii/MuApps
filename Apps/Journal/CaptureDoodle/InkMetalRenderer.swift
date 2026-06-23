import Metal
import MetalKit
import UIKit
import simd

// Uniform structs — must match the MSL layout in `shaderSource`.

private struct StampUniforms {
  var canvasSize: SIMD2<Float>
  var center: SIMD2<Float>
  var radius: Float
  var hardness: Float
  var opacity: Float
  var padding: Float = 0
}

private struct CompositeUniforms {
  var color: SIMD4<Float>
}

extension InkBrush {
  /// Straight (non-premultiplied) RGB with alpha folded with stroke opacity.
  fileprivate var effectiveColor: SIMD4<Float> {
    SIMD4(Float(color.red), Float(color.green), Float(color.blue), Float(color.alpha * opacity))
  }
}

/// Metal ink renderer adapted from Brightroom's brush-stamp rasterizer. Strokes
/// are soft round stamps laid along the smoothed path. The masking indirection
/// is replaced with colored ink:
///   - active stroke → a single-channel coverage texture (`.max` blend, so
///     overlapping stamps don't darken past opacity)
///   - on commit → the coverage is tinted by the brush color and flattened into
///     a persistent canvas texture (premultiplied source-over)
///   - each frame → blit the canvas, then composite the live coverage on top
/// This keeps per-frame cost at O(live stroke) instead of redrawing every stroke.
@MainActor
final class InkMetalRenderer {

  let device: MTLDevice
  private let commandQueue: MTLCommandQueue
  private let stampPipeline: MTLRenderPipelineState
  private let compositePipeline: MTLRenderPipelineState
  private let blitPipeline: MTLRenderPipelineState

  private var canvasTexture: MTLTexture?
  private var coverageTexture: MTLTexture?
  private var pixelSize: CGSize = .zero
  private var scale: CGFloat = 1

  private var committed: [InkStroke] = []
  private var activeBrush: InkBrush?
  private var activeStamps: [CGPoint] = []

  var hasContent: Bool { committed.isEmpty == false }

  init?(device: MTLDevice) {
    guard
      let queue = device.makeCommandQueue(),
      let library = try? device.makeLibrary(source: Self.shaderSource, options: nil),
      let stamp = try? Self.makeStampPipeline(device: device, library: library),
      let composite = try? Self.makeCompositePipeline(device: device, library: library),
      let blit = try? Self.makeBlitPipeline(device: device, library: library)
    else {
      return nil
    }
    self.device = device
    self.commandQueue = queue
    self.stampPipeline = stamp
    self.compositePipeline = composite
    self.blitPipeline = blit
  }

  // MARK: - Sizing

  func resize(pixelSize: CGSize, scale: CGFloat) {
    guard pixelSize.width > 0, pixelSize.height > 0 else { return }
    guard pixelSize != self.pixelSize || scale != self.scale else { return }
    self.pixelSize = pixelSize
    self.scale = scale
    canvasTexture = makeTexture(format: .bgra8Unorm, usage: [.renderTarget, .shaderRead], storage: .shared)
    coverageTexture = makeTexture(format: .r8Unorm, usage: [.renderTarget, .shaderRead], storage: .private)
    rebuildCanvas()
  }

  // MARK: - Stroke lifecycle

  func beginStroke(brush: InkBrush) {
    activeBrush = brush
    activeStamps = []
    guard let coverageTexture, let commandBuffer = commandQueue.makeCommandBuffer() else { return }
    clearTexture(coverageTexture, commandBuffer: commandBuffer)
    commandBuffer.commit()
  }

  func appendStamps(_ stamps: [CGPoint]) {
    guard let brush = activeBrush, let coverageTexture, stamps.isEmpty == false else { return }
    activeStamps += stamps
    guard let commandBuffer = commandQueue.makeCommandBuffer() else { return }
    rasterize(stamps: stamps, brush: brush, into: coverageTexture, commandBuffer: commandBuffer, load: .load)
    commandBuffer.commit()
  }

  func endStroke() {
    defer {
      activeBrush = nil
      activeStamps = []
    }
    guard let brush = activeBrush, let canvasTexture, let coverageTexture else { return }
    guard activeStamps.isEmpty == false, let commandBuffer = commandQueue.makeCommandBuffer() else { return }
    composite(coverage: coverageTexture, color: brush.effectiveColor, into: canvasTexture, commandBuffer: commandBuffer, load: .load)
    clearTexture(coverageTexture, commandBuffer: commandBuffer)
    commandBuffer.commit()
    committed.append(InkStroke(stamps: activeStamps, brush: brush))
  }

  func cancelStroke() {
    activeBrush = nil
    activeStamps = []
    guard let coverageTexture, let commandBuffer = commandQueue.makeCommandBuffer() else { return }
    clearTexture(coverageTexture, commandBuffer: commandBuffer)
    commandBuffer.commit()
  }

  // MARK: - Editing

  func undo() {
    guard committed.isEmpty == false else { return }
    committed.removeLast()
    rebuildCanvas()
  }

  func clear() {
    committed.removeAll()
    activeBrush = nil
    activeStamps = []
    rebuildCanvas()
    guard let coverageTexture, let commandBuffer = commandQueue.makeCommandBuffer() else { return }
    clearTexture(coverageTexture, commandBuffer: commandBuffer)
    commandBuffer.commit()
  }

  // MARK: - Frame render

  func render(in view: MTKView) {
    guard
      let drawable = view.currentDrawable,
      let passDescriptor = view.currentRenderPassDescriptor,
      let canvasTexture,
      let coverageTexture,
      let commandBuffer = commandQueue.makeCommandBuffer(),
      let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: passDescriptor)
    else {
      return
    }

    // 1. Committed ink.
    encoder.setRenderPipelineState(blitPipeline)
    encoder.setFragmentTexture(canvasTexture, index: 0)
    encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)

    // 2. Live in-flight stroke.
    if let brush = activeBrush, activeStamps.isEmpty == false {
      var uniforms = CompositeUniforms(color: brush.effectiveColor)
      encoder.setRenderPipelineState(compositePipeline)
      encoder.setFragmentTexture(coverageTexture, index: 0)
      encoder.setFragmentBytes(&uniforms, length: MemoryLayout<CompositeUniforms>.stride, index: 0)
      encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }

    encoder.endEncoding()
    commandBuffer.present(drawable)
    commandBuffer.commit()
  }

  // MARK: - Export

  func exportImage() -> UIImage? {
    guard let canvasTexture, pixelSize.width > 0 else { return nil }

    // Flush the queue so all committed GPU writes have landed before readback.
    if let fence = commandQueue.makeCommandBuffer() {
      fence.commit()
      fence.waitUntilCompleted()
    }

    let width = canvasTexture.width
    let height = canvasTexture.height
    let bytesPerRow = width * 4
    var bytes = [UInt8](repeating: 0, count: bytesPerRow * height)
    bytes.withUnsafeMutableBytes { raw in
      canvasTexture.getBytes(
        raw.baseAddress!,
        bytesPerRow: bytesPerRow,
        from: MTLRegionMake2D(0, 0, width, height),
        mipmapLevel: 0
      )
    }

    let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    guard
      let context = CGContext(
        data: &bytes,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: bytesPerRow,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: bitmapInfo
      ),
      let cgImage = context.makeImage()
    else {
      return nil
    }
    return UIImage(cgImage: cgImage, scale: scale, orientation: .up)
  }

  // MARK: - GPU helpers

  private func rebuildCanvas() {
    guard let canvasTexture, let coverageTexture else { return }
    if let commandBuffer = commandQueue.makeCommandBuffer() {
      clearTexture(canvasTexture, commandBuffer: commandBuffer)
      commandBuffer.commit()
    }
    for stroke in committed {
      guard let commandBuffer = commandQueue.makeCommandBuffer() else { continue }
      clearTexture(coverageTexture, commandBuffer: commandBuffer)
      rasterize(stamps: stroke.stamps, brush: stroke.brush, into: coverageTexture, commandBuffer: commandBuffer, load: .load)
      composite(coverage: coverageTexture, color: stroke.brush.effectiveColor, into: canvasTexture, commandBuffer: commandBuffer, load: .load)
      commandBuffer.commit()
    }
  }

  private func rasterize(
    stamps: [CGPoint],
    brush: InkBrush,
    into texture: MTLTexture,
    commandBuffer: MTLCommandBuffer,
    load: MTLLoadAction
  ) {
    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = texture
    pass.colorAttachments[0].loadAction = load
    pass.colorAttachments[0].storeAction = .store
    pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
    guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
    encoder.setRenderPipelineState(stampPipeline)

    let canvas = SIMD2<Float>(Float(pixelSize.width), Float(pixelSize.height))
    let radius = Float(brush.size / 2 * Double(scale))
    for stamp in stamps {
      var uniforms = StampUniforms(
        canvasSize: canvas,
        center: SIMD2(Float(stamp.x * scale), Float(stamp.y * scale)),
        radius: radius,
        hardness: Float(brush.hardness),
        opacity: 1
      )
      encoder.setVertexBytes(&uniforms, length: MemoryLayout<StampUniforms>.stride, index: 0)
      encoder.setFragmentBytes(&uniforms, length: MemoryLayout<StampUniforms>.stride, index: 0)
      encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    }
    encoder.endEncoding()
  }

  private func composite(
    coverage: MTLTexture,
    color: SIMD4<Float>,
    into target: MTLTexture,
    commandBuffer: MTLCommandBuffer,
    load: MTLLoadAction
  ) {
    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = target
    pass.colorAttachments[0].loadAction = load
    pass.colorAttachments[0].storeAction = .store
    pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
    guard let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: pass) else { return }
    encoder.setRenderPipelineState(compositePipeline)
    encoder.setFragmentTexture(coverage, index: 0)
    var uniforms = CompositeUniforms(color: color)
    encoder.setFragmentBytes(&uniforms, length: MemoryLayout<CompositeUniforms>.stride, index: 0)
    encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
    encoder.endEncoding()
  }

  private func clearTexture(_ texture: MTLTexture, commandBuffer: MTLCommandBuffer) {
    let pass = MTLRenderPassDescriptor()
    pass.colorAttachments[0].texture = texture
    pass.colorAttachments[0].loadAction = .clear
    pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
    pass.colorAttachments[0].storeAction = .store
    commandBuffer.makeRenderCommandEncoder(descriptor: pass)?.endEncoding()
  }

  private func makeTexture(
    format: MTLPixelFormat,
    usage: MTLTextureUsage,
    storage: MTLStorageMode
  ) -> MTLTexture? {
    let descriptor = MTLTextureDescriptor.texture2DDescriptor(
      pixelFormat: format,
      width: Int(pixelSize.width),
      height: Int(pixelSize.height),
      mipmapped: false
    )
    descriptor.usage = usage
    descriptor.storageMode = storage
    return device.makeTexture(descriptor: descriptor)
  }

  // MARK: - Pipelines

  private static func makeStampPipeline(device: MTLDevice, library: MTLLibrary) throws -> MTLRenderPipelineState {
    let descriptor = MTLRenderPipelineDescriptor()
    descriptor.vertexFunction = library.makeFunction(name: "ink_stamp_vertex")
    descriptor.fragmentFunction = library.makeFunction(name: "ink_stamp_fragment")
    let attachment = descriptor.colorAttachments[0]!
    attachment.pixelFormat = .r8Unorm
    // `.max` so overlapping stamps within one stroke don't accumulate past opacity.
    attachment.isBlendingEnabled = true
    attachment.rgbBlendOperation = .max
    attachment.alphaBlendOperation = .max
    attachment.sourceRGBBlendFactor = .one
    attachment.sourceAlphaBlendFactor = .one
    attachment.destinationRGBBlendFactor = .one
    attachment.destinationAlphaBlendFactor = .one
    return try device.makeRenderPipelineState(descriptor: descriptor)
  }

  private static func makeCompositePipeline(device: MTLDevice, library: MTLLibrary) throws -> MTLRenderPipelineState {
    let descriptor = MTLRenderPipelineDescriptor()
    descriptor.vertexFunction = library.makeFunction(name: "ink_fullscreen_vertex")
    descriptor.fragmentFunction = library.makeFunction(name: "ink_composite_fragment")
    configureSourceOver(descriptor.colorAttachments[0]!)
    return try device.makeRenderPipelineState(descriptor: descriptor)
  }

  private static func makeBlitPipeline(device: MTLDevice, library: MTLLibrary) throws -> MTLRenderPipelineState {
    let descriptor = MTLRenderPipelineDescriptor()
    descriptor.vertexFunction = library.makeFunction(name: "ink_fullscreen_vertex")
    descriptor.fragmentFunction = library.makeFunction(name: "ink_blit_fragment")
    configureSourceOver(descriptor.colorAttachments[0]!)
    return try device.makeRenderPipelineState(descriptor: descriptor)
  }

  private static func configureSourceOver(_ attachment: MTLRenderPipelineColorAttachmentDescriptor) {
    attachment.pixelFormat = .bgra8Unorm
    attachment.isBlendingEnabled = true
    attachment.rgbBlendOperation = .add
    attachment.alphaBlendOperation = .add
    attachment.sourceRGBBlendFactor = .one // premultiplied
    attachment.sourceAlphaBlendFactor = .one
    attachment.destinationRGBBlendFactor = .oneMinusSourceAlpha
    attachment.destinationAlphaBlendFactor = .oneMinusSourceAlpha
  }

  // MARK: - Shaders

  private static let shaderSource = """
  #include <metal_stdlib>
  using namespace metal;

  struct StampUniforms {
    float2 canvasSize;
    float2 center;
    float radius;
    float hardness;
    float opacity;
    float padding;
  };

  struct StampVertexOut {
    float4 position [[position]];
    float2 local;
  };

  inline float ink_stamp_alpha(float d, float hardness, float opacity) {
    if (d > 1.0) { return 0.0; }
    float alpha = 1.0;
    if (hardness < 0.999) {
      float start = clamp(hardness, 0.0, 0.998);
      alpha = 1.0 - smoothstep(start, 1.0, d);
    }
    return alpha * clamp(opacity, 0.0, 1.0);
  }

  vertex StampVertexOut ink_stamp_vertex(uint vid [[vertex_id]],
                                         constant StampUniforms& brush [[buffer(0)]]) {
    constexpr float2 corners[4] = {
      float2(-1.0, -1.0), float2(1.0, -1.0),
      float2(-1.0,  1.0), float2(1.0,  1.0)
    };
    float2 local = corners[vid];
    float2 pixel = brush.center + local * brush.radius;
    float2 pos = float2(
      pixel.x / brush.canvasSize.x * 2.0 - 1.0,
      1.0 - pixel.y / brush.canvasSize.y * 2.0
    );
    StampVertexOut out;
    out.position = float4(pos, 0.0, 1.0);
    out.local = local;
    return out;
  }

  fragment float4 ink_stamp_fragment(StampVertexOut in [[stage_in]],
                                     constant StampUniforms& brush [[buffer(0)]]) {
    float a = ink_stamp_alpha(length(in.local), brush.hardness, brush.opacity);
    return float4(a, a, a, a);
  }

  struct FullscreenOut {
    float4 position [[position]];
    float2 uv;
  };

  vertex FullscreenOut ink_fullscreen_vertex(uint vid [[vertex_id]]) {
    constexpr float2 positions[4] = {
      float2(-1.0, -1.0), float2(1.0, -1.0),
      float2(-1.0,  1.0), float2(1.0,  1.0)
    };
    constexpr float2 uvs[4] = {
      float2(0.0, 1.0), float2(1.0, 1.0),
      float2(0.0, 0.0), float2(1.0, 0.0)
    };
    FullscreenOut out;
    out.position = float4(positions[vid], 0.0, 1.0);
    out.uv = uvs[vid];
    return out;
  }

  struct CompositeUniforms {
    float4 color;
  };

  fragment float4 ink_composite_fragment(FullscreenOut in [[stage_in]],
                                         texture2d<float> coverage [[texture(0)]],
                                         constant CompositeUniforms& uniforms [[buffer(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    float cov = coverage.sample(s, in.uv).r;
    float a = cov * uniforms.color.a;
    return float4(uniforms.color.rgb * a, a);
  }

  fragment float4 ink_blit_fragment(FullscreenOut in [[stage_in]],
                                    texture2d<float> image [[texture(0)]]) {
    constexpr sampler s(filter::linear, address::clamp_to_edge);
    return image.sample(s, in.uv);
  }
  """
}
