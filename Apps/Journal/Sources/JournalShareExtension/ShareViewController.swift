import SwiftUI
import UIKit

/// UIKit entry point declared as the Share extension's principal class.
///
/// UIKit owns the extension lifecycle while the actual review UI stays in
/// SwiftUI. All completion paths return through `NSExtensionContext`, which is
/// the only supported way for a share extension to dismiss itself.
final class ShareViewController: UIViewController {
  private var shareModel: JournalShareModel?

  override func viewDidLoad() {
    super.viewDidLoad()

    JournalShareTemporaryFile.cleanUpStaleImports()
    view.backgroundColor = .systemBackground
    preferredContentSize = CGSize(width: 540, height: 660)

    let model = JournalShareModel(
      onComplete: { [weak self] in
        self?.extensionContext?.completeRequest(
          returningItems: nil,
          completionHandler: nil
        )
      },
      onCancel: { [weak self] in
        self?.extensionContext?.cancelRequest(
          withError: CocoaError(.userCancelled)
        )
      }
    )
    shareModel = model

    let hostingController = UIHostingController(rootView: JournalShareView(model: model))
    addChild(hostingController)
    hostingController.view.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(hostingController.view)
    NSLayoutConstraint.activate([
      hostingController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      hostingController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      hostingController.view.topAnchor.constraint(equalTo: view.topAnchor),
      hostingController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
    hostingController.didMove(toParent: self)

    let inputItems = extensionContext?.inputItems.compactMap { $0 as? NSExtensionItem } ?? []
    model.start(inputItems: inputItems)
  }

  override func viewDidDisappear(_ animated: Bool) {
    super.viewDidDisappear(animated)
    shareModel?.hostDidDismiss()
  }
}
