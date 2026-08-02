//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//

@preconcurrency import AVFoundation
import CoreMedia
import SwiftUI

/// Presents source and technical information for one editor video selection.
struct VideoInformationView: View {

  let displayName: String
  let source: VideoSource

  @Environment(\.dismiss) private var dismiss
  @State private var metadataLoadState = VideoMetadataLoadState.loading
  @State private var metadataLoadRequestID = UUID()

  var body: some View {
    NavigationStack {
      List {
        VideoInformationIdentitySection(
          displayName: displayName,
          sourceName: source.informationSourceName
        )

        switch metadataLoadState {
        case .loading:
          VideoInformationLoadingSection()

        case .loaded(let metadata):
          VideoInformationTechnicalSection(metadata: metadata)
          VideoInformationColorSection(
            colorMetadata: metadata.colorMetadata
          )

        case .failed(let message):
          VideoInformationFailureSection(
            message: message,
            onRetry: { metadataLoadRequestID = UUID() }
          )
        }
      }
      .navigationTitle("Video Information")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .confirmationAction) {
          Button("Done") {
            dismiss()
          }
        }
      }
    }
    .presentationDetents([.medium, .large])
    .task(id: metadataLoadRequestID) {
      await loadMetadata()
    }
  }

  private func loadMetadata() async {
    metadataLoadState = .loading

    do {
      let metadata = try await VideoMetadata.load(from: source.asset)
      try Task.checkCancellation()
      metadataLoadState = .loaded(metadata)
    } catch is CancellationError {
      return
    } catch {
      metadataLoadState = .failed(
        message: String(localized: "Färg couldn't read this video's metadata.")
      )
    }
  }
}

/// The mutually exclusive states of the sheet's lazy AVFoundation read.
private enum VideoMetadataLoadState: Equatable {
  case loading
  case loaded(VideoMetadata)
  case failed(message: String)
}

/// Identifies the selected clip without exposing its backing path or identifier.
private struct VideoInformationIdentitySection: View {

  let displayName: String
  let sourceName: LocalizedStringResource

  var body: some View {
    Section("Selected Video") {
      LabeledContent("Name") {
        Text(displayName)
          .multilineTextAlignment(.trailing)
      }

      LabeledContent("Source") {
        Text(sourceName)
      }
    }
  }
}

/// Reserves the technical section while AVFoundation resolves its properties.
private struct VideoInformationLoadingSection: View {

  var body: some View {
    Section("Video") {
      HStack(spacing: 10) {
        ProgressView()
        Text("Reading metadata…")
          .foregroundStyle(.secondary)
      }
      .accessibilityElement(children: .combine)
    }
  }
}

/// Reports a transient source failure and lets the user retry in place.
private struct VideoInformationFailureSection: View {

  let message: String
  let onRetry: @MainActor @Sendable () -> Void

  var body: some View {
    Section("Video") {
      Label {
        Text(message)
      } icon: {
        Image(systemName: "exclamationmark.triangle")
          .foregroundStyle(.orange)
      }

      Button("Try Again", action: onRetry)
    }
  }
}

/// Displays track properties that describe the selected source rather than export.
private struct VideoInformationTechnicalSection: View {

  let metadata: VideoMetadata

  var body: some View {
    Section("Video") {
      LabeledContent("Duration") {
        if let seconds = metadata.durationSeconds {
          let duration = Duration.seconds(seconds)
          if seconds >= 3_600 {
            Text(
              duration,
              format: .time(pattern: .hourMinuteSecond)
            )
            .monospacedDigit()
          } else {
            Text(
              duration,
              format: .time(pattern: .minuteSecond)
            )
            .monospacedDigit()
          }
        } else {
          UnavailableMetadataValue()
        }
      }

      LabeledContent("Resolution") {
        if let dimensions = metadata.pixelDimensions {
          Text("\(dimensions.width) × \(dimensions.height)")
            .monospacedDigit()
        } else {
          UnavailableMetadataValue()
        }
      }

      LabeledContent("Frame Rate") {
        if let frameRate = metadata.nominalFrameRate {
          Text(
            "\(frameRate, format: .number.precision(.fractionLength(0...3))) fps"
          )
          .monospacedDigit()
        } else {
          UnavailableMetadataValue()
        }
      }

      LabeledContent("Codec") {
        if let codecName = metadata.codecName {
          Text(codecName)
        } else {
          UnavailableMetadataValue()
        }
      }

      LabeledContent("Estimated Bitrate") {
        if let bitRate = metadata.estimatedBitRate {
          Text(
            "\(bitRate / 1_000_000, format: .number.precision(.fractionLength(0...2))) Mbps"
          )
          .monospacedDigit()
        } else {
          UnavailableMetadataValue()
        }
      }
    }
  }
}

