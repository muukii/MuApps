//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//

import BrightroomParametric
import FargMotionBlur
import Foundation
import StateGraph

/// Owns the authored state and long-lived collaborators for one Editor session.
///
/// `RootView` creates a new instance whenever the full-screen Editor is opened
/// and releases it when that presentation ends. The class uses `Identifiable`'s
/// default `ObjectIdentifier` identity, so presentation identity follows the
/// lifetime of this exact session object.
///
/// Application-scoped services are injected into the session but are not owned
/// by it. Authored values are separate graph nodes so each consumer observes
/// only the state it reads. `makeRenderRecipe()` is the single boundary that
/// snapshots those values for preview and batch export.
@MainActor
final class EditorViewModel: GraphObject, Identifiable {

  /// Intensities at or below this value omit the LUT from the recipe.
  private static let minimumAmount = 0.001

  /// Application-scoped LUT metadata and materialization cache.
  let library: LUTLibrary

  /// Application-scoped Files import preference.
  let defaultVideoFolder: DefaultVideoFolderStore

  /// Application-scoped sample sources used by Settings.
  let previewSamples: LUTPreviewSampleLibrary

  /// Preview subsystem whose lifecycle is limited to this editor session.
  let preview = VideoPreviewModel()

  /// LUT still-image cache whose lifecycle is limited to this editor session.
  let lutPreviewModels = LUTPreviewModelStore()

  /// Videos in picker order. Each clip owns its source-specific color metadata.
  @GraphStored private(set) var clips: [VideoClip] = []

  /// The clip currently shown by the preview.
  @GraphStored private(set) var selectedClipID: VideoClip.ID? = nil

  /// Stable identifier of the selected LUT. `nil` means no LUT.
  @GraphStored var selectedLUTID: LUT.ID? = nil

  /// LUT intensity, where zero is the original image and one is the full LUT.
  @GraphStored var amount: Double = 1

  /// Exposure offset evaluated before the selected LUT.
  @GraphStored var exposure: ExposureAdjustment = .neutral

  /// Optical Flow motion blur shared by every clip in the collection.
  @GraphStored var motionBlur: MotionBlurSettings = .disabled

  /// Identity-stable film-grain node shared by every clip in the collection.
  @GraphStored var grain: FilmGrainFeature = FilmGrainFeature(
    id: FeatureID(rawValue: "farg.film-grain")
  )

  /// Whether the session contains at least one video.
  var hasVideos: Bool { clips.isEmpty == false }

  /// Whether any imported source is still resolving its media content.
  var isPreparingClips: Bool {
    clips.contains(where: \.isPreparing)
  }

  /// Clips whose media content is ready for preview or export.
  var readyClips: [VideoClip] {
    clips.filter(\.isReady)
  }

  /// The selected clip, or the first clip if no explicit selection exists.
  var selectedClip: VideoClip? {
    guard let selectedClipID else { return clips.first }
    return clips.first { $0.id == selectedClipID }
  }

  /// The selected clip's current position in picker order.
  var selectedClipIndex: Int? {
    guard let selectedClipID else { return nil }
    return clips.firstIndex { $0.id == selectedClipID }
  }

  /// Number of clips whose resolved content uses an HDR source color space.
  var hdrVideoCount: Int {
    clips.count { $0.content?.colorInfo.isHDR == true }
  }

  init(
    library: LUTLibrary,
    defaultVideoFolder: DefaultVideoFolderStore,
    previewSamples: LUTPreviewSampleLibrary,
    initialClips: [VideoClip],
    initialSelectedLUTID: LUT.ID? = nil
  ) {
    self.library = library
    self.defaultVideoFolder = defaultVideoFolder
    self.previewSamples = previewSamples
    self.clips = initialClips
    self.selectedClipID = initialClips.first?.id
    self.selectedLUTID = initialSelectedLUTID.flatMap { id in
      library.lut(id: id)?.id
    }
  }

  /// Adds videos without disturbing the clip currently being evaluated.
  func append(clips newClips: [VideoClip]) {
    guard newClips.isEmpty == false else { return }
    let shouldSelectFirstClip = clips.isEmpty
    clips.append(contentsOf: newClips)
    if shouldSelectFirstClip {
      selectedClipID = newClips[0].id
    }
  }

  /// Selects a clip only when it belongs to this editor session.
  func selectClip(id: VideoClip.ID) {
    guard clips.contains(where: { $0.id == id }) else { return }
    selectedClipID = id
  }

  /// Removes one clip and keeps selection on the nearest surviving neighbor.
  func removeClip(id: VideoClip.ID) {
    guard let removedIndex = clips.firstIndex(where: { $0.id == id }) else {
      return
    }
    let wasSelected = selectedClipID == id
    clips.remove(at: removedIndex)

    guard clips.isEmpty == false else {
      selectedClipID = nil
      return
    }
    if wasSelected {
      selectedClipID = clips[min(removedIndex, clips.count - 1)].id
    }
  }

  /// Removes unresolved clips belonging to one cancelled or failed import.
  func removeClips(ids: Set<VideoClip.ID>) {
    guard ids.isEmpty == false else { return }
    let selectedID = selectedClipID
    clips.removeAll { ids.contains($0.id) }

    if let selectedID, ids.contains(selectedID) {
      selectedClipID = clips.first?.id
    }
  }

  /// Clears a selection whose LUT was removed by a library revision.
  func reconcileSelectedLUT() {
    if let selectedLUTID, library.lut(id: selectedLUTID) == nil {
      self.selectedLUTID = nil
    }
  }

  /// Snapshots the complete render recipe used by preview and export.
  func makeRenderRecipe() throws -> FargVideoRenderRecipe {
    let lutOutputColorSpace: FargLUTOutputColorSpace? =
      selectedLUTID.flatMap(library.lut(id:)) != nil
        && amount > Self.minimumAmount
      ? .rec709
      : nil
    return FargVideoRenderRecipe(
      document: try makeDocument(),
      motionBlur: motionBlur,
      lutOutputColorSpace: lutOutputColorSpace
    )
  }

  /// Compiles the current spatial adjustments in their evaluation order.
  ///
  /// Exposure is evaluated before the selected LUT so it changes the LUT's
  /// input response. The identity-stable film-grain feature follows both.
  private func makeDocument() throws -> EditingDocument {
    var features: [MainFeature] = [
      .effect(exposure.feature)
    ]
    // A zero-strength LUT contributes nothing. Omitting it also avoids
    // materializing and evaluating an otherwise null color cube.
    if let selectedLUTID,
      let lut = library.lut(id: selectedLUTID),
      amount > Self.minimumAmount
    {
      let feature = try library.feature(for: lut, amount: amount)
      features.append(.effect(feature))
    }
    features.append(.effect(grain))
    return EditingDocument(mainTree: MainTree(features: features))
  }
}
