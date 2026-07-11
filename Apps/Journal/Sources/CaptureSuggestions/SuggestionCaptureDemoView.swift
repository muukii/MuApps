import SwiftUI

/// Standalone demo harness for `SuggestionCaptureView`, used by the dev gallery to
/// exercise Apple's Journaling Suggestions in isolation.
///
/// It presents the system picker, then renders whatever the user picked as a flat
/// list of `SuggestionElement`s — the same material a real journaling flow would
/// turn into an entry, attachments, or a writing prompt.
public struct SuggestionCaptureDemoView: View {

  @State private var captured: CapturedSuggestion?

  public init() {}

  public var body: some View {
    ScrollView {
      VStack(alignment: .leading, spacing: 24) {
        RequirementsCard()

        SuggestionCaptureView { suggestion in
          captured = suggestion
        }
        .frame(maxWidth: .infinity)

        if let captured {
          CapturedSuggestionView(suggestion: captured)
        }
      }
      .padding()
    }
    .background(.background)
    .navigationTitle("Suggestions")
    #if os(iOS)
    .navigationBarTitleDisplayMode(.inline)
    #endif
  }
}

// MARK: - Fileprivate Views

/// Explains why the picker may show nothing — the framework is inert without the
/// entitlement, a real device, and the Settings opt-in.
private struct RequirementsCard: View {
  var body: some View {
    VStack(alignment: .leading, spacing: 8) {
      Label("Journaling Suggestions", systemImage: "wand.and.stars")
        .font(.headline)

      Text(
        "Apple surfaces on-device moments — photos, music, workouts, places, people — as suggestions. The app only receives the one you tap; the raw signals never leave the system picker."
      )
      .font(.callout)
      .foregroundStyle(.secondary)

      VStack(alignment: .leading, spacing: 4) {
        requirement("Requires the com.apple.developer.journal.allow entitlement")
        requirement("Physical device only — the Simulator shows no suggestions")
        requirement("Enabled in Settings › Privacy & Security, in a supported region")
      }
      .padding(.top, 4)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding()
    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 16))
  }

  private func requirement(_ text: String) -> some View {
    Label(text, systemImage: "checkmark.circle")
      .font(.caption)
      .foregroundStyle(.secondary)
  }
}

/// Renders a resolved suggestion: its title, time span, and each element.
private struct CapturedSuggestionView: View {
  let suggestion: CapturedSuggestion

  var body: some View {
    VStack(alignment: .leading, spacing: 12) {
      VStack(alignment: .leading, spacing: 2) {
        Text(suggestion.title)
          .font(.title3)
          .fontWeight(.bold)
        if let interval = suggestion.dateInterval {
          Text(interval.formattedRange)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }

      if suggestion.isEmpty {
        Text("No resolvable content in this suggestion.")
          .font(.callout)
          .foregroundStyle(.secondary)
      } else {
        ForEach(suggestion.elements) { element in
          SuggestionElementRow(element: element)
        }
      }
    }
    .frame(maxWidth: .infinity, alignment: .leading)
  }
}

/// One row per resolved element. The `switch` is exhaustive, so a new
/// `SuggestionElement` case forces a rendering decision here.
private struct SuggestionElementRow: View {
  let element: SuggestionElement

  var body: some View {
    HStack(alignment: .top, spacing: 12) {
      thumbnail
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 8))

