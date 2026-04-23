//
//  YouTubePlayerWebView.swift
//  YouTubeSubtitle
//
//  1st Party YouTube Player - WKWebView Wrapper
//
//  Architecture:
//  - WKWebView hosts YouTube iFrame Player API
//  - WKScriptMessageHandler receives events from JavaScript
//  - evaluateJavaScript sends commands to JavaScript
//
//  Communication Flow:
//  [Swift] --evaluateJavaScript--> [JavaScript/iFrame API]
//  [JavaScript] --postMessage--> [WKScriptMessageHandler] --> [Swift]
//

import Combine
import WebKit

// MARK: - YouTubePlayerWebView

@MainActor
final class YouTubePlayerWebView: WKWebView {

  // MARK: - Event Types

  enum Event: Sendable {
    case ready
    case stateChange(PlaybackState)
    case error(Int)
  }

  // MARK: - Playback State

  /// YouTube iFrame API player state values
  /// Reference: https://developers.google.com/youtube/iframe_api_reference#Playback_status
  enum PlaybackState: Int, Sendable {
    case unstarted = -1  // Player has not started
    case ended = 0       // Video has finished playing
    case playing = 1     // Video is currently playing
    case paused = 2      // Video is paused
    case buffering = 3   // Video is buffering
    case cued = 5        // Video is cued and ready to play

    var isPlaying: Bool { self == .playing }
  }

  // MARK: - Properties

  /// Event publisher for player events
  let eventPublisher = PassthroughSubject<Event, Never>()

  /// Message handler name used in JavaScript
  private let messageHandlerName = "youtubePlayer"

  /// Script message handler (prevent deallocation)
  private var messageHandler: ScriptMessageHandler?

  /// Store userContentController reference for cleanup
  private let userContentController: WKUserContentController

  // MARK: - Initialization

  init() {
    let configuration = WKWebViewConfiguration()

    // Allow inline playback (required for iOS)
    configuration.allowsInlineMediaPlayback = true
    configuration.mediaTypesRequiringUserActionForPlayback = []

    // Use non-persistent data store to avoid caching issues
    configuration.websiteDataStore = .nonPersistent()

    self.userContentController = configuration.userContentController

    super.init(frame: .zero, configuration: configuration)

    setupMessageHandler()
    setupWebView()
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  // Note: deinit removed as WKWebView handles cleanup automatically
  // and accessing MainActor-isolated properties in deinit causes issues

  // MARK: - Setup

  private func setupMessageHandler() {
    let handler = ScriptMessageHandler { [weak self] message in
      Task { @MainActor in
        self?.handleMessage(message)
      }
    }
    self.messageHandler = handler
    userContentController.add(handler, name: messageHandlerName)
  }

  private func setupWebView() {
    // Transparent background
    isOpaque = false
    backgroundColor = .clear
    scrollView.backgroundColor = .clear

    // Disable scrolling (video player handles its own interaction)
    scrollView.isScrollEnabled = false
    scrollView.bounces = false

    // Enable Safari Web Inspector in debug builds
    #if DEBUG
    if #available(iOS 16.4, *) {
      isInspectable = true
    }
    #endif
  }

  // MARK: - Cleanup

  /// Call this method before releasing the web view
  func cleanup() {
    userContentController.removeScriptMessageHandler(forName: messageHandlerName)
    messageHandler = nil
  }

  // MARK: - Load Video

  /// Origin URL for YouTube iFrame API
  /// Uses bundle identifier as host to create a valid origin that YouTube accepts
  /// e.g., "https://app.muukii.verse"
  private static var originURL: URL? = {
    var components = URLComponents()
    components.scheme = "https"
    components.host = Bundle.main.bundleIdentifier?.lowercased() ?? "youtubeplayer"
    return components.url
  }()

  /// Load a YouTube video
  /// - Parameters:
  ///   - videoID: YouTube video ID
  ///   - autoplay: Whether to autoplay
  ///   - controls: Show YouTube controls
  func loadVideo(videoID: String, autoplay: Bool = false, controls: Bool = true) {
    let origin = Self.originURL?.absoluteString ?? "https://youtubeplayer"
    let html = YouTubePlayerHTML.generate(
      videoID: videoID,
      autoplay: autoplay,
      controls: controls,
      origin: origin
    )
    loadHTMLString(html, baseURL: Self.originURL)
  }

  // MARK: - JavaScript API Calls

  /// Play the video
  func play() async {
    await evaluateJSVoid("play()")
  }

  /// Pause the video
  func pause() async {
    await evaluateJSVoid("pause()")
  }

  /// Mute the video
  func mute() async {
    await evaluateJSVoid("mute()")
  }

  /// Unmute the video
  func unmute() async {
    await evaluateJSVoid("unmute()")
  }

  /// Seek to a specific time
  /// - Parameter seconds: Time in seconds
  func seek(to seconds: Double) async {
    await evaluateJSVoid("seekTo(\(seconds))")
  }

