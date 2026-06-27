import AVFoundation
import CaptureAudio
import CoreLocation
import MuColor
import SwiftUI

/// First-run (and on-demand) introduction to Journal.
///
/// Four horizontally-paged screens — a welcome, the capture methods, an optional
/// permission primer, and a theme picker — followed by a single call-to-action.
/// The view is presentation-agnostic: it reports completion through `onComplete`
/// and never touches `JournalDefaults.hasCompletedOnboarding` itself. `RootView`
/// injects a closure that flips that flag (first run); `SettingsView` injects one
/// that merely dismisses its cover (manual re-showing).
///
/// It wraps its own body in a `PrimaryContainer` keyed to the stored theme so the
/// palette resolves whether it is shown inline (already inside `RootView`'s
/// container) or over the app from a `fullScreenCover` — and so the theme page's
/// selection re-tints the onboarding live.
struct OnboardingView: View {

  let onComplete: @MainActor @Sendable () -> Void

  @AppStorage(JournalDefaults.themeID) private var themeID: String = Theme.default.id
  @State private var pageIndex = 0

  /// Pages, in order. The index of the last one drives the CTA's "last page"
  /// behavior and hides the Skip affordance.
  private static let pageCount = 4

  private var isLastPage: Bool { pageIndex == Self.pageCount - 1 }

  var body: some View {
    PrimaryContainer(theme: Theme.with(id: themeID)) {
      ZStack {
        Rectangle()
          .fill(.appPrimaryContainer)
          .ignoresSafeArea()

        VStack(spacing: 0) {
          topBar

          TabView(selection: $pageIndex) {
            WelcomePage().tag(0)
            CaptureMethodsPage().tag(1)
            PermissionsPage().tag(2)
            ThemePage().tag(3)
          }
          .tabViewStyle(.page(indexDisplayMode: .always))
          .indexViewStyle(.page(backgroundDisplayMode: .interactive))

          ctaBar
        }
      }
    }
  }

  private var topBar: some View {
    HStack {
      Spacer(minLength: 0)
      if !isLastPage {
        Button("Skip", action: onComplete)
          .buttonStyle(.glass)
      }
    }
    .frame(height: 44)
    .padding(.horizontal, 20)
    .padding(.top, 8)
    .animation(.smooth, value: isLastPage)
  }

  private var ctaBar: some View {
    Button(action: advance) {
      Text(isLastPage ? "Get Started" : "Next")
        .font(.headline)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 6)
    }
    .buttonStyle(.glassProminent)
    .controlSize(.large)
    .padding(.horizontal, 28)
    .padding(.vertical, 16)
    .sensoryFeedback(.selection, trigger: pageIndex)
  }

  private func advance() {
    if isLastPage {
      onComplete()
    } else {
      withAnimation(.smooth) { pageIndex += 1 }
    }
  }
}

// MARK: - Pages

/// The hero. A single decorative card states the core idea — everything you
/// record is kept as one card — over a short welcome.
fileprivate struct WelcomePage: View {

  var body: some View {
    VStack(spacing: 36) {
      Spacer(minLength: 0)

      CardSurface {
        VStack(alignment: .leading, spacing: 12) {
          Text("Today")
            .font(.headline)
            .foregroundStyle(.secondary)
          Text("Every little thing\nbecomes a card.")
            .font(.system(size: 26, weight: .bold))
        }
      }
      .frame(maxWidth: 230)

      VStack(spacing: 10) {
        Text("Welcome to Journal")
          .font(.largeTitle.bold())
          .multilineTextAlignment(.center)
        Text("Capture text, photos, doodles, and sound — each kept as a simple card that syncs across your devices.")
          .font(.body)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
      }

      Spacer(minLength: 0)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 28)
    .frame(maxWidth: .infinity)
  }
}

/// Introduces the six capture modalities the app offers, each as an icon + name +
/// one-line summary.
fileprivate struct CaptureMethodsPage: View {

  var body: some View {
    OnboardingPage(
      title: "Many ways to capture",
      subtitle: "Each thing you record becomes one card."
    ) {
      VStack(spacing: 16) {
        ForEach(CaptureMethod.all) { method in
          CaptureMethodRow(method: method)
        }
      }
    }
  }
}

