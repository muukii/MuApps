//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//

import SwiftUI

/// Displays one lazily rendered LUT result for a fixed source still.
struct LUTPreviewImageView: View {

  let source: LUTPreviewSourceImage?
  let lut: LUT?
  let library: LUTLibrary
  @Environment(LUTPreviewModelStore.self) private var previewModels

  var body: some View {
    ZStack {
      Color.secondary.opacity(0.12)

      if let renderedImage = previewModel?.image(for: requestID) {
        Image(decorative: renderedImage, scale: 1)
          .resizable()
          .scaledToFill()
      } else if let source, lut == nil {
        Image(decorative: source.image, scale: 1)
          .resizable()
          .scaledToFill()
      } else if source == nil {
        Image(systemName: "photo")
          .font(.title2)
          .foregroundStyle(.tertiary)
      } else if previewModel?.didFail(requestID: requestID) == true {
        Image(systemName: "exclamationmark.triangle")
          .font(.title3)
          .foregroundStyle(.secondary)
      } else {
        ProgressView()
          .controlSize(.small)
      }
    }
    .clipped()
    .task(id: taskID) {
      requestPreview()
    }
    .onDisappear {
      previewModel?.disappear()
    }
  }

  private var requestID: LUTPreviewRequestID {
    LUTPreviewRequestID(
      sourceID: source?.id ?? "missing-source",
      lutID: lut?.id ?? "original",
      libraryRevision: library.revision
    )
  }

  private var taskID: LUTPreviewViewTaskID {
    LUTPreviewViewTaskID(
      requestID: requestID,
      modelID: previewModel.map(ObjectIdentifier.init)
    )
  }

  private var previewModel: LUTPreviewModel? {
    lut.map { previewModels.model(for: $0.id) }
  }

  private func requestPreview() {
    guard
      let source,
      let lut,
      let previewModel
    else {
      return
    }
    do {
      previewModel.appear(
        requestID: requestID,
        source: source,
        recipe: try library.previewRecipe(for: lut)
      )
    } catch {
      previewModel.fail(requestID: requestID)
    }
  }
}

/// Restarts cell lifecycle work if catalog synchronization replaces its model.
private struct LUTPreviewViewTaskID: Hashable {

  var requestID: LUTPreviewRequestID
  var modelID: ObjectIdentifier?
}

/// Shows the shared input and one LUT output side by side in Settings.
struct LUTPreviewComparisonView: View {

  let source: LUTPreviewSourceImage?
  let sourceLabel: String
  let lut: LUT
  let library: LUTLibrary

  var body: some View {
    GeometryReader { proxy in
      let paneWidth = max((proxy.size.width - 1) / 2, 0)

      HStack(spacing: 1) {
        previewPane(label: sourceLabel) {
          LUTPreviewImageView(
            source: source,
            lut: nil,
            library: library
          )
        }
        .frame(width: paneWidth, height: proxy.size.height)

        previewPane(label: "Result") {
          LUTPreviewImageView(
            source: source,
            lut: lut,
            library: library
          )
        }
        .frame(width: paneWidth, height: proxy.size.height)
      }
    }
    .frame(maxWidth: .infinity)
    .aspectRatio(2.15, contentMode: .fit)
    .background(Color.black)
    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
  }

  private func previewPane<Content: View>(
    label: String,
    @ViewBuilder content: @escaping () -> Content
  ) -> some View {
    GeometryReader { proxy in
      ZStack(alignment: .bottomLeading) {
        content()
          .frame(
            width: proxy.size.width,
            height: proxy.size.height
          )

        Text(label)
          .font(.caption2.weight(.semibold))
          .lineLimit(1)
          .padding(.horizontal, 6)
          .padding(.vertical, 4)
          .foregroundStyle(.white)
          .background(.black.opacity(0.64))
      }
    }
    .clipped()
  }
}