  /// Set playback rate
  /// - Parameter rate: Playback rate (0.25, 0.5, 1, 1.5, 2)
  func setPlaybackRate(_ rate: Double) async {
    await evaluateJSVoid("setPlaybackRate(\(rate))")
  }

  /// Get current playback time
  /// - Returns: Current time in seconds
  func getCurrentTime() async -> Double {
    let value = await evaluateJSDouble("getCurrentTime()")
    return value ?? 0
  }

  /// Get video duration
  /// - Returns: Duration in seconds
  func getDuration() async -> Double {
    await evaluateJSDouble("getDuration()") ?? 0
  }

  /// Get current player state
  /// - Returns: PlaybackState
  func getPlayerState() async -> PlaybackState {
    let stateValue = await evaluateJSInt("getPlayerState()") ?? -1
    return PlaybackState(rawValue: stateValue) ?? .unstarted
  }

  /// Get current playback rate
  /// - Returns: Playback rate
  func getPlaybackRate() async -> Double {
    await evaluateJSDouble("getPlaybackRate()") ?? 1.0
  }

  // MARK: - Private Methods

  /// Evaluate JavaScript without expecting a return value
  private func evaluateJSVoid(_ script: String) async {
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
      evaluateJavaScript(script) { _, error in
        if let error {
          #if DEBUG
          print("[YouTubePlayerWebView] JS Error: \(error.localizedDescription)")
          #endif
        }
        continuation.resume()
      }
    }
  }

  /// Evaluate JavaScript and return Double result
  private func evaluateJSDouble(_ script: String) async -> Double? {
    await withCheckedContinuation { continuation in
      evaluateJavaScript(script) { result, error in
        if let error {
          #if DEBUG
          print("[YouTubePlayerWebView] JS Error: \(error.localizedDescription)")
          #endif
          continuation.resume(returning: nil)
          return
        }
        if let doubleValue = result as? Double {
          continuation.resume(returning: doubleValue)
        } else if let intValue = result as? Int {
          continuation.resume(returning: Double(intValue))
        } else {
          continuation.resume(returning: nil)
        }
      }
    }
  }

  /// Evaluate JavaScript and return Int result
  private func evaluateJSInt(_ script: String) async -> Int? {
    await withCheckedContinuation { continuation in
      evaluateJavaScript(script) { result, error in
        if let error {
          #if DEBUG
          print("[YouTubePlayerWebView] JS Error: \(error.localizedDescription)")
          #endif
          continuation.resume(returning: nil)
          return
        }
        if let intValue = result as? Int {
          continuation.resume(returning: intValue)
        } else if let doubleValue = result as? Double {
          continuation.resume(returning: Int(doubleValue))
        } else {
          continuation.resume(returning: nil)
        }
      }
    }
  }

  /// Handle message from JavaScript
  private func handleMessage(_ message: WKScriptMessage) {
    guard let body = message.body as? [String: Any],
          let eventName = body["event"] as? String else {
      return
    }

    // Filter out YouTube Widget API internal events (channel: "widget")
    // We only care about our custom postMessage events
    if body["channel"] != nil {
      // YouTube Widget API event - ignore most of them
      // Handle onReady/onStateChange/onError from Widget API as fallback
      switch eventName {
      case "onReady":
        eventPublisher.send(.ready)
      case "onStateChange":
        if let stateValue = body["info"] as? Int,
           let state = PlaybackState(rawValue: stateValue) {
          eventPublisher.send(.stateChange(state))
        }
      case "onError":
        if let errorCode = body["info"] as? Int {
          eventPublisher.send(.error(errorCode))
          #if DEBUG
          print("[YouTubePlayerWebView] Player Error: \(errorCode)")
          #endif
        }
      default:
        // Ignore other widget events (readyToListen, initialDelivery, alreadyInitialized, etc.)
        break
      }
      return
    }

    // Our custom postMessage events
    switch eventName {
    case "ready":
      eventPublisher.send(.ready)

    case "stateChange":
      if let stateValue = body["data"] as? Int,
         let state = PlaybackState(rawValue: stateValue) {
        eventPublisher.send(.stateChange(state))
      }

    case "error":
      if let errorCode = body["data"] as? Int {
        eventPublisher.send(.error(errorCode))
        #if DEBUG
        print("[YouTubePlayerWebView] Player Error: \(errorCode)")
        // Error codes: 2=invalid param, 5=HTML5 error, 100=not found, 101/150=embed blocked
        #endif
      }

    default:
      #if DEBUG
      print("[YouTubePlayerWebView] Unknown event: \(eventName)")
      #endif
    }
  }
}

// MARK: - ScriptMessageHandler

/// Wrapper class for WKScriptMessageHandler to avoid retain cycles
private final class ScriptMessageHandler: NSObject, WKScriptMessageHandler, @unchecked Sendable {
  private let handler: @Sendable (WKScriptMessage) -> Void

  init(handler: @escaping @Sendable (WKScriptMessage) -> Void) {
    self.handler = handler
    super.init()
  }

  func userContentController(
    _ userContentController: WKUserContentController,
    didReceive message: WKScriptMessage
  ) {
    handler(message)
  }
}
