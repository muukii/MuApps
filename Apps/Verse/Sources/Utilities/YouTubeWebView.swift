//
//  YouTubeWebView.swift
//  YouTubeSubtitle
//
//  Created by Hiroshi Kimura on 2025/12/01.
//

import SwiftUI
import WebKit
import AuthenticationServices

struct YouTubeWebView: View {
  let onOpenPlayer: (YouTubeContentID) -> Void

  @State private var webView: WKWebView?
  @State private var currentURL: URL?
  #if os(iOS)
  @State private var isAuthenticating = false
  @State private var authSession: ASWebAuthenticationSession?
  @State private var presentationContext: WebAuthPresentationContext?
  #endif

  private var isVideoPage: Bool {
    guard let url = currentURL else { return false }
    let path = url.path
    return path.hasPrefix("/watch") || path.hasPrefix("/shorts/")
  }

  private var detectedVideoID: YouTubeContentID? {
    guard let url = currentURL, isVideoPage else { return nil }
    return YouTubeURLParser.extractVideoID(from: url)
  }

  var body: some View {
    ZStack(alignment: .bottom) {
      YouTubeWebViewRepresentable(
        onURLChanged: { url in
          currentURL = url
        },
        webViewRef: $webView
      )

      // Show button when video is detected
      if let videoID = detectedVideoID, let url = currentURL {
        Button {
          onOpenPlayer(videoID)
        } label: {
          VStack(spacing: 4) {
            Label("Open with Subtitles", systemImage: "captions.bubble")
              .font(.headline)
            Text(url.absoluteString)
              .font(.caption)
              .foregroundStyle(.secondary)
              .lineLimit(1)
          }
          .padding(.horizontal, 20)
          .padding(.vertical, 12)
          .background(.ultraThinMaterial)
          .clipShape(RoundedRectangle(cornerRadius: 16))
          .shadow(radius: 4)
        }
        .buttonStyle(.plain)
        .padding(.bottom, 16)
        .padding(.horizontal, 16)
        .transition(.move(edge: .bottom).combined(with: .opacity))
        .animation(.spring(duration: 0.3), value: detectedVideoID)
      }
    }
    #if os(iOS)
    .toolbar {
      ToolbarItemGroup(placement: .bottomBar) {
        Button {
          webView?.goBack()
        } label: {
          Image(systemName: "chevron.left")
        }
        .disabled(webView?.canGoBack != true)

        Button {
          webView?.goForward()
        } label: {
          Image(systemName: "chevron.right")
        }
        .disabled(webView?.canGoForward != true)

        Spacer()

        Button {
          startGoogleSignIn()
        } label: {
          Image(systemName: "person.circle")
        }
        .disabled(isAuthenticating)

        Button {
          webView?.reload()
        } label: {
          Image(systemName: "arrow.clockwise")
        }
      }
    }
    #else
    .toolbar {
      ToolbarItemGroup(placement: .automatic) {
        Button {
          webView?.goBack()
        } label: {
          Image(systemName: "chevron.left")
        }
        .disabled(webView?.canGoBack != true)

        Button {
          webView?.goForward()
        } label: {
          Image(systemName: "chevron.right")
        }
        .disabled(webView?.canGoForward != true)

        Button {
          webView?.reload()
        } label: {
          Image(systemName: "arrow.clockwise")
        }
      }
    }
    #endif
  }

  #if os(iOS)
  private func startGoogleSignIn() {
    // YouTube's sign in URL
    guard let authURL = URL(string: "https://accounts.google.com/ServiceLogin?continue=https://m.youtube.com") else {
      return
    }

    isAuthenticating = true

    let session = ASWebAuthenticationSession(
      url: authURL,
      callbackURLScheme: nil  // nil means it will complete when user navigates back
    ) { [self] callbackURL, error in
      isAuthenticating = false
      authSession = nil
      presentationContext = nil

      // Reload the webview to pick up the new session
      webView?.reload()
    }

    // Use shared Safari cookies (not ephemeral)
    session.prefersEphemeralWebBrowserSession = false

    // Get the presentation anchor and store references to prevent deallocation
    if let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
       let window = windowScene.windows.first {
      let context = WebAuthPresentationContext(anchor: window)
      presentationContext = context
      session.presentationContextProvider = context
    }

    authSession = session
    session.start()
  }
  #endif
}

#if os(iOS)
private class WebAuthPresentationContext: NSObject, ASWebAuthenticationPresentationContextProviding {
  let anchor: ASPresentationAnchor

  init(anchor: ASPresentationAnchor) {
    self.anchor = anchor
  }

  func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
    anchor
  }
}
#endif

