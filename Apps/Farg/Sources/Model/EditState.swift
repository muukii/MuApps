//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//

import BrightroomParametric
import FargMotionBlur
import Foundation

/// The edit being authored: an ordered video collection plus one shared
/// parametric feature stack.
///
/// `makeRenderRecipe(using:)` is the single place the UI turns selections into
/// an immutable single-frame document plus temporal settings, so every clip
/// uses the same recipe during preview and batch export.
@MainActor
@Observable
final class EditState {

  /// Videos in picker order. Each clip owns its source-specific color metadata.
  private(set) var clips: [VideoClip] = []

  /// The clip currently shown by the preview.
  var selectedClipID: VideoClip.ID?

  /// The selected LUT, or `nil` for the unmodified video.
  var selectedLUT: LUT?

  /// The LUT intensity (0 = original, 1 = full LUT).
  var amount: Double = 1.0

  /// The exposure offset applied before the selected LUT.
  var exposure = ExposureAdjustment.neutral

  /// Optical Flow motion blur shared by every clip in the current collection.
  var motionBlur = MotionBlurSettings.disabled

  /// The identity-stable film-grain node shared by every clip in the collection.
  var grain = FilmGrainFeature(
    id: FeatureID(rawValue: "farg.film-grain")
  )

  /// Intensities at or below this are treated as "no effect".
  private static let minimumAmount = 0.001

  var hasVideos: Bool { clips.isEmpty == false }

  var isPreparingClips: Bool {
    clips.contains(where: \.isPreparing)
  }

  var readyClips: [VideoClip] {
    clips.filter(\.isReady)
  }

  var selectedClip: VideoClip? {
    guard let selectedClipID else { return clips.first }
    return clips.first { $0.id == selectedClipID }
  }

  var selectedClipIndex: Int? {
    guard let selectedClipID else { return nil }
    return clips.firstIndex { $0.id == selectedClipID }
  }

  var hdrVideoCount: Int {
    clips.count { $0.content?.colorInfo.isHDR == true }
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

  /// Replaces the collection with one externally supplied edit request.
  func replaceClips(with newClips: [VideoClip]) {
    clips = newClips
    selectedClipID = newClips.first?.id
  }

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

  func removeAllClips() {
    clips.removeAll()
    selectedClipID = nil
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

  /// Compiles the current selections into a parametric editing document.
  ///
  /// Exposure is evaluated before the selected LUT so it changes the LUT's
  /// input response. The identity-stable film-grain feature follows both.
  /// Keeping every single-frame effect in this ordered tree makes the document
  /// the complete authored spatial recipe.
  func makeDocument(using library: LUTLibrary) throws -> EditingDocument {
    var features: [MainFeature] = [
      .effect(exposure.feature)
    ]
    // Below the threshold the LUT contributes nothing, so omit its node rather
    // than evaluating a null color cube. Exposure and Grain remain authored.
    if let lut = selectedLUT, amount > Self.minimumAmount {
      let feature = try library.feature(for: lut, amount: amount)
      features.append(.effect(feature))
    }
    features.append(.effect(grain))
    return EditingDocument(mainTree: MainTree(features: features))
  }

  /// Snapshots the complete render recipe used by preview and export.
  func makeRenderRecipe(using library: LUTLibrary) throws -> FargVideoRenderRecipe {
    let lutOutputColorSpace: FargLUTOutputColorSpace? =
      selectedLUT != nil && amount > Self.minimumAmount
      ? .rec709
      : nil
    return FargVideoRenderRecipe(
      document: try makeDocument(using: library),
      motionBlur: motionBlur,
      lutOutputColorSpace: lutOutputColorSpace
    )
  }
}
