//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//

import Foundation
import OSLog

/// Correlates one picker selection across Files access and AVFoundation loading.
///
/// The selection identifier and source kind are safe to expose in diagnostics.
/// File names remain private and hash-masked so repeated events can be correlated
/// without recording a person's media name or full external-storage path.
nonisolated struct VideoImportLogContext: Sendable {

  /// The system surface that supplied the source movie.
  enum SourceKind: String, Sendable {
    case files
    case photos
  }

  let selectionID: UUID
  let sourceKind: SourceKind
  let fileName: String
  let pathExtension: String

  /// Describes one Photos selection without inspecting its media resource.
  static func photos(selectionID: UUID) -> Self {
    Self(
      selectionID: selectionID,
      sourceKind: .photos,
      fileName: "photos-selection",
      pathExtension: "unavailable"
    )
  }

  /// Describes one Files selection using only non-I/O URL components.
  static func files(selectionID: UUID, url: URL) -> Self {
    Self(
      selectionID: selectionID,
      sourceKind: .files,
      fileName: url.lastPathComponent,
      pathExtension: url.pathExtension.lowercased()
    )
  }
}

/// Emits privacy-safe lifecycle and error records for source video preparation.
///
/// Filter Console by subsystem `app.muukii.farg` and category `VideoImport`.
/// Error records retain Foundation/AVFoundation domains, numeric codes, and the
/// underlying-error chain while keeping descriptions private because system
/// descriptions can contain complete file-system paths.
nonisolated enum VideoImportDiagnostics {

  private static let logger = Logger(
    subsystem: "app.muukii.farg",
    category: "VideoImport"
  )

  static func selectionQueued(_ context: VideoImportLogContext) {
    logger.info(
      """
      event=selectionQueued selection=\(context.selectionID.uuidString, privacy: .public) \
      source=\(context.sourceKind.rawValue, privacy: .public) \
      file=\(context.fileName, privacy: .private(mask: .hash)) \
      extension=\(context.pathExtension, privacy: .public)
      """
    )
  }

  static func securityScopeStarted(_ context: VideoImportLogContext) {
    logger.info(
      """
      event=securityScopeStarted selection=\(context.selectionID.uuidString, privacy: .public) \
      source=\(context.sourceKind.rawValue, privacy: .public) \
      file=\(context.fileName, privacy: .private(mask: .hash))
      """
    )
  }

  static func securityScopeEnded(_ context: VideoImportLogContext) {
    logger.info(
      """
      event=securityScopeEnded selection=\(context.selectionID.uuidString, privacy: .public) \
      source=\(context.sourceKind.rawValue, privacy: .public) \
      file=\(context.fileName, privacy: .private(mask: .hash))
      """
    )
  }

  static func assetValidationStarted(_ context: VideoImportLogContext) {
    logger.info(
      """
      event=assetValidationStarted selection=\(context.selectionID.uuidString, privacy: .public) \
      source=\(context.sourceKind.rawValue, privacy: .public) \
      extension=\(context.pathExtension, privacy: .public)
      """
    )
  }

  static func assetValidationRejected(
    _ context: VideoImportLogContext,
    isPlayable: Bool,
    videoTrackCount: Int
  ) {
    logger.error(
      """
      event=assetValidationRejected selection=\(context.selectionID.uuidString, privacy: .public) \
      source=\(context.sourceKind.rawValue, privacy: .public) \
      isPlayable=\(isPlayable, privacy: .public) \
      videoTrackCount=\(videoTrackCount, privacy: .public) \
      extension=\(context.pathExtension, privacy: .public)
      """
    )
  }

  static func sourcePrepared(
    _ context: VideoImportLogContext,
    videoTrackCount: Int
  ) {
    logger.info(
      """
      event=sourcePrepared selection=\(context.selectionID.uuidString, privacy: .public) \
      source=\(context.sourceKind.rawValue, privacy: .public) \
      videoTrackCount=\(videoTrackCount, privacy: .public) \
      extension=\(context.pathExtension, privacy: .public)
      """
    )
  }

  static func sourcePreparationCancelled(_ context: VideoImportLogContext) {
    logger.info(
      """
      event=sourcePreparationCancelled selection=\(context.selectionID.uuidString, privacy: .public) \
      source=\(context.sourceKind.rawValue, privacy: .public)
      """
    )
  }

  /// Records the complete NSError chain at the boundary where an operation failed.
  static func log(
    error: any Error,
    stage: String,
    context: VideoImportLogContext
  ) {
    var currentError: NSError? = error as NSError
    var underlyingDepth = 0

    while let error = currentError, underlyingDepth < 5 {
      let userInfoKeys = error.userInfo.keys
        .map(String.init(describing:))
        .sorted()
        .joined(separator: ",")

      logger.error(
        """
        event=sourcePreparationFailed selection=\(context.selectionID.uuidString, privacy: .public) \
        source=\(context.sourceKind.rawValue, privacy: .public) \
        stage=\(stage, privacy: .public) \
        underlyingDepth=\(underlyingDepth, privacy: .public) \
        domain=\(error.domain, privacy: .public) \
        code=\(error.code, privacy: .public) \
        file=\(context.fileName, privacy: .private(mask: .hash)) \
        extension=\(context.pathExtension, privacy: .public) \
        description=\(error.localizedDescription, privacy: .private) \
        failureReason=\(error.localizedFailureReason ?? "unavailable", privacy: .private) \
        userInfoKeys=\(userInfoKeys, privacy: .public)
        """
      )

      currentError = error.userInfo[NSUnderlyingErrorKey] as? NSError
      underlyingDepth += 1
    }
  }
}