/// Displays source color tags independently from Färg's current output recipe.
private struct VideoInformationColorSection: View {

  let colorMetadata: VideoMetadata.ColorMetadata

  var body: some View {
    Section("Color") {
      LabeledContent("Dynamic Range") {
        if let dynamicRangeName = colorMetadata.informationDynamicRangeName {
          Text(dynamicRangeName)
        } else {
          UnavailableMetadataValue()
        }
      }

      LabeledContent("Color Primaries") {
        if let colorPrimariesName = colorMetadata.informationColorPrimariesName {
          Text(colorPrimariesName)
        } else {
          UnavailableMetadataValue()
        }
      }

      LabeledContent("Transfer Function") {
        if let transferFunctionName = colorMetadata.informationTransferFunctionName {
          Text(transferFunctionName)
        } else {
          UnavailableMetadataValue()
        }
      }

      LabeledContent("YCbCr Matrix") {
        if let yCbCrMatrixName = colorMetadata.informationYCbCrMatrixName {
          Text(yCbCrMatrixName)
        } else {
          UnavailableMetadataValue()
        }
      }
    }
  }
}

/// Gives omitted or invalid source values a consistent secondary treatment.
private struct UnavailableMetadataValue: View {

  var body: some View {
    Text("Unavailable")
      .foregroundStyle(.secondary)
  }
}

extension VideoSource {

  fileprivate var informationSourceName: LocalizedStringResource {
    switch origin {
    case .photoLibrary:
      return "Photos"
    case .securityScopedFile:
      return "Files"
    case .appOwnedFile:
      return "Färg"
    }
  }
}

extension VideoMetadata.ColorMetadata {

  fileprivate var informationDynamicRangeName: String? {
    switch dynamicRange {
    case .sdr:
      return "SDR"
    case .hdr:
      return "HDR"
    case .log:
      return "Log"
    case nil:
      return nil
    }
  }

  fileprivate var informationColorPrimariesName: String? {
    switch colorPrimaries {
    case AVVideoColorPrimaries_ITU_R_709_2:
      return "Rec. 709"
    case AVVideoColorPrimaries_P3_D65:
      return "Display P3"
    case AVVideoColorPrimaries_ITU_R_2020:
      return "Rec. 2020"
    case .some(let value):
      return value
    case nil:
      return nil
    }
  }

  fileprivate var informationTransferFunctionName: String? {
    if let logTransferFunction {
      if logTransferFunction
        == (kCMFormatDescriptionLogTransferFunction_AppleLog as String)
      {
        return "Apple Log"
      }
      return logTransferFunction
    }

    switch transferFunction {
    case AVVideoTransferFunction_ITU_R_709_2:
      return "Rec. 709"
    case AVVideoTransferFunction_ITU_R_2100_HLG:
      return "HLG"
    case AVVideoTransferFunction_SMPTE_ST_2084_PQ:
      return "PQ"
    case .some(let value):
      return value
    case nil:
      return nil
    }
  }

  fileprivate var informationYCbCrMatrixName: String? {
    switch yCbCrMatrix {
    case AVVideoYCbCrMatrix_ITU_R_709_2:
      return "Rec. 709"
    case AVVideoYCbCrMatrix_ITU_R_2020:
      return "Rec. 2020"
    case AVVideoYCbCrMatrix_ITU_R_601_4:
      return "Rec. 601"
    case .some(let value):
      return value
    case nil:
      return nil
    }
  }
}
