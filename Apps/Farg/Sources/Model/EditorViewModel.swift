//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//

import Foundation
import StateGraph

/// Owns the mutable state and long-lived services for one Editor presentation.
///
/// `RootView` creates a new instance whenever the full-screen Editor is opened
/// and releases it when that presentation ends. Application-scoped services,
/// such as `LUTLibrary`, are injected into the session but are not owned by it.
/// The selected LUT is represented only by its stable identifier in the graph;
/// a `LUT` value is resolved from the current library only at the render or
/// display boundary.
@MainActor
final class EditorViewModel: GraphObject, Identifiable {

  /// Identifies this presentation session, not the selected video or LUT.
  let id = UUID()

  /// Application-scoped LUT metadata and materialization cache.
  let library: LUTLibrary
  /// Application-scoped Files import preference.
  let defaultVideoFolder: DefaultVideoFolderStore
  /// Application-scoped sample sources used by Settings.
  let previewSamples: LUTPreviewSampleLibrary

  /// Existing authored editor state retained during the vertical migration.
  let editState: EditState
  /// Existing preview subsystem retained behind this session boundary.
  let preview = VideoPreviewModel()
  /// Existing LUT still-image cache retained behind this session boundary.
  let lutPreviewModels = LUTPreviewModelStore()

  /// Stable source of truth for the selected LUT. `nil` means no LUT.
  @GraphStored var selectedLUTID: LUT.ID? = nil

  init(
    library: LUTLibrary,
    defaultVideoFolder: DefaultVideoFolderStore,
    previewSamples: LUTPreviewSampleLibrary,
    editState: EditState,
    initialSelectedLUTID: LUT.ID? = nil
  ) {
    self.library = library
    self.defaultVideoFolder = defaultVideoFolder
    self.previewSamples = previewSamples
    self.editState = editState

    let selectedLUTID = initialSelectedLUTID.flatMap { id in
      library.lut(id: id)?.id
    }
    self.selectedLUTID = selectedLUTID
  }

  /// Updates the graph-owned LUT selection.
  func selectLUT(id: LUT.ID?) {
    selectedLUTID = id
  }

  /// Clears a selection whose LUT was removed by a library revision.
  func reconcileSelectedLUT() {
    if let selectedLUTID, library.lut(id: selectedLUTID) == nil {
      self.selectedLUTID = nil
    }
  }
}
