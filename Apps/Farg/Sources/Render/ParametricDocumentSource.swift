//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//

import BrightroomParametric
import Synchronization

/// Supplies one coherent parametric document to each Preview frame evaluation.
///
/// An installed video composition owns one source. Grain-only edits replace the
/// stored value so subsequent compositor requests see the latest authored
/// parameters without replacing the composition or player item. Changes that
/// affect LUT color delivery create a new source together with a new
/// composition, preventing the old color contract from observing the new
/// document.
nonisolated final class ParametricDocumentSource: Sendable {

  private let storage: Mutex<EditingDocument>

  /// Creates a source containing the document used by the next frame request.
  init(document: EditingDocument) {
    self.storage = Mutex(document)
  }

  /// Returns one stable document value for the duration of a frame evaluation.
  func snapshot() -> EditingDocument {
    storage.withLock { document in
      document
    }
  }

  /// Replaces the document consumed by subsequent frame requests.
  func update(document: EditingDocument) {
    storage.withLock { storedDocument in
      storedDocument = document
    }
  }
}
