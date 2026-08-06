import Testing

@testable import Farg

@Suite("Editor LUT session state")
@MainActor
struct EditorViewModelTests {

  @Test
  func selectingAnotherLUTUpdatesTheGraphSelection() {
    let model = EditorViewModel(
      library: LUTLibrary(),
      defaultVideoFolder: DefaultVideoFolderStore(),
      previewSamples: LUTPreviewSampleLibrary(),
      editState: EditState()
    )

    model.selectLUT(id: "lut-a")
    model.selectLUT(id: "lut-b")

    #expect(model.selectedLUTID == "lut-b")
  }

  @Test
  func reconciliationClearsMissingSelection() {
    let model = EditorViewModel(
      library: LUTLibrary(),
      defaultVideoFolder: DefaultVideoFolderStore(),
      previewSamples: LUTPreviewSampleLibrary(),
      editState: EditState()
    )
    model.selectedLUTID = "removed-lut"

    model.reconcileSelectedLUT()

    #expect(model.selectedLUTID == nil)
  }

  @Test
  func separateEditorSessionsHaveSeparateOwnersAndAuthoredState() {
    let library = LUTLibrary()
    let defaultVideoFolder = DefaultVideoFolderStore()
    let previewSamples = LUTPreviewSampleLibrary()
    let first = EditorViewModel(
      library: library,
      defaultVideoFolder: defaultVideoFolder,
      previewSamples: previewSamples,
      editState: EditState()
    )
    let second = EditorViewModel(
      library: library,
      defaultVideoFolder: defaultVideoFolder,
      previewSamples: previewSamples,
      editState: EditState()
    )

    #expect(first.id != second.id)
    #expect(first.editState !== second.editState)
    #expect(first.preview !== second.preview)
  }
}
