import AVFoundation
import CoreGraphics
import CoreMedia
import Testing

@testable import Farg

/// Verifies the source geometry and codec labels presented by Video Information.
@Suite("Video metadata")
struct VideoMetadataTests {

  @Test
  func presentationDimensionsApplyPortraitTrackTransform() {
    let dimensions = VideoMetadata.presentationDimensions(
      naturalSize: CGSize(width: 3_840, height: 2_160),
      preferredTransform: CGAffineTransform(
        a: 0,
        b: 1,
        c: -1,
        d: 0,
        tx: 2_160,
        ty: 0
      )
    )

    #expect(
      dimensions
        == VideoMetadata.PixelDimensions(width: 2_160, height: 3_840)
    )
  }

  @Test
  func presentationDimensionsRejectInvalidSourceGeometry() {
    #expect(
      VideoMetadata.presentationDimensions(
        naturalSize: CGSize(width: 0, height: 1_080),
        preferredTransform: .identity
      ) == nil
    )
  }

  @Test
  func commonCodecNamesAreRecognizable() {
    #expect(
      VideoMetadata.codecDisplayName(for: kCMVideoCodecType_H264)
        == "H.264"
    )
    #expect(
      VideoMetadata.codecDisplayName(for: kCMVideoCodecType_HEVC)
        == "HEVC (H.265)"
    )
  }

  @Test
  func dynamicRangeUsesExplicitSourceTransferMetadata() {
    let hdr = VideoMetadata.ColorMetadata(
      colorPrimaries: AVVideoColorPrimaries_ITU_R_2020,
      transferFunction: AVVideoTransferFunction_ITU_R_2100_HLG,
      logTransferFunction: nil,
      yCbCrMatrix: AVVideoYCbCrMatrix_ITU_R_2020
    )
    let log = VideoMetadata.ColorMetadata(
      colorPrimaries: AVVideoColorPrimaries_ITU_R_2020,
      transferFunction: AVVideoTransferFunction_ITU_R_709_2,
      logTransferFunction:
        kCMFormatDescriptionLogTransferFunction_AppleLog as String,
      yCbCrMatrix: AVVideoYCbCrMatrix_ITU_R_2020
    )

    #expect(hdr.dynamicRange == .hdr)
    #expect(log.dynamicRange == .log)
  }
}
