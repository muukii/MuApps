import SafariServices
import os.log

final class SafariWebExtensionHandler: NSObject, NSExtensionRequestHandling {
  func beginRequest(with context: NSExtensionContext) {
    let request = context.inputItems.first as? NSExtensionItem

    let profile: UUID?
    if #available(iOS 17.0, macOS 14.0, *) {
      profile = request?.userInfo?[SFExtensionProfileKey] as? UUID
    } else {
      profile = request?.userInfo?["profile"] as? UUID
    }

    let message: Any?
    if #available(iOS 15.0, macOS 11.0, *) {
      message = request?.userInfo?[SFExtensionMessageKey]
    } else {
      message = request?.userInfo?["message"]
    }

    Logger.safariExtension.debug(
      "Received Safari extension message: \(String(describing: message), privacy: .public), profile: \(profile?.uuidString ?? "none", privacy: .public)"
    )

    let response = NSExtensionItem()
    let payload: [String: Any] = [
      "ok": true,
      "received": String(describing: message),
    ]

    if #available(iOS 15.0, macOS 11.0, *) {
      response.userInfo = [SFExtensionMessageKey: payload]
    } else {
      response.userInfo = ["message": payload]
    }

    context.completeRequest(returningItems: [response], completionHandler: nil)
  }
}

private extension Logger {
  static let safariExtension = Logger(subsystem: "app.muukii.safarireactor", category: "SafariExtension")
}