#if os(iOS)
private struct YouTubeWebViewRepresentable: UIViewRepresentable {
  let onURLChanged: (URL?) -> Void
  @Binding var webViewRef: WKWebView?

  func makeCoordinator() -> Coordinator {
    Coordinator(onURLChanged: onURLChanged)
  }

  func makeUIView(context: Context) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.allowsInlineMediaPlayback = true
    configuration.mediaTypesRequiringUserActionForPlayback = []

    let webView = WKWebView(frame: .zero, configuration: configuration)
    webView.navigationDelegate = context.coordinator
    webView.uiDelegate = context.coordinator
    webView.allowsBackForwardNavigationGestures = true
    context.coordinator.observeURL(of: webView)

    // Load YouTube mobile
    if let url = URL(string: "https://m.youtube.com") {
      webView.load(URLRequest(url: url))
    }

    DispatchQueue.main.async {
      webViewRef = webView
    }

    return webView
  }

  func updateUIView(_ webView: WKWebView, context: Context) {}
}
#else
private struct YouTubeWebViewRepresentable: NSViewRepresentable {
  let onURLChanged: (URL?) -> Void
  @Binding var webViewRef: WKWebView?

  func makeCoordinator() -> Coordinator {
    Coordinator(onURLChanged: onURLChanged)
  }

  func makeNSView(context: Context) -> WKWebView {
    let configuration = WKWebViewConfiguration()
    configuration.mediaTypesRequiringUserActionForPlayback = []

    let webView = WKWebView(frame: .zero, configuration: configuration)
    webView.navigationDelegate = context.coordinator
    webView.uiDelegate = context.coordinator
    webView.allowsBackForwardNavigationGestures = true
    context.coordinator.observeURL(of: webView)

    // Load YouTube
    if let url = URL(string: "https://www.youtube.com") {
      webView.load(URLRequest(url: url))
    }

    DispatchQueue.main.async {
      webViewRef = webView
    }

    return webView
  }

  func updateNSView(_ webView: WKWebView, context: Context) {}
}
#endif

private class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate {
  let onURLChanged: (URL?) -> Void
  private var urlObservation: NSKeyValueObservation?

  init(onURLChanged: @escaping (URL?) -> Void) {
    self.onURLChanged = onURLChanged
  }

  func observeURL(of webView: WKWebView) {
    urlObservation = webView.observe(\.url, options: [.new]) { [weak self] webView, _ in
      DispatchQueue.main.async {
        self?.onURLChanged(webView.url)
      }
    }
  }

  // MARK: - WKUIDelegate

  // Handle new window requests (for popups, authentication flows)
  func webView(
    _ webView: WKWebView,
    createWebViewWith configuration: WKWebViewConfiguration,
    for navigationAction: WKNavigationAction,
    windowFeatures: WKWindowFeatures
  ) -> WKWebView? {
    // Load popup URLs in the same webview
    if navigationAction.targetFrame == nil {
      webView.load(navigationAction.request)
    }
    return nil
  }

  #if os(iOS)
  // Handle JavaScript alerts
  func webView(
    _ webView: WKWebView,
    runJavaScriptAlertPanelWithMessage message: String,
    initiatedByFrame frame: WKFrameInfo,
    completionHandler: @escaping () -> Void
  ) {
    let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in
      completionHandler()
    })
    UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .first?.windows.first?.rootViewController?
      .present(alert, animated: true)
  }

  // Handle JavaScript confirms
  func webView(
    _ webView: WKWebView,
    runJavaScriptConfirmPanelWithMessage message: String,
    initiatedByFrame frame: WKFrameInfo,
    completionHandler: @escaping (Bool) -> Void
  ) {
    let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in
      completionHandler(false)
    })
    alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in
      completionHandler(true)
    })
    UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .first?.windows.first?.rootViewController?
      .present(alert, animated: true)
  }

  // Handle JavaScript text input
  func webView(
    _ webView: WKWebView,
    runJavaScriptTextInputPanelWithPrompt prompt: String,
    defaultText: String?,
    initiatedByFrame frame: WKFrameInfo,
    completionHandler: @escaping (String?) -> Void
  ) {
    let alert = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)
    alert.addTextField { textField in
      textField.text = defaultText
    }
    alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in
      completionHandler(nil)
    })
    alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in
      completionHandler(alert.textFields?.first?.text)
    })
    UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .first?.windows.first?.rootViewController?
      .present(alert, animated: true)
  }
  #endif
}

#Preview {
  NavigationStack {
    YouTubeWebView { videoID in
      print("Open player for: \(videoID)")
    }
  }
}