/// Primes the three system permissions the app can use. Everything here is
/// optional: each row requests its own permission on demand and reflects the live
/// status, but the user can advance without granting anything.
fileprivate struct PermissionsPage: View {

  var body: some View {
    OnboardingPage(
      title: "A few permissions",
      subtitle: "All optional — grant only what you want to use. You can change these anytime in the Settings app."
    ) {
      VStack(spacing: 14) {
        CameraPermissionRow()
        MicrophonePermissionRow()
        LocationPermissionRow()
      }
    }
  }
}

/// Lets the user pick a theme during onboarding, written straight to the same
/// `@AppStorage` key the rest of the app reads, so the choice applies app-wide
/// (and re-tints this very screen) the moment it's tapped.
fileprivate struct ThemePage: View {

  @AppStorage(JournalDefaults.themeID) private var themeID: String = Theme.default.id
  @Environment(\.colorScheme) private var colorScheme

  private let columns = [GridItem(.flexible(), spacing: 16), GridItem(.flexible(), spacing: 16)]

  var body: some View {
    OnboardingPage(
      title: "Make it yours",
      subtitle: "Pick a color theme. You can change it anytime in Settings."
    ) {
      LazyVGrid(columns: columns, spacing: 16) {
        ForEach(Theme.all) { theme in
          ThemeTile(
            theme: theme,
            isSelected: theme.id == themeID,
            onSelect: {
              withAnimation(.smooth) { themeID = theme.id }
            }
          )
        }
      }
    }
    .sensoryFeedback(.selection, trigger: themeID)
  }
}

// MARK: - Page Scaffold

/// Shared layout for the non-hero pages: a left-aligned title/subtitle header
/// above scrollable content, with consistent insets. Extracted because three
/// pages genuinely share this shape; the welcome page deliberately doesn't use it.
fileprivate struct OnboardingPage<Content: View>: View {

  let title: String
  let subtitle: String
  @ViewBuilder var content: Content

  var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        VStack(alignment: .leading, spacing: 8) {
          Text(title)
            .font(.largeTitle.bold())
          Text(subtitle)
            .font(.body)
            .foregroundStyle(.secondary)
        }
        content
      }
      .frame(maxWidth: .infinity, alignment: .leading)
      .padding(28)
      .padding(.bottom, 40)
    }
  }
}

// MARK: - Capture Methods

/// One capture modality as plain display data. Every entry has the same shape, so
/// this is a struct with static constants rather than an enum.
private struct CaptureMethod: Identifiable {

  let id: String
  let icon: String
  let name: String
  let summary: String

  static let all: [CaptureMethod] = [
    .init(id: "text", icon: "text.alignleft", name: "Text", summary: "Jot down what's on your mind."),
    .init(id: "photo", icon: "camera", name: "Photo", summary: "Capture a moment with the camera."),
    .init(id: "doodle", icon: "scribble.variable", name: "Doodle", summary: "Sketch a quick ink drawing."),
    .init(id: "audio", icon: "waveform", name: "Ambient Sound", summary: "Record the sound around you."),
    .init(id: "suggestion", icon: "sparkles", name: "Suggestions", summary: "Start from a Journaling Suggestion."),
  ]
}

fileprivate struct CaptureMethodRow: View {

  let method: CaptureMethod

  var body: some View {
    HStack(spacing: 16) {
      Image(systemName: method.icon)
        .font(.title3)
        .foregroundStyle(.tint)
        .frame(width: 44, height: 44)
        .background(
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(.appSecondaryContainer)
        )

      VStack(alignment: .leading, spacing: 2) {
        Text(method.name)
          .font(.headline)
        Text(method.summary)
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }

      Spacer(minLength: 0)
    }
  }
}

// MARK: - Permissions

/// Tri-state distillation of the various system permission enums, so the row's
/// presentation switches on one shape regardless of which permission it shows.
private enum PermissionState {
  case notDetermined
  case granted
  case denied
}

/// The presentation of a single permission. Owns no system state — each concrete
/// permission wrapper maps its platform status into `state` and supplies the
/// request action.
fileprivate struct PermissionRow: View {

  let icon: String
  let title: String
  let description: String
  let state: PermissionState
  let onRequest: @MainActor @Sendable () -> Void

  var body: some View {
    HStack(spacing: 16) {
      Image(systemName: icon)
        .font(.title3)
        .foregroundStyle(.tint)
        .frame(width: 44, height: 44)
        .background(
          RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(.appSecondaryContainer)
        )

      VStack(alignment: .leading, spacing: 2) {
        Text(title)
          .font(.headline)
        Text(description)
          .font(.subheadline)
          .foregroundStyle(.secondary)
      }

      Spacer(minLength: 0)

      trailing
    }
  }

  @ViewBuilder
  private var trailing: some View {
    switch state {
    case .granted:
      Image(systemName: "checkmark.circle.fill")
        .font(.title2)
        .foregroundStyle(.tint)
        .transition(.scale.combined(with: .opacity))
    case .notDetermined:
      Button("Allow", action: onRequest)
        .buttonStyle(.glass)
        .font(.subheadline.weight(.semibold))
    case .denied:
      Text("Denied")
        .font(.subheadline)
        .foregroundStyle(.secondary)
    }
  }
}

