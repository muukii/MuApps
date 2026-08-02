//
// Copyright (c) 2026 Hiroshi Kimura(Muukii) <muukii.app@gmail.com>
//

import Photos
import SwiftUI

/// Introduces Färg and requests the PhotoKit access needed for copy-free editing.
///
/// The view reports completion to its owner instead of persisting launch state.
/// Photo access remains optional because Färg can open movies from Files.
struct FargOnboardingView: View {

  let onComplete: @MainActor @Sendable () -> Void

  @State private var step: FargOnboardingStep = .start
  @State private var authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
  @State private var isRequestingPhotoAccess = false

  var body: some View {
    FargOnboardingContent(
      step: step,
      photoAccessState: PhotoLibraryAccessState(authorizationStatus),
      isRequestingPhotoAccess: isRequestingPhotoAccess,
      onStart: { step = .photoAccess },
      onContinue: continueFromOnboarding
    )
    .animation(.smooth, value: step)
  }

  private func continueFromOnboarding() {
    switch authorizationStatus {
    case .notDetermined:
      isRequestingPhotoAccess = true
      Task {
        defer { isRequestingPhotoAccess = false }
        authorizationStatus = await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        onComplete()
      }
    case .authorized, .limited, .denied, .restricted:
      onComplete()
    @unknown default:
      onComplete()
    }
  }
}

/// Identifies the two decisions a person makes during first launch.
private enum FargOnboardingStep: Equatable {
  case start
  case photoAccess
}

/// A small presentation model that removes PhotoKit-specific cases from leaf views.
private enum PhotoLibraryAccessState: Equatable {
  case notDetermined
  case granted
  case denied

  init(_ authorizationStatus: PHAuthorizationStatus) {
    switch authorizationStatus {
    case .notDetermined:
      self = .notDetermined
    case .authorized, .limited:
      self = .granted
    case .denied, .restricted:
      self = .denied
    @unknown default:
      self = .denied
    }
  }
}

/// Composes the onboarding regions from preview-friendly display values.
private struct FargOnboardingContent: View {

  let step: FargOnboardingStep
  let photoAccessState: PhotoLibraryAccessState
  let isRequestingPhotoAccess: Bool
  let onStart: @MainActor @Sendable () -> Void
  let onContinue: @MainActor @Sendable () -> Void

  var body: some View {
    ZStack {
      Rectangle()
        .fill(.background)
        .ignoresSafeArea()

      ScrollView {
        switch step {
        case .start:
          FargOnboardingWelcomeScreen()
            .transition(.opacity)
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
        case .photoAccess:
          FargOnboardingPhotoAccessScreen(state: photoAccessState)
            .transition(.opacity)
            .padding(.horizontal, 24)
            .padding(.bottom, 32)
        }
      }
    }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      switch step {
      case .start:
        FargOnboardingActions(
          step: step,
          photoAccessState: .notDetermined,
          isRequestingPhotoAccess: false,
          onAction: onStart
        )
      case .photoAccess:
        FargOnboardingActions(
          step: step,
          photoAccessState: photoAccessState,
          isRequestingPhotoAccess: isRequestingPhotoAccess,
          onAction: onContinue
        )
      }
    }
  }
}

/// Introduces the editing experience before the person is asked for system access.
private struct FargOnboardingWelcomeScreen: View {

  var body: some View {
    VStack(spacing: 24) {
      Spacer(minLength: 24)

      Image("logo-large")
        .resizable()
        .scaledToFit()
        .frame(width: 160)
        .accessibilityHidden(true)

      VStack(spacing: 8) {
        Text("Your LUTs, on every video")
          .font(.title.bold())

        Text("Build a faster path from footage to share.")
          .font(.body)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
      }

      VStack(spacing: 14) {
        FargOnboardingFeatureRow(
          systemImage: "rectangle.stack.fill",
          title: "One clip or a whole batch",
          description: "Apply your own LUT consistently across every video."
        )

        FargOnboardingFeatureRow(
          systemImage: "externaldrive.fill",
          title: "Photos, Files, and external drives",
          description: "Work from your library or connected storage without an extra copy."
        )

        FargOnboardingFeatureRow(
          systemImage: "clock.fill",
          title: "Exports that keep moving",
          description: "When background processing is available, keep exporting after you leave."
        )

        FargOnboardingFeatureRow(
          systemImage: "wind",
          title: "Optical Flow motion blur",
          description:
            "Add smoother motion trails to footage shot without an ND filter on supported iPhones."
        )

        FargOnboardingFeatureRow(
          systemImage: "command",
          title: "From capture to share, with Shortcuts",
          description:
            "Apply a selected LUT to one video, then pass the result to your next action."
        )
      }

      Spacer(minLength: 24)
    }
    .frame(maxWidth: 520)
  }
}

