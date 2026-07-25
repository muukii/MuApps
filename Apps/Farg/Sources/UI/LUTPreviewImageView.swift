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