fileprivate struct CameraPermissionRow: View {

  @State private var status = AVCaptureDevice.authorizationStatus(for: .video)

  var body: some View {
    PermissionRow(
      icon: "camera",
      title: "Camera",
      description: "Take a photo to attach to an entry.",
      state: state,
      onRequest: {
        Task {
          _ = await AVCaptureDevice.requestAccess(for: .video)
          withAnimation(.smooth) {
            status = AVCaptureDevice.authorizationStatus(for: .video)
          }
        }
      }
    )
  }

  private var state: PermissionState {
    switch status {
    case .authorized: .granted
    case .denied, .restricted: .denied
    case .notDetermined: .notDetermined
    @unknown default: .notDetermined
    }
  }
}

fileprivate struct MicrophonePermissionRow: View {

  @State private var permission = AmbientAudioRecorder.permission

  var body: some View {
    PermissionRow(
      icon: "waveform",
      title: "Microphone",
      description: "Record the sound around you.",
      state: state,
      onRequest: {
        Task {
          _ = await AmbientAudioRecorder.requestPermission()
          withAnimation(.smooth) {
            permission = AmbientAudioRecorder.permission
          }
        }
      }
    )
  }

  private var state: PermissionState {
    switch permission {
    case .granted: .granted
    case .denied: .denied
    case .undetermined: .notDetermined
    @unknown default: .notDetermined
    }
  }
}

fileprivate struct LocationPermissionRow: View {

  @State private var manager = LocationManager()

  var body: some View {
    PermissionRow(
      icon: "location",
      title: "Location",
      description: "Attach where you are to an entry.",
      state: state,
      onRequest: { manager.requestAuthorization() }
    )
  }

  private var state: PermissionState {
    if manager.isAuthorized { return .granted }
    switch manager.authorizationStatus {
    case .notDetermined: return .notDetermined
    default: return .denied
    }
  }
}

// MARK: - Theme Tile

fileprivate struct ThemeTile: View {

  @Environment(\.colorScheme) private var colorScheme

  let theme: Theme
  let isSelected: Bool
  let onSelect: @MainActor @Sendable () -> Void

  var body: some View {
    Button(action: onSelect) {
      let palette = theme.palette(for: colorScheme)
      VStack(spacing: 10) {
        ZStack {
          RoundedRectangle(cornerRadius: 16, style: .continuous)
            .fill(palette.primaryContainer)

          HStack(spacing: 8) {
            Circle().fill(palette.tint)
            Circle().fill(palette.secondaryContainer)
          }
          .frame(height: 20)
          .padding(16)
        }
        .frame(height: 76)
        .overlay {
          RoundedRectangle(cornerRadius: 16, style: .continuous)
            .strokeBorder(
              isSelected ? palette.tint : palette.outline,
              lineWidth: isSelected ? 2.5 : 1
            )
        }

        Text(theme.name)
          .font(.subheadline)
          .fontWeight(isSelected ? .semibold : .regular)
          .foregroundStyle(.primary)
      }
      .contentShape(Rectangle())
    }
    .buttonStyle(.plain)
  }
}

// MARK: - Previews

#Preview("Onboarding") {
  OnboardingView(onComplete: {})
}

#Preview("Capture Methods") {
  PrimaryContainer(theme: .default) {
    CaptureMethodsPage()
      .background(.appPrimaryContainer)
  }
}

#Preview("Permission Row") {
  PrimaryContainer(theme: .default) {
    VStack(spacing: 14) {
      PermissionRow(icon: "camera", title: "Camera", description: "Take a photo to attach to an entry.", state: .notDetermined, onRequest: {})
      PermissionRow(icon: "waveform", title: "Microphone", description: "Record the sound around you.", state: .granted, onRequest: {})
      PermissionRow(icon: "location", title: "Location", description: "Attach where you are to an entry.", state: .denied, onRequest: {})
    }
    .padding(28)
    .background(.appPrimaryContainer)
  }
}