      VStack(alignment: .leading, spacing: 2) {
        Text(primaryText)
          .font(.callout)
          .fontWeight(.medium)
        if let secondaryText {
          Text(secondaryText)
            .font(.caption)
            .foregroundStyle(.secondary)
        }
      }
      Spacer(minLength: 0)
    }
    .padding(12)
    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 12))
  }

  @ViewBuilder
  private var thumbnail: some View {
    switch element {
    case .contact(_, _, let photoURL):
      remoteImage(photoURL, fallback: "person.crop.circle")
    case .eventPoster(_, _, let imageURL, _, _, _, _):
      remoteImage(imageURL, fallback: "calendar.badge.clock")
    case .genericMedia(_, _, _, _, _, let appIconURL):
      remoteImage(appIconURL, fallback: "play.square")
    case .livePhoto(_, let imageURL, _, _):
      remoteImage(imageURL, fallback: "livephoto")
    case .location:
      symbol("mappin.and.ellipse")
    case .locationGroup:
      symbol("map")
    case .motion(_, _, _, let iconURL, _):
      remoteImage(iconURL, fallback: "figure.walk")
    case .photo(_, let imageURL, _):
      remoteImage(imageURL, fallback: "photo")
    case .podcast(_, _, _, let artworkURL, _):
      remoteImage(artworkURL, fallback: "music.note")
    case .reflection:
      symbol("quote.bubble")
    case .song(_, _, _, _, let artworkURL, _):
      remoteImage(artworkURL, fallback: "music.note")
    case .stateOfMind(_, _, let iconURL):
      remoteImage(iconURL, fallback: "heart.text.square")
    case .video:
      symbol("video")
    case .workout(_, let workout):
      remoteImage(workout.iconURL, fallback: "figure.run")
    case .workoutGroup(_, let group):
      remoteImage(group.iconURL, fallback: "figure.mixed.cardio")
    }
  }

  private func remoteImage(_ url: URL?, fallback: String) -> some View {
    AsyncImage(url: url) { image in
      image.resizable().scaledToFill()
    } placeholder: {
      symbol(fallback)
    }
  }

  private func symbol(_ name: String) -> some View {
    ZStack {
      Color.accentColor.opacity(0.15)
      Image(systemName: name)
        .foregroundStyle(.tint)
    }
  }

  private var primaryText: String {
    switch element {
    case .contact(_, let name, _):
      return name
    case .eventPoster(_, let title, _, _, _, _, _):
      return title.nilIfEmpty ?? "Event"
    case .genericMedia(_, let title, _, _, _, _):
      return title ?? "Media"
    case .livePhoto:
      return "Live Photo"
    case .location(_, let value):
      return value.place ?? value.city ?? "Location"
    case .locationGroup(_, let locations):
      return "\(locations.count) locations"
    case .motion(_, let steps, _, _, _):
      return "\(steps) steps"
    case .photo:
      return "Photo"
    case .podcast(_, let episode, _, _, _):
      return episode ?? "Podcast"
    case .reflection(_, let prompt):
      return prompt
    case .song(_, let title, _, _, _, _):
      return title ?? "Song"
    case .stateOfMind:
      return "State of Mind"
    case .video:
      return "Video"
    case .workout(_, let workout):
      return workout.details?.localizedName ?? "Workout"
    case .workoutGroup(_, let group):
      return "\(group.workouts.count) workouts"
    }
  }

  private var secondaryText: String? {
    switch element {
    case .contact:
      return "Contact"
    case .eventPoster(_, _, _, let eventStart, let eventEnd, let isHost, let placeName):
      let role = isHost == true ? "Host" : nil
      let date = eventStart.map { start in
        if let eventEnd {
          return DateInterval(start: start, end: eventEnd).formattedRange
        }
        return start.formatted(date: .abbreviated, time: .shortened)
      }
      return [placeName, date, role].compactMap { $0 }.joined(separator: " · ").nilIfEmpty
    case .genericMedia(_, _, let artist, let album, let date, _):
      return [artist, album, date?.formatted(date: .abbreviated, time: .shortened)]
        .compactMap { $0 }
        .joined(separator: " · ")
        .nilIfEmpty
    case .livePhoto(_, _, _, let date):
      return date?.formatted(date: .abbreviated, time: .shortened)
    case .location(_, let value):
      return value.city
    case .locationGroup(_, let locations):
      return locations.compactMap(\.city).joined(separator: " · ").nilIfEmpty
    case .motion(_, _, let interval, _, let movementType):
      return [movementType?.displayTitle, interval?.formattedRange]
        .compactMap { $0 }
        .joined(separator: " · ")
        .nilIfEmpty
    case .photo(_, _, let date):
      return date?.formatted(date: .abbreviated, time: .shortened)
    case .podcast(_, _, let show, _, let date):
      return [show, date?.formatted(date: .abbreviated, time: .shortened)]
        .compactMap { $0 }
        .joined(separator: " · ")
        .nilIfEmpty
    case .reflection:
      return "Reflection prompt"
    case .song(_, _, let artist, let album, _, let date):
      return [artist, album, date?.formatted(date: .abbreviated, time: .shortened)]
        .compactMap { $0 }
        .joined(separator: " · ")
        .nilIfEmpty
    case .stateOfMind(_, let value, _):
      return "Valence \(value.valence.formatted(.number.precision(.fractionLength(2))))"
    case .video(_, _, let date):
      return date?.formatted(date: .abbreviated, time: .shortened)
    case .workout(_, let workout):
      let details = workout.details
      let parts = [
        details?.activeEnergyKilocalories.map { "\(Int($0)) kcal" },
        details?.distanceMeters.map { String(format: "%.1f km", $0 / 1000) },
        details?.averageHeartRateBeatsPerMinute.map { "\(Int($0)) bpm" },
        details?.dateInterval?.formattedRange,
      ].compactMap { $0 }
      return parts.joined(separator: " · ").nilIfEmpty
    case .workoutGroup(_, let group):
      let parts = [
        group.activeEnergyKilocalories.map { "\(Int($0)) kcal" },
        group.duration.map(\.formattedDuration),
      ].compactMap { $0 }
      return parts.joined(separator: " · ").nilIfEmpty
    }
  }
}

// MARK: - Formatting Helpers

extension DateInterval {
  fileprivate var formattedRange: String {
    let style = Date.IntervalFormatStyle(date: .abbreviated, time: .shortened)
    return style.format(start..<end)
  }
}

extension String {
  fileprivate var nilIfEmpty: String? { isEmpty ? nil : self }
}

private extension CapturedSuggestionMovementType {

  var displayTitle: String {
    switch self {
    case .running:
      return "Running"
    case .walking:
      return "Walking"
    case .runningWalking:
      return "Running + Walking"
    }
  }
}

private extension TimeInterval {

  var formattedDuration: String {
    let minutes = Int((self / 60).rounded())
    if minutes < 60 {
      return "\(minutes) min"
    }

    let hours = minutes / 60
    let remainingMinutes = minutes % 60
    return remainingMinutes == 0 ? "\(hours) hr" : "\(hours) hr \(remainingMinutes) min"
  }
}

#Preview {
  NavigationStack {
    SuggestionCaptureDemoView()
  }
}
