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
      initialClips: []
    )

    model.selectedLUTID = "lut-a"
    model.selectedLUTID = "lut-b"

    #expect(model.selectedLUTID == "lut-b")
  }

  @Test
  func reconciliationClearsMissingSelection() {
    let model = EditorViewModel(
      library: LUTLibrary(),
      defaultVideoFolder: DefaultVideoFolderStore(),
      previewSamples: LUTPreviewSampleLibrary(),
      initialClips: []
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
      initialClips: []
    )
    let second = EditorViewModel(
      library: library,
      defaultVideoFolder: defaultVideoFolder,
      previewSamples: previewSamples,
      initialClips: []
    )

    first.exposure = ExposureAdjustment(ev: 0.5)

    #expect(first !== second)
    #expect(first.id == ObjectIdentifier(first))
    #expect(second.id == ObjectIdentifier(second))
    #expect(first.exposure.ev == 0.5)
    #expect(second.exposure.isNeutral)
    #expect(first.preview !== second.preview)
  }
}
