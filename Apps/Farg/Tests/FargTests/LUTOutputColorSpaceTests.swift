import AVFoundation
import BrightroomParametric
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
