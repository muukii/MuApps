import CaptureAudio
import Foundation
import JournalVault
import Testing

@testable import Tinycurve

@MainActor
struct AudioWaveformDraftTests {

  @Test
  func vaultDraft_encodesCapturedWaveformIntoAudioResource() throws {
    let waveform = AudioWaveform(
      normalizedLevels: [0, 0.5, 1],
      sampleInterval: 0.05
    )
    let snapshot = CardEditDraftSnapshot(
      kind: .audio,
      text: "",
      completedAt: nil,
      photo: nil,
      video: nil,
      livePhoto: nil,
      audio: AudioRecording(
        fileURL: URL(filePath: "/tmp/audio.m4a"),
        duration: 1,
        waveform: waveform
      ),
      suggestion: nil,
      suggestionMediaFileURLsByResourceID: [:],
      doodle: nil,
      bauhaus: nil,
      location: nil
    )

    let draft = try snapshot.vaultDraft()
    let resource = try #require(draft.mediaResources.first)
    let waveformData = try #require(resource.waveformData)

    #expect(resource.role == .audio)
    #expect(AudioWaveform.decode(from: waveformData) == waveform)
  }
}