/// Summarizes one production capability without turning the welcome into prose.
private struct FargOnboardingFeatureRow: View {

  let systemImage: String
  let title: LocalizedStringResource
  let description: LocalizedStringResource

  var body: some View {
    HStack(alignment: .top, spacing: 14) {
      Image(systemName: systemImage)
        .font(.headline)
        .foregroundStyle(.tint)
        .frame(width: 38, height: 38)
        .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 3) {
        Text(title)
          .font(.subheadline.weight(.semibold))

        Text(description)
          .font(.caption)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      Spacer(minLength: 0)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// Prepares a person for the optional PhotoKit read/write authorization request.
private struct FargOnboardingPhotoAccessScreen: View {

  let state: PhotoLibraryAccessState

  var body: some View {
    VStack(spacing: 28) {
      Spacer(minLength: 72)

      Image(systemName: accessSymbol)
        .font(.system(size: 64, weight: .medium))
        .foregroundStyle(accessColor)
        .frame(width: 132, height: 132)
        .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 32))
        .accessibilityHidden(true)

      VStack(spacing: 12) {
        Text("Choose your videos")
          .font(.largeTitle.bold())
          .multilineTextAlignment(.center)

        Text(permissionDescription)
          .font(.body)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
          .fixedSize(horizontal: false, vertical: true)
      }
      .frame(maxWidth: 420)

      Spacer(minLength: 32)
    }
    .frame(maxWidth: 520)
  }

  private var accessSymbol: String {
    switch state {
    case .notDetermined:
      "photo.on.rectangle.angled"
    case .granted:
      "checkmark.circle.fill"
    case .denied:
      "exclamationmark.circle.fill"
    }
  }

  private var accessColor: Color {
    switch state {
    case .notDetermined:
      .accentColor
    case .granted:
      .green
    case .denied:
      .secondary
    }
  }

  private var permissionDescription: LocalizedStringResource {
    switch state {
    case .notDetermined:
      "Photos access lets Färg choose videos without an extra copy and save finished movies back to your library."
    case .granted:
      "Photos access is ready. Choose videos without an extra copy and save finished movies back to your library."
    case .denied:
      "Photos access is off. You can still open videos from Files and change access later in the Settings app."
    }
  }
}

/// Keeps the permission request explicit while preserving a Files-only path.
private struct FargOnboardingActions: View {

  /// Liquid Glass adds 12 points horizontally and 7 points vertically around
  /// its label. These dimensions yield a visible 240 by 44 point capsule.
  private static let primaryActionLabelWidth: CGFloat = 216
  private static let primaryActionLabelHeight: CGFloat = 30

  let step: FargOnboardingStep
  let photoAccessState: PhotoLibraryAccessState
  let isRequestingPhotoAccess: Bool
  let onAction: @MainActor @Sendable () -> Void

  var body: some View {
    VStack {
      Button(action: onAction) {
        HStack(spacing: 10) {
          if isRequestingPhotoAccess {
            ProgressView()
          }

          Text(primaryActionTitle)
        }
        .frame(
          width: Self.primaryActionLabelWidth,
          height: Self.primaryActionLabelHeight
        )
      }
      .buttonStyle(.glassProminent)
      .controlSize(.regular)
      .disabled(isRequestingPhotoAccess)
      .accessibilityIdentifier(accessibilityIdentifier)
    }
    .frame(maxWidth: .infinity)
    .padding(.top, 12)
    .padding(.bottom, 12)
  }

  private var primaryActionTitle: LocalizedStringResource {
    switch step {
    case .start:
      "Start"
    case .photoAccess:
      switch photoAccessState {
      case .notDetermined:
        "Allow Photos Access"
      case .granted, .denied:
        "Get Started"
      }
    }
  }

  private var accessibilityIdentifier: String {
    switch step {
    case .start:
      "onboarding-start"
    case .photoAccess:
      "onboarding-continue"
    }
  }
}

/// Owns simulated state so Xcode Preview can replay the complete onboarding flow.
private struct FargOnboardingPreviewHost: View {

  @State private var step: FargOnboardingStep = .start
  @State private var photoAccessState: PhotoLibraryAccessState = .notDetermined

  var body: some View {
    FargOnboardingContent(
      step: step,
      photoAccessState: photoAccessState,
      isRequestingPhotoAccess: false,
      onStart: { step = .photoAccess },
      onContinue: continuePreview
    )
    .animation(.smooth, value: step)
    .animation(.smooth, value: photoAccessState)
  }

  /// Simulates authorization, then resets after completion so the flow is replayable.
  private func continuePreview() {
    switch photoAccessState {
    case .notDetermined:
      photoAccessState = .granted
    case .granted, .denied:
      step = .start
      photoAccessState = .notDetermined
    }
  }
}

#Preview("Onboarding flow") {
  FargOnboardingPreviewHost()
}
