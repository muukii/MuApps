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
    .navigationBarTitleDisplayMode(.inline)
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
    case .photo(_, let imageURL, _):
      remoteImage(imageURL, fallback: "photo")
    case .song(_, _, _, _, let artworkURL),
      .podcast(_, _, _, let artworkURL):
      remoteImage(artworkURL, fallback: "music.note")
    case .contact(_, _, let photoURL):
      remoteImage(photoURL, fallback: "person.crop.circle")
    case .media:
      symbol("play.square")
    case .workout:
      symbol("figure.run")
    case .location:
      symbol("mappin.and.ellipse")
    case .motion:
      symbol("figure.walk")
    case .reflection:
      symbol("quote.bubble")
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
    case .photo:
      return "Photo"
    case .song(_, let title, _, _, _):
      return title ?? "Song"
    case .podcast(_, let episode, _, _):
      return episode ?? "Podcast"
    case .media(_, let title, _, _):
      return title ?? "Media"
    case .workout(_, let name, _, _, _):
      return name ?? "Workout"
    case .location(_, let place, let city, _, _):
      return place ?? city ?? "Location"
    case .motion(_, let steps, _):
      return "\(steps) steps"
    case .contact(_, let name, _):
      return name
    case .reflection(_, let prompt):
      return prompt
    }
  }

  private var secondaryText: String? {
    switch element {
    case .photo(_, _, let date):
      return date?.formatted(date: .abbreviated, time: .shortened)
    case .song(_, _, let artist, let album, _):
      return [artist, album].compactMap { $0 }.joined(separator: " · ").nilIfEmpty
    case .podcast(_, _, let show, _):
      return show
    case .media(_, _, let artist, let album):
      return [artist, album].compactMap { $0 }.joined(separator: " · ").nilIfEmpty
    case .workout(_, _, let kcal, let meters, _):
      let parts = [
        kcal.map { "\(Int($0)) kcal" },
        meters.map { String(format: "%.1f km", $0 / 1000) },
      ].compactMap { $0 }
      return parts.joined(separator: " · ").nilIfEmpty
    case .location(_, _, let city, _, _):
      return city
    case .motion(_, _, let interval):
      return interval?.formattedRange
    case .contact:
      return "Contact"
    case .reflection:
      return "Reflection prompt"
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

#Preview {
  NavigationStack {
    SuggestionCaptureDemoView()
  }
}
