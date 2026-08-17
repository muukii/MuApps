import AVFoundation
import AppUIComponents
import CaptureBauhaus
import CaptureDoodle
import Foundation
import ImageIO
import Testing
import UIKit

@testable import Tinycurve

@Suite("Entry share frame")
struct EntryShareFrameTests {

  @Test("Default output uniformly scales the logical frame by three")
  func defaultRasterScale() throws {
    let scale = try #require(
      EntryShareFrameLayout.rasterScale(
        for: EntryShareImageRenderer.defaultPixelSize
      )
    )

    #expect(scale == 3)
  }

  @Test("Content bounds and replay artwork stay centered")
  func centeredContentGeometry() throws {
    let pixelSize = EntryShareImageRenderer.defaultPixelSize
    let bounds = try #require(
      EntryShareFrameLayout.contentBounds(in: pixelSize)
    )

    #expect(bounds == CGRect(x: 96, y: 96, width: 888, height: 1_728))

    let doodleRect = EntryShareFrameLayout.aspectFitRect(
      aspectRatio: 4 / 5,
      in: bounds
    )
    let bauhausRect = EntryShareFrameLayout.aspectFitRect(
      aspectRatio: 1,
      in: bounds
    )

    #expect(doodleRect.midX == pixelSize.width / 2)
    #expect(doodleRect.midY == pixelSize.height / 2)
    #expect(abs(doodleRect.width / doodleRect.height - 4 / 5) < 0.000_1)
    #expect(bauhausRect.midX == pixelSize.width / 2)
    #expect(bauhausRect.midY == pixelSize.height / 2)
    #expect(bauhausRect.width == bauhausRect.height)
  }

  @Test("Non-9:16 output is rejected instead of stretching content")
  func rejectsNonUniformRasterScale() {
    #expect(
      EntryShareFrameLayout.rasterScale(
        for: CGSize(width: 1_080, height: 1_080)
      ) == nil
    )
  }

  @MainActor
  @Test("PNG renderer keeps the 1080 by 1920 pixel contract")
  func rendersDefaultPixelDimensions() throws {
    let snapshot = EntryShareSnapshot(
      id: UUID(uuidString: "E94F1C55-95B9-42F7-A8E9-72273FBB842C")!,
      content: .text("Centered content")
    )
    let image = try #require(EntryShareImageRenderer.image(for: snapshot))
    let pngData = try #require(image.pngData())
    let imageSource = try #require(
      CGImageSourceCreateWithData(pngData as CFData, nil)
    )
    let cgImage = try #require(
      CGImageSourceCreateImageAtIndex(imageSource, 0, nil)
    )

    #expect(cgImage.width == 1_080)
    #expect(cgImage.height == 1_920)
  }

  @MainActor
  @Test("Doodle replay uses the shared vertical frame")
  func rendersDoodleReplayVideo() async throws {
    let drawing = DoodleDrawing(
      strokes: [
        DoodleStroke(
          points: [
            DoodlePoint(x: 4, y: 8, time: 0),
            DoodlePoint(x: 32, y: 42, time: 0.2),
          ],
          width: 3
        )
      ],
      canvasSize: CGSize(width: 40, height: 50),
      duration: 0.2
    )
    let snapshot = EntryShareSnapshot(
      id: UUID(uuidString: "E5CF87D8-E850-4F72-B1D7-791A2BCE8197")!,
      content: .doodle(DoodleContentSource(drawing: drawing))
    )

    try await withTemporaryDirectory { directory in
      let fileURL = try await EntryShareVideoRenderer.mp4File(
        for: snapshot,
        drawing: drawing,
        pixelSize: EntryShareFrameLayout.pointSize,
        frameRate: 1,
        directory: directory
      )

      try await expectVideoSize(
        EntryShareFrameLayout.pointSize,
        at: fileURL
      )
    }
  }

  @MainActor
  @Test("Bauhaus replay uses the shared vertical frame")
  func rendersBauhausReplayVideo() async throws {
    let position = BauhausGridPosition(row: 2, column: 2)
    let tile = BauhausTile(shape: .circle, shapeSwatch: .slot1)
    var artwork = BauhausGridArtwork()
    artwork[position] = tile
    var replay = BauhausGridReplay()
    replay.append(
      action: .setTile(position: position, tile: tile),
      at: 0
    )
    let document = BauhausGridDocument(artwork: artwork, replay: replay)
    let snapshot = EntryShareSnapshot(
      id: UUID(uuidString: "0B0EC8A2-23C9-458E-8BD9-5DD252BA8B0B")!,
      content: .bauhaus(BauhausContentSource(document: document))
    )

    try await withTemporaryDirectory { directory in
      let fileURL = try await EntryShareVideoRenderer.mp4File(
        for: snapshot,
        bauhausDocument: document,
        pixelSize: EntryShareFrameLayout.pointSize,
        frameRate: 1,
        directory: directory
      )

      try await expectVideoSize(
        EntryShareFrameLayout.pointSize,
        at: fileURL
      )
    }
  }

  private func expectVideoSize(
    _ expectedSize: CGSize,
    at fileURL: URL
  ) async throws {
    let asset = AVURLAsset(url: fileURL)
    let videoTracks = try await asset.loadTracks(withMediaType: .video)
    let videoTrack = try #require(videoTracks.first)
    let naturalSize = try await videoTrack.load(.naturalSize)

    #expect(naturalSize == expectedSize)
  }

  private func withTemporaryDirectory(
    operation: (URL) async throws -> Void
  ) async throws {
    let directory = FileManager.default.temporaryDirectory
      .appending(path: "EntryShareFrameTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(
      at: directory,
      withIntermediateDirectories: true
    )
    defer { try? FileManager.default.removeItem(at: directory) }

    try await operation(directory)
  }
}
