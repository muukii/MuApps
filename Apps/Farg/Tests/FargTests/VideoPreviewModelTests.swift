import AVFoundation
import Testing

@testable import Farg

/// Verifies transport state owned by the editor preview model.
@Suite("Video preview playback")
@MainActor
struct VideoPreviewModelTests {

  @Test
  func startsMutedAndKeepsMuteStateSynchronizedWithPlayer() {
    let model = VideoPreviewModel()

    #expect(model.isMuted)
    #expect(model.player.isMuted)

    model.toggleMute()

    #expect(model.isMuted == false)
    #expect(model.player.isMuted == false)

    model.toggleMute()

    #expect(model.isMuted)
    #expect(model.player.isMuted)
  }
}
