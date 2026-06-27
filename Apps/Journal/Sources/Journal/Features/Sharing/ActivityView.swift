import SwiftUI
import UIKit

/// SwiftUI bridge for the system activity view controller.
///
/// Use this when the share payload is prepared by an explicit user action before
/// presentation. That fits context-menu actions better than embedding a
/// `ShareLink` directly inside the menu.
struct ActivityView: UIViewControllerRepresentable {

  /// Items passed to `UIActivityViewController`, such as a file URL.
  var activityItems: [Any]

  /// Optional activity services to exclude from the sheet.
  var excludedActivityTypes: [UIActivity.ActivityType] = []

  func makeUIViewController(context: Context) -> UIActivityViewController {
    let controller = UIActivityViewController(
      activityItems: activityItems,
      applicationActivities: nil
    )
    controller.excludedActivityTypes = excludedActivityTypes
    return controller
  }

  func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
