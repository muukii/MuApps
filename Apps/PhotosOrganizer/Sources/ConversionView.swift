import Photos
import SwiftUI

struct ConversionView: View {

  let asset: PHAsset
  let originalSize: Int64?

  @State private var format: ConversionFormat = .heif {
    didSet { result = nil }
  }
  @State private var quality: Double = 0.5
  @State private var result: ConversionResult?
  @State private var isConverting = false
  @State private var isSaving = false
  @State private var error: String?
  @State private var saved = false

  @Environment(\.dismiss) private var dismiss

  private let converter = ImageConverter()

  var body: some View {
    NavigationStack {
      Form {
        Section("Original") {
          if let originalSize {
            LabeledContent("Size", value: formatFileSize(originalSize))
          }
          LabeledContent("Dimensions", value: "\(asset.pixelWidth) × \(asset.pixelHeight)")
        }

        Section("Conversion Settings") {
          Picker("Format", selection: $format) {
            ForEach(ConversionFormat.allCases) { fmt in
              Text(fmt.rawValue).tag(fmt)
            }
          }

          VStack(alignment: .leading) {
            LabeledContent("Quality", value: "\(Int(quality * 100))%")
            Slider(value: $quality, in: 0.1...0.85, step: 0.05)
          }
          if quality >= 0.8 {
            Text("High quality values may produce larger files than the original")
              .font(.caption)
              .foregroundStyle(.secondary)
          }
        }

        Section {
          Button {
            Task { await preview() }
          } label: {
            if isConverting {
              ProgressView()
                .frame(maxWidth: .infinity)
            } else {
              Text("Preview Conversion")
                .frame(maxWidth: .infinity)
            }
          }
          .disabled(isConverting)
        }

        if let result {
          Section("Result") {
            LabeledContent("Converted Size", value: formatFileSize(result.convertedSize))
            LabeledContent("Saved", value: formatFileSize(result.savedBytes))
            LabeledContent(
              "Reduction",
              value: String(format: "%.1f%%", result.savedPercentage)
            )

            Button {
              Task { await save(data: result.convertedData) }
            } label: {
              if isSaving {
                ProgressView()
                  .frame(maxWidth: .infinity)
              } else {
                Label("Save to Photos", systemImage: "square.and.arrow.down")
                  .frame(maxWidth: .infinity)
              }
            }
            .disabled(isSaving)
          }
        }

        if saved {
          Section {
            Label("Saved successfully", systemImage: "checkmark.circle.fill")
              .foregroundStyle(.green)
          }
        }

        if let error {
          Section {
            Text(error)
              .foregroundStyle(.red)
          }
        }
      }
      .navigationTitle("Convert")
      .navigationBarTitleDisplayMode(.inline)
      .toolbar {
        ToolbarItem(placement: .cancellationAction) {
          Button("Close") { dismiss() }
        }
      }
    }
  }

  private func preview() async {
    isConverting = true
    error = nil
    result = nil

    do {
      let originalData = try await converter.loadOriginalData(for: asset)
      let convertedData = try await converter.convert(
        imageData: originalData,
        to: format,
        quality: quality
      )
      result = ConversionResult(
        originalSize: Int64(originalData.count),
        convertedSize: Int64(convertedData.count),
        convertedData: convertedData
      )
    } catch {
      self.error = error.localizedDescription
    }

    isConverting = false
  }

  private func save(data: Data) async {
    isSaving = true
    error = nil

    do {
      try await converter.saveToPhotoLibrary(data: data, originalAsset: asset)
      saved = true
    } catch {
      self.error = error.localizedDescription
    }

    isSaving = false
  }
}
