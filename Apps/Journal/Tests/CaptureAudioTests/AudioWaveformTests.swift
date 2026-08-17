import Foundation
import Testing

@testable import CaptureAudio

struct AudioWaveformTests {

  @Test
  func normalizedLevels_areClampedAndQuantized() {
    let waveform = AudioWaveform(
      normalizedLevels: [-1, 0, 0.5, 1, 2],
      sampleInterval: 0.05
    )

    #expect(waveform.levels == Data([0, 0, 128, 255, 255]))
    #expect(waveform.normalizedLevels[2] == Float(128) / Float(UInt8.max))
  }

  @Test
  func encodedData_roundTripsAsVersionedJSON() throws {
    let waveform = AudioWaveform(
      normalizedLevels: [0, 0.25, 1],
      sampleInterval: 0.05
    )

    let data = try waveform.encodedData()
    let decoded = try #require(AudioWaveform.decode(from: data))
    let json = try #require(
      JSONSerialization.jsonObject(with: data) as? [String: Any]
    )

    #expect(decoded == waveform)
    #expect(json["formatVersion"] as? Int == AudioWaveform.currentFormatVersion)
    #expect(json["sampleInterval"] as? Double == 0.05)
    #expect(json["levels"] is String)
  }

  @Test
  func decode_rejectsUnsupportedAndInvalidPayloads() throws {
    let unsupported = AudioWaveform(
      sampleInterval: 0.05,
      levels: Data([1, 2, 3]),
      formatVersion: AudioWaveform.currentFormatVersion + 1
    )
    let empty = AudioWaveform(
      sampleInterval: 0.05,
      levels: Data()
    )

    #expect(AudioWaveform.decode(from: try unsupported.encodedData()) == nil)
    #expect(AudioWaveform.decode(from: try empty.encodedData()) == nil)
    #expect(AudioWaveform.decode(from: Data("not JSON".utf8)) == nil)
  }

  @Test
  func audioRecording_decodesLegacyPayloadWithoutWaveform() throws {
    let data = Data(
      #"{"fileURL":"file:///tmp/legacy.m4a","duration":1.5}"#.utf8
    )

    let recording = try JSONDecoder().decode(AudioRecording.self, from: data)

    #expect(recording.duration == 1.5)
    #expect(recording.waveform == nil)
  }
}
