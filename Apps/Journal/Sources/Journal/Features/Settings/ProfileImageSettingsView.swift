#if TINYCURVE_PROFILE_IMAGE
  import ImageCropper
  import ImageIO
  import PhotosUI
  import SwiftUI

  /// Settings destination for the current user's optional public profile image.
  ///
  /// Photos selection and the CloudKit confirmation action stay in the app layer;
  /// `ImageCropper` owns only the reusable visual edit and square JPEG rendering.
  struct ProfileImageSettingsView: View {

    @Environment(JournalUserProfile.self) private var profile

    @State private var selectedPhotoItem: PhotosPickerItem?
    @State private var cropPresentation: ProfileImageCropPresentation?
    @State private var isPreparingSelectedPhoto = false
    @State private var isRemoveConfirmationPresented = false
    @State private var selectionFailureMessage: String?

    var body: some View {
      let photoActionTitle =
        profile.imageData == nil
        ? String(localized: "Choose Photo")
        : String(localized: "Change Photo")

      Form {
        ProfileImagePreviewSection(profile: profile)

        Section {
          PhotosPicker(
            selection: $selectedPhotoItem,
            matching: .images,
            preferredItemEncoding: .current
          ) {
            Label(photoActionTitle, systemImage: "photo.badge.plus")
          }
          .disabled(profile.loadState != .loaded || profile.isBusy || isPreparingSelectedPhoto)

          if profile.imageData != nil {
            Button(role: .destructive) {
              isRemoveConfirmationPresented = true
            } label: {
              Label("Remove Photo", systemImage: "trash")
            }
            .disabled(profile.isBusy || isPreparingSelectedPhoto)
          }
        } header: {
          Text("Profile Photo")
        } footer: {
          Text(
            "Your profile photo is stored in Tinycurve's public CloudKit database and may be shown to other Tinycurve users."
          )
        }
        .settingsListRowBackground()
      }
      .scrollContentBackground(.hidden)
      .background(.background)
      .navigationTitle("Profile")
      .appInlineNavigationTitle()
      .toolbar {
        ToolbarItem(placement: .appTrailingAction) {
          Button {
            Task { await profile.reload() }
          } label: {
            Image(systemName: "arrow.clockwise")
          }
          .disabled(profile.isBusy || isPreparingSelectedPhoto)
          .accessibilityLabel("Reload Profile")
        }
      }
      .overlay {
        if isPreparingSelectedPhoto {
          ProgressView("Preparing Photo")
            .padding()
            .background(.regularMaterial, in: .rect(cornerRadius: 12))
        }
      }
      .task {
        await profile.loadIfNeeded()
      }
      .onChange(of: selectedPhotoItem) { _, item in
        guard let item else { return }
        selectedPhotoItem = nil
        Task { await prepareCrop(from: item) }
      }
      .confirmationDialog(
        "Remove Profile Photo?",
        isPresented: $isRemoveConfirmationPresented,
        titleVisibility: .visible
      ) {
        Button("Remove Photo", role: .destructive) {
          Task { await profile.removeImage() }
        }
        Button("Cancel", role: .cancel) {}
      } message: {
        Text("This removes the photo from your public Tinycurve profile.")
      }
      .alert(
        "Profile Image Unavailable",
        isPresented: profileFailureIsPresented
      ) {
        Button("OK", role: .cancel) {
          profile.clearFailure()
        }
      } message: {
        Text(profile.failure?.message ?? "")
      }
      .alert(
        "Could Not Use Photo",
        isPresented: selectionFailureIsPresented
      ) {
        Button("OK", role: .cancel) {
          selectionFailureMessage = nil
        }
      } message: {
        Text(selectionFailureMessage ?? "")
      }
      .appFullScreenCover(item: $cropPresentation) { presentation in
        ProfileImageCropScreen(
          session: presentation.session,
          onCancel: { cropPresentation = nil },
          onSaved: { cropPresentation = nil }
        )
      }
    }

    private var profileFailureIsPresented: Binding<Bool> {
      Binding(
        get: { profile.failure != nil },
        set: { isPresented in
          if !isPresented {
            profile.clearFailure()
          }
        }
      )
    }

    private var selectionFailureIsPresented: Binding<Bool> {
      Binding(
        get: { selectionFailureMessage != nil },
        set: { isPresented in
          if !isPresented {
            selectionFailureMessage = nil
          }
        }
      )
    }

    @MainActor
    private func prepareCrop(from item: PhotosPickerItem) async {
      guard !isPreparingSelectedPhoto else { return }
      isPreparingSelectedPhoto = true
      defer { isPreparingSelectedPhoto = false }

      do {
        guard let imageData = try await item.loadTransferable(type: Data.self) else {
          throw ProfileImageSelectionError.missingImageData
        }

        // Preserve the picker-provided bytes. This first cropper intentionally
        // does not rotate or normalize EXIF orientation metadata.
        let session = try ImageCropSession(imageData: imageData)
        cropPresentation = ProfileImageCropPresentation(session: session)
      } catch {
        selectionFailureMessage = String(
          localized: "The selected photo could not be prepared for cropping."
        )
      }
    }
  }

  /// Large preview and durable availability state shown above profile actions.
  private struct ProfileImagePreviewSection: View {

    let profile: JournalUserProfile

    var body: some View {
      Section {
        VStack(spacing: 16) {
          ZStack {
            ProfileImageAvatar(imageData: profile.imageData, diameter: 144)

            if profile.isReloading {
              Circle()
                .fill(.black.opacity(0.28))
                .frame(width: 144, height: 144)
              ProgressView()
                .tint(.white)
            }
          }

          switch profile.loadState {
          case .idle, .loading:
            ProgressView("Loading Profile")

          case .loaded:
            Group {
              if profile.imageData == nil {
                Text("Choose a photo to create your Tinycurve profile.")
              } else {
                Text("This photo can identify you in collaborative Tinycurve features.")
              }
            }
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)

          case .unavailable:
            Label(
              "Profile photos require an available iCloud account.",
              systemImage: "icloud.slash"
            )
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)

          case .failed:
            Label("The profile could not be loaded.", systemImage: "exclamationmark.triangle")
              .font(.footnote)
              .foregroundStyle(.secondary)
          }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 12)
      }
      .settingsListRowBackground()
    }
  }

  /// Platform-adaptive crop presentation whose Save button performs the public upload.
  private struct ProfileImageCropScreen: View {

    @Environment(JournalUserProfile.self) private var profile

    let session: ImageCropSession
    let onCancel: @MainActor @Sendable () -> Void
    let onSaved: @MainActor @Sendable () -> Void

    @State private var renderingFailureMessage: String?

    var body: some View {
      NavigationStack {
        ZStack {
          Color.black
            .ignoresSafeArea()

          ImageCropEditor(session: session)
            .padding(24)

          if profile.mutation == .saving {
            Color.black.opacity(0.24)
              .ignoresSafeArea()
            ProgressView("Saving")
              .tint(.white)
              .foregroundStyle(.white)
              .padding()
              .background(.regularMaterial, in: .rect(cornerRadius: 12))
          }
        }
        .navigationTitle("Crop Profile Photo")
        .appInlineNavigationTitle()
        .toolbar {
          ToolbarItem(placement: .cancellationAction) {
            Button("Cancel", action: onCancel)
              .disabled(profile.isBusy)
          }

          ToolbarItem(placement: .confirmationAction) {
            Button("Save") {
              Task { await saveCrop() }
            }
            .disabled(profile.isBusy)
          }
        }
      }
      .frame(minWidth: 420, minHeight: 520)
      .interactiveDismissDisabled(profile.isBusy)
      .alert(
        "Could Not Save Profile Image",
        isPresented: cropFailureIsPresented
      ) {
        Button("OK", role: .cancel) {
          renderingFailureMessage = nil
          profile.clearFailure()
        }
      } message: {
        Text(renderingFailureMessage ?? profile.failure?.message ?? "")
      }
    }

    private var cropFailureIsPresented: Binding<Bool> {
      Binding(
        get: { renderingFailureMessage != nil || profile.failure != nil },
        set: { isPresented in
          if !isPresented {
            renderingFailureMessage = nil
            profile.clearFailure()
          }
        }
      )
    }

    @MainActor
    private func saveCrop() async {
      do {
        // Rendering and CloudKit upload happen only after this explicit Save.
        // Cancelling PhotosPicker or this editor never publishes public data.
        let jpegData = try session.renderJPEG(pixelLength: 512, quality: 0.9)
        if await profile.save(imageData: jpegData) {
          onSaved()
        }
      } catch {
        renderingFailureMessage = String(
          localized: "The cropped profile image could not be rendered."
        )
      }
    }
  }

  /// Cross-platform circular rendering of a saved square profile JPEG.
  struct ProfileImageAvatar: View {

    let imageData: Data?
    let diameter: CGFloat

    var body: some View {
      Group {
        if let image = decodedImage {
          Image(decorative: image, scale: 1, orientation: .up)
            .resizable()
            .aspectRatio(contentMode: .fill)
        } else {
          ZStack {
            Circle()
              .fill(.quaternary)
            Image(systemName: "person.fill")
              .font(.system(size: diameter * 0.46))
              .foregroundStyle(.secondary)
          }
        }
      }
      .frame(width: diameter, height: diameter)
      .clipShape(Circle())
      .overlay {
        Circle()
          .stroke(.primary.opacity(0.12), lineWidth: 1)
      }
      .accessibilityHidden(true)
    }

    private var decodedImage: CGImage? {
      guard let imageData,
        let source = CGImageSourceCreateWithData(imageData as CFData, nil)
      else {
        return nil
      }
      return CGImageSourceCreateImageAtIndex(source, 0, nil)
    }
  }

  /// One full-screen crop edit selected from PhotosPicker.
  private struct ProfileImageCropPresentation: Identifiable {
    let id = UUID()
    let session: ImageCropSession
  }

  /// Local selection failure before a crop session can be created.
  private enum ProfileImageSelectionError: Error {
    case missingImageData
  }
#endif
