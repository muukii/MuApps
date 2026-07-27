//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//

@preconcurrency import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation

/// Technical metadata read from the primary video track for display in the editor.
///
/// Values are optional because playable assets can omit nominal timing or format
/// estimates. The source remains authoritative; Färg does not infer missing
/// values from the current preview or export recipe.
nonisolated struct VideoMetadata: Equatable, Sendable {

  /// Display-oriented pixel dimensions after applying the track transform.
  struct PixelDimensions: Equatable, Sendable {
    let width: Int
    let height: Int
  }

  /// Source color tags read without applying Färg's fallback output contract.
  struct ColorMetadata: Equatable, Sendable {

    /// The broad transfer category explicitly described by the source.
    enum DynamicRange: Equatable, Sendable {
      case sdr
      case hdr
      case log
    }

    let colorPrimaries: String?
    let transferFunction: String?
    let logTransferFunction: String?
    let yCbCrMatrix: String?

    var dynamicRange: DynamicRange? {
      if logTransferFunction != nil {
        return .log
      }
      switch transferFunction {
      case AVVideoTransferFunction_ITU_R_2100_HLG,
        AVVideoTransferFunction_SMPTE_ST_2084_PQ:
        return .hdr
      case .some:
        return .sdr
      case nil:
        return nil
      }
    }
  }

  let durationSeconds: Double?
  let pixelDimensions: PixelDimensions?
  let nominalFrameRate: Double?
  let codecName: String?
  let estimatedBitRate: Double?
  let colorMetadata: ColorMetadata

  /// Reads lightweight movie properties without decoding media samples.
  static func load(from asset: AVAsset) async throws -> VideoMetadata {
    guard let videoTrack = try await asset.loadTracks(withMediaType: .video).first else {
      throw VideoMetadataError.videoTrackUnavailable
    }

    let duration = try? await asset.load(.duration)
    try Task.checkCancellation()
    let naturalSize = try? await videoTrack.load(.naturalSize)
    try Task.checkCancellation()
    let preferredTransform = try? await videoTrack.load(.preferredTransform)
    try Task.checkCancellation()
    let nominalFrameRate = try? await videoTrack.load(.nominalFrameRate)
    try Task.checkCancellation()
    let estimatedDataRate = try? await videoTrack.load(.estimatedDataRate)
    try Task.checkCancellation()
    let formatDescriptions = try? await videoTrack.load(.formatDescriptions)
    try Task.checkCancellation()

    return VideoMetadata(
      durationSeconds: positiveFiniteValue(duration?.seconds),
      pixelDimensions: presentationDimensions(
        naturalSize: naturalSize,
        preferredTransform: preferredTransform
      ),
      nominalFrameRate: positiveFiniteValue(nominalFrameRate.map(Double.init)),
      codecName: formatDescriptions?.first.map {
        codecDisplayName(
          for: CMFormatDescriptionGetMediaSubType($0)
        )
      },
      estimatedBitRate: positiveFiniteValue(estimatedDataRate.map(Double.init)),
      colorMetadata: colorMetadata(from: formatDescriptions?.first)
    )
  }

  /// Resolves encoded dimensions into the orientation a person sees in playback.
  static func presentationDimensions(
    naturalSize: CGSize?,
    preferredTransform: CGAffineTransform?
  ) -> PixelDimensions? {
    guard
      let naturalSize,
      naturalSize.width.isFinite,
      naturalSize.height.isFinite,
      naturalSize.width > 0,
      naturalSize.height > 0
    else {
      return nil
    }

    let transformedRect = CGRect(
      origin: .zero,
      size: naturalSize
    ).applying(preferredTransform ?? .identity)
    let width = abs(transformedRect.width)
    let height = abs(transformedRect.height)
    guard
      width.isFinite,
      height.isFinite,
      width > 0,
      height > 0
    else {
      return nil
    }

    return PixelDimensions(
      width: Int(width.rounded()),
      height: Int(height.rounded())
    )
  }

  /// Gives common camera codecs a recognizable name while retaining unknown FourCCs.
  static func codecDisplayName(for mediaSubType: FourCharCode) -> String {
    let fourCharacterCode = fourCharacterCodeString(mediaSubType)
    switch fourCharacterCode {
    case "avc1", "avc3":
      return "H.264"
    case "hvc1", "hev1":
      return "HEVC (H.265)"
    case "ap4x":
      return "Apple ProRes 4444 XQ"
    case "ap4h":
      return "Apple ProRes 4444"
    case "apch":
      return "Apple ProRes 422 HQ"
    case "apcn":
      return "Apple ProRes 422"
    case "apcs":
      return "Apple ProRes 422 LT"
    case "apco":
      return "Apple ProRes 422 Proxy"
    case "aprh":
      return "Apple ProRes RAW HQ"
    case "aprn":
      return "Apple ProRes RAW"
    default:
      return fourCharacterCode
    }
  }

  private static func positiveFiniteValue(_ value: Double?) -> Double? {
    guard let value, value.isFinite, value > 0 else { return nil }
    return value
  }

  private static func colorMetadata(
    from formatDescription: CMFormatDescription?
  ) -> ColorMetadata {
    func extensionValue(_ key: CFString) -> String? {
      guard let formatDescription else { return nil }
      return CMFormatDescriptionGetExtension(
        formatDescription,
        extensionKey: key
      ) as? String
    }

    return ColorMetadata(
      colorPrimaries: extensionValue(
        kCMFormatDescriptionExtension_ColorPrimaries
      ),
      transferFunction: extensionValue(
        kCMFormatDescriptionExtension_TransferFunction
      ),
      logTransferFunction: extensionValue(
        kCMFormatDescriptionExtension_LogTransferFunction
      ),
      yCbCrMatrix: extensionValue(
        kCMFormatDescriptionExtension_YCbCrMatrix
      )
    )
  }

  private static func fourCharacterCodeString(_ code: FourCharCode) -> String {
    let bytes = [
      UInt8(truncatingIfNeeded: code >> 24),
      UInt8(truncatingIfNeeded: code >> 16),
      UInt8(truncatingIfNeeded: code >> 8),
      UInt8(truncatingIfNeeded: code),
    ]
    guard
      bytes.allSatisfy({ $0 >= 0x20 && $0 <= 0x7E }),
      let string = String(bytes: bytes, encoding: .ascii)
    else {
      return "0x\(String(code, radix: 16, uppercase: true))"
    }
    return string
  }
}

/// Failures that prevent the editor from presenting technical movie information.
private nonisolated enum VideoMetadataError: LocalizedError, Sendable {
  case videoTrackUnavailable

  var errorDescription: String? {
    switch self {
    case .videoTrackUnavailable:
      return String(localized: "The video track is no longer available.")
    }
  }
}
