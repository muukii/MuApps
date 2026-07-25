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

  @State private var authorizationStatus = PHPhotoLibrary.authorizationStatus(for: .readWrite)
  @State private var isRequestingPhotoAccess = false

  var body: some View {
    FargOnboardingContent(
      photoAccessState: PhotoLibraryAccessState(authorizationStatus),
      isRequestingPhotoAccess: isRequestingPhotoAccess,
      onContinue: continueFromOnboarding
    )
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

/// A small presentation model that removes PhotoKit-specific cases from leaf views.
private enum PhotoLibraryAccessState {
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

  let photoAccessState: PhotoLibraryAccessState
  let isRequestingPhotoAccess: Bool
  let onContinue: @MainActor @Sendable () -> Void

  var body: some View {
    ZStack {
      Rectangle()
        .fill(.background)
        .ignoresSafeArea()

      ScrollView {
        VStack(spacing: 40) {
          Spacer(minLength: 24)

          FargOnboardingHero()

          PhotoLibraryPermissionCard(state: photoAccessState)
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 32)
      }
    }
    .safeAreaInset(edge: .bottom, spacing: 0) {
      FargOnboardingActions(
        photoAccessState: photoAccessState,
        isRequestingPhotoAccess: isRequestingPhotoAccess,
        onContinue: onContinue
      )
    }
  }
}

/// Presents the app's color-editing purpose before asking for system access.
private struct FargOnboardingHero: View {

  var body: some View {
    VStack(spacing: 24) {
      Image("logo-large")
        .resizable()
        .scaledToFit()
        .frame(width: 160)
        .accessibilityHidden(true)

      VStack(spacing: 12) {
        Text("Welcome to Färg")
          .font(.largeTitle.bold())

        Text("Apply your LUTs to one video or a whole batch, then export each finished movie.")
          .font(.body)
          .foregroundStyle(.secondary)
          .multilineTextAlignment(.center)
      }
    }
    .frame(maxWidth: 520)
  }
}

/// Explains why PhotoKit read/write access is useful and reflects its current state.
private struct PhotoLibraryPermissionCard: View {

  let state: PhotoLibraryAccessState

  var body: some View {
    HStack(alignment: .top, spacing: 16) {
      Image(systemName: "photo.on.rectangle.angled")
        .font(.title2)
        .foregroundStyle(.tint)
        .frame(width: 48, height: 48)
        .background(.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 14))
        .accessibilityHidden(true)

      VStack(alignment: .leading, spacing: 6) {
        Text("Photos Access")
          .font(.headline)

        Text(permissionDescription)
          .font(.subheadline)
          .foregroundStyle(.secondary)
          .fixedSize(horizontal: false, vertical: true)
      }

      Spacer(minLength: 0)

      switch state {
      case .notDetermined:
        EmptyView()
      case .granted:
        Image(systemName: "checkmark.circle.fill")
          .font(.title2)
          .foregroundStyle(.green)
          .accessibilityLabel("Photos access granted")
      case .denied:
        Image(systemName: "exclamationmark.circle.fill")
          .font(.title2)
          .foregroundStyle(.secondary)
          .accessibilityLabel("Photos access not granted")
      }
    }
    .padding(20)
    .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24))
    .frame(maxWidth: 520)
  }

  private var permissionDescription: LocalizedStringResource {
    switch state {
    case .notDetermined, .granted:
      "Choose videos without making an extra copy, then save finished movies to Photos."
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

  let photoAccessState: PhotoLibraryAccessState
  let isRequestingPhotoAccess: Bool
  let onContinue: @MainActor @Sendable () -> Void

  var body: some View {
    VStack {
      Button(action: onContinue) {
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
      .accessibilityIdentifier("onboarding-continue")
    }
    .frame(maxWidth: .infinity)
    .padding(.top, 12)
    .padding(.bottom, 12)
  }

  private var primaryActionTitle: LocalizedStringResource {
    switch photoAccessState {
    case .notDetermined:
      "Allow Photos Access"
    case .granted, .denied:
      "Get Started"
    }
  }
}

#Preview {
  FargOnboardingContent(
    photoAccessState: .notDetermined,
    isRequestingPhotoAccess: false,
    onContinue: {}
  )
}
