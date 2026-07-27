import AVFoundation
import BrightroomParametric
import CoreGraphics
import CoreImage
import FargMotionBlur
import Testing

@testable import Farg

/// Verifies the color contract carried by a render recipe independently of
/// AVFoundation's decoder and encoder negotiation.
@Suite("LUT output color space")
struct LUTOutputColorSpaceTests {

  private let emptyDocument = EditingDocument(
    mainTree: MainTree(features: [])
  )

  @Test
  func rec709LUTSeparatesMasteringFromCoreMediaDelivery() {
    let outputColorSpace = FargLUTOutputColorSpace.rec709

    #expect(
      outputColorSpace.lutResultColorSpace.name
        == CGColorSpace.itur_709
    )
    #expect(
      outputColorSpace.coreMediaDeliveryColorSpace.name
        == CGColorSpace.coreMedia709
    )
    #expect(
      outputColorSpace.lutResultColorSpace
        != outputColorSpace.coreMediaDeliveryColorSpace
    )
  }

  @Test
  func coreMediaDeliveryCompensatesRec709MasteringMidtone() {
    let outputColorSpace = FargLUTOutputColorSpace.rec709
    let sourceImage = CIImage(
      bitmapData: Data([128, 128, 128, 255]),
      bytesPerRow: 4,
      size: CGSize(width: 1, height: 1),
      format: .RGBA8,
      colorSpace: outputColorSpace.lutResultColorSpace
    )
    var deliveryPixel = [UInt8](repeating: 0, count: 4)

    deliveryPixel.withUnsafeMutableBytes { buffer in
      FargCIContext.shared.render(
        sourceImage,
        toBitmap: buffer.baseAddress!,
        rowBytes: 4,
        bounds: sourceImage.extent,
        format: .RGBA8,
        colorSpace: outputColorSpace.coreMediaDeliveryColorSpace
      )
    }

    // 128 in Rec.709 / Gamma 2.4 becomes approximately 110 so Apple's
    // 1-1-1 playback reconstructs the intended mastering luminance.
    #expect((109...111).contains(Int(deliveryPixel[0])))
    #expect(deliveryPixel[0] == deliveryPixel[1])
    #expect(deliveryPixel[1] == deliveryPixel[2])
    #expect(deliveryPixel[3] == 255)
  }

  @Test
  func rec709LUTDoesNotReuseSourceColorTags() {
    let wideSource = VideoColorInfo(
      colorPrimaries: AVVideoColorPrimaries_ITU_R_2020,
      transferFunction: AVVideoTransferFunction_ITU_R_709_2,
      yCbCrMatrix: AVVideoYCbCrMatrix_ITU_R_2020,
      isHDR: false
    )
    let recipe = FargVideoRenderRecipe(
      document: emptyDocument,
      motionBlur: .disabled,
      lutOutputColorSpace: .rec709
    )

    #expect(
      recipe.resolveOutputColorInfo(sourceColorInfo: wideSource)
        == .sdrRec709
    )
  }

  @Test
  func passThroughRecipePreservesNonHDRSourceColorTags() {
    let displayP3Source = VideoColorInfo(
      colorPrimaries: AVVideoColorPrimaries_P3_D65,
      transferFunction: AVVideoTransferFunction_ITU_R_709_2,
      yCbCrMatrix: AVVideoYCbCrMatrix_ITU_R_709_2,
      isHDR: false
    )
    let recipe = FargVideoRenderRecipe(
      document: emptyDocument,
      motionBlur: .disabled
    )

    #expect(
      recipe.resolveOutputColorInfo(sourceColorInfo: displayP3Source)
        == displayP3Source
    )
  }

  @Test
  func passThroughHDRUsesCurrentSDRRenderingContract() {
    let hlgSource = VideoColorInfo(
      colorPrimaries: AVVideoColorPrimaries_ITU_R_2020,
      transferFunction: AVVideoTransferFunction_ITU_R_2100_HLG,
      yCbCrMatrix: AVVideoYCbCrMatrix_ITU_R_2020,
      isHDR: true
    )
    let recipe = FargVideoRenderRecipe(
      document: emptyDocument,
      motionBlur: .disabled
    )

    #expect(
      recipe.resolveOutputColorInfo(sourceColorInfo: hlgSource)
        == .sdrRec709
    )
  }
}
