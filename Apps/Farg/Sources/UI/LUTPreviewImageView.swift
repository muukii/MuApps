//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//

import SwiftUI

/// Displays one lazily rendered LUT result for a fixed source still.
struct LUTPreviewImageView: View {

  let source: LUTPreviewSourceImage?
  let lut: LUT?
  let library: LUTLibrary
  let exposure: ExposureAdjustment
  @Environment(LUTPreviewModelStore.self) private var previewModels

  init(
    source: LUTPreviewSourceImage?,
    lut: LUT?,
    library: LUTLibrary,
    exposure: ExposureAdjustment = .neutral
  ) {
    self.source = source
    self.lut = lut
    self.library = library
    self.exposure = exposure
  }

  var body: some View {
    
    Color.clear.overlay { 
      ZStack {

        if let renderedImage = previewModel.image(for: requestID) {
          Image(decorative: renderedImage, scale: 1)
            .resizable()
            .aspectRatio(contentMode: .fill)
        } else if let source, lut == nil, exposure.isNeutral {
          Image(decorative: source.image, scale: 1)
            .resizable()
            .aspectRatio(contentMode: .fill)
        } else if source == nil {
          Image(systemName: "photo")
            .font(.title2)
            .foregroundStyle(.tertiary)
        } else if previewModel.didFail(requestID: requestID) {
          Image(systemName: "exclamationmark.triangle")
            .font(.title3)
            .foregroundStyle(.secondary)
        } else {
          ProgressView()
            .controlSize(.small)
        }
        
      }
    }
    .background(content: { 
      Color.secondary.opacity(0.12)
    })
    .clipped()
    .task(id: taskID) {
      await requestPreview()
    }
    .onDisappear {
      previewModel.disappear()
    }
  }

  private var requestID: LUTPreviewRequestID {
    LUTPreviewRequestID(
      sourceID: source?.id ?? "missing-source",
      itemID: itemID,
      libraryRevision: library.revision,
      exposureEV: exposure.ev
    )
  }

  private var taskID: LUTPreviewViewTaskID {
    LUTPreviewViewTaskID(
      requestID: requestID,
      modelID: ObjectIdentifier(previewModel)
    )
  }

  private var itemID: LUTPreviewItemID {
    lut.map { .lut($0.id) } ?? .original
  }

  private var previewModel: LUTPreviewModel {
    previewModels.model(for: itemID)
  }

  private func requestPreview() async {
    guard let source else { return }
    guard lut != nil || exposure.isNeutral == false else { return }

    // A short cancellation window prevents slider ticks from starting a full
    // visible-cell rerender before the authored EV settles.
    do {
      try await Task.sleep(for: .milliseconds(120))
    } catch {
      return
    }
    guard Task.isCancelled == false else { return }

    do {
      let recipe: LUTPreviewRecipe?
      if let lut {
        recipe = try library.previewRecipe(for: lut)
      } else {
        recipe = nil
      }
      previewModel.appear(
        requestID: requestID,
        source: source,
        recipe: recipe,
        exposure: exposure
      )
    } catch {
      previewModel.fail(requestID: requestID)
    }
  }
}

/// Restarts cell lifecycle work if catalog synchronization replaces its model.
private struct LUTPreviewViewTaskID: Hashable {

  var requestID: LUTPreviewRequestID
  var modelID: ObjectIdentifier
}

#Preview {
  LUTPreviewImageView(
    source: LUTPreviewSampleLibrary.makePreviewSource(),
    lut: nil,
    library: LUTLibrary()
  )
  .environment(LUTPreviewModelStore())
  .padding(50)
}
