import CaptureSuggestions
import JournalVault
import UniformTypeIdentifiers

extension SuggestionCardPayload {

  /// Splits one picked suggestion into intentionally separate card payloads.
  ///
  /// The home composer uses the aggregate initializer below so one selection is
  /// one post. Import or migration workflows can use this helper when they
  /// explicitly want every top-level element to become a separate card; grouped
  /// assets such as Live Photos remain one element/card.
  static func cardPayloads(capturedSuggestion: CapturedSuggestion) -> [SuggestionCardPayload] {
    let payloads = capturedSuggestion.elements.map { capturedElement in
      let element = SuggestionCardElement(capturedElement: capturedElement)
      return SuggestionCardPayload(
        title: capturedSuggestion.title,
        dateInterval: capturedSuggestion.dateInterval,
        elements: [element],
        mediaResources: SuggestionCardMediaResource.mediaResources(
          capturedElement: capturedElement,
          elementID: element.id
        )
      )
    }

    if payloads.isEmpty {
      return [
        SuggestionCardPayload(
          title: capturedSuggestion.title,
          dateInterval: capturedSuggestion.dateInterval,
          elements: []
        )
      ]
    }

    return payloads
  }

  /// Converts the picker-owned capture value into the vault-owned persistence
  /// snapshot used by suggestion cards.
  ///
  /// The single-card composer uses this aggregate shape so one system picker
  /// selection stays one post. `cardPayloads(capturedSuggestion:)` remains
  /// available to importers that intentionally author a multi-card post.
  init(capturedSuggestion: CapturedSuggestion) {
    let convertedElements = capturedSuggestion.elements.map { SuggestionCardElement(capturedElement: $0) }
    let mediaResources = zip(capturedSuggestion.elements, convertedElements).flatMap { capturedElement, element in
      SuggestionCardMediaResource.mediaResources(capturedElement: capturedElement, elementID: element.id)
    }

    self.init(
      title: capturedSuggestion.title,
      dateInterval: capturedSuggestion.dateInterval,
      elements: convertedElements,
      mediaResources: mediaResources
    )
  }
}

private extension SuggestionCardMediaResource {

  static func mediaResources(
    capturedElement: SuggestionElement,
    elementID: UUID
  ) -> [SuggestionCardMediaResource] {
    switch capturedElement {
    case .contact(_, _, let photoURL):
      return compactResource(elementID: elementID, kind: .contactPhoto, url: photoURL)
    case .eventPoster(_, _, let imageURL, _, _, _, _):
      return compactResource(elementID: elementID, kind: .eventPosterImage, url: imageURL)
    case .genericMedia(_, _, _, _, _, let appIconURL):
      return compactResource(elementID: elementID, kind: .genericMediaAppIcon, url: appIconURL)
    case .livePhoto(_, let imageURL, let videoURL, _):
      return [
        resource(elementID: elementID, kind: .livePhotoImage, url: imageURL),
        resource(elementID: elementID, kind: .livePhotoVideo, url: videoURL),
      ]
    case .motion(_, _, _, let iconURL, _):
      return compactResource(elementID: elementID, kind: .motionIcon, url: iconURL)
    case .photo(_, let imageURL, _):
      return [resource(elementID: elementID, kind: .photoImage, url: imageURL)]
    case .podcast(_, _, _, let artworkURL, _):
      return compactResource(elementID: elementID, kind: .podcastArtwork, url: artworkURL)
    case .song(_, _, _, _, let artworkURL, _):
      return compactResource(elementID: elementID, kind: .songArtwork, url: artworkURL)
    case .stateOfMind(_, _, let iconURL):
      return compactResource(elementID: elementID, kind: .stateOfMindIcon, url: iconURL)
    case .video(_, let videoURL, _):
      return [resource(elementID: elementID, kind: .video, url: videoURL)]
    case .workout(_, let workout):
      return compactResource(elementID: elementID, kind: .workoutIcon, url: workout.iconURL)
    case .workoutGroup(_, let group):
      return compactResource(elementID: elementID, kind: .workoutGroupIcon, url: group.iconURL)
    case .location, .locationGroup, .reflection:
      return []
    }
  }

  static func compactResource(
    elementID: UUID,
    kind: SuggestionCardMediaResource.Kind,
    url: URL?
  ) -> [SuggestionCardMediaResource] {
    guard let url else { return [] }
    return [resource(elementID: elementID, kind: kind, url: url)]
  }

  static func resource(
    elementID: UUID,
    kind: SuggestionCardMediaResource.Kind,
    url: URL
  ) -> SuggestionCardMediaResource {
    SuggestionCardMediaResource(
      elementID: elementID,
      kind: kind,
      contentType: url.inferredContentTypeIdentifier
    )
  }
}

private extension URL {

  var inferredContentTypeIdentifier: String? {
    UTType(filenameExtension: pathExtension)?.identifier
  }
}

private extension SuggestionCardElement {

  init(capturedElement: SuggestionElement) {
    switch capturedElement {
    case .contact(let id, let name, let photoURL):
      self = .contact(id: id, name: name, photoURL: photoURL)
    case .eventPoster(let id, let title, let imageURL, let eventStart, let eventEnd, let isHost, let placeName):
      self = .eventPoster(
        id: id,
        title: title,
        imageURL: imageURL,
        eventStart: eventStart,
        eventEnd: eventEnd,
        isHost: isHost,
        placeName: placeName
      )
    case .genericMedia(let id, let title, let artist, let album, let date, let appIconURL):
      self = .genericMedia(
        id: id,
        title: title,
        artist: artist,
        album: album,
        date: date,
        appIconURL: appIconURL
      )
    case .livePhoto(let id, let imageURL, let videoURL, let date):
      self = .livePhoto(id: id, imageURL: imageURL, videoURL: videoURL, date: date)
    case .location(let id, let value):
      self = .location(id: id, value: SuggestionCardLocation(capturedLocation: value))
    case .locationGroup(let id, let locations):
      self = .locationGroup(
        id: id,
        locations: locations.map { SuggestionCardLocation(capturedLocation: $0) }
      )
    case .motion(let id, let steps, let dateInterval, let iconURL, let movementType):
      self = .motion(
        id: id,
        steps: steps,
        dateInterval: dateInterval,
        iconURL: iconURL,
        movementType: movementType.map { SuggestionCardMotionMovement(capturedMovementType: $0) }
      )
    case .photo(let id, let imageURL, let date):
      self = .photo(id: id, imageURL: imageURL, date: date)
    case .podcast(let id, let episode, let show, let artworkURL, let date):
      self = .podcast(id: id, episode: episode, show: show, artworkURL: artworkURL, date: date)
    case .reflection(let id, let prompt):
      self = .reflection(id: id, prompt: prompt)
    case .song(let id, let title, let artist, let album, let artworkURL, let date):
      self = .song(
        id: id,
        title: title,
        artist: artist,
        album: album,
        artworkURL: artworkURL,
        date: date
      )
    case .stateOfMind(let id, let value, let iconURL):
      self = .stateOfMind(id: id, value: SuggestionCardStateOfMind(capturedStateOfMind: value), iconURL: iconURL)
    case .video(let id, let videoURL, let date):
      self = .video(id: id, videoURL: videoURL, date: date)
    case .workout(let id, let value):
      self = .workout(id: id, value: SuggestionCardWorkout(capturedWorkout: value))
    case .workoutGroup(let id, let value):
      self = .workoutGroup(id: id, value: SuggestionCardWorkoutGroup(capturedWorkoutGroup: value))
    }
  }
}

private extension SuggestionCardLocation {

  init(capturedLocation: CapturedSuggestionLocation) {
    self.init(
      place: capturedLocation.place,
      city: capturedLocation.city,
      coordinate: capturedLocation.coordinate.map {
        JournalVault.Coordinate(latitude: $0.latitude, longitude: $0.longitude)
      },
      date: capturedLocation.date,
      isWorkLocation: capturedLocation.isWorkLocation
    )
  }
}

private extension SuggestionCardMotionMovement {

  init(capturedMovementType: CapturedSuggestionMovementType) {
    switch capturedMovementType {
    case .running:
      self = .running
    case .walking:
      self = .walking
    case .runningWalking:
      self = .runningWalking
    }
  }
}

private extension SuggestionCardWorkoutDetails {

  init(capturedDetails: CapturedSuggestionWorkoutDetails) {
    self.init(
      activityTypeRawValue: capturedDetails.activityTypeRawValue,
      localizedName: capturedDetails.localizedName,
      activeEnergyKilocalories: capturedDetails.activeEnergyKilocalories,
      distanceMeters: capturedDetails.distanceMeters,
      averageHeartRateBeatsPerMinute: capturedDetails.averageHeartRateBeatsPerMinute,
      dateInterval: capturedDetails.dateInterval
    )
  }
}

private extension SuggestionCardWorkout {

  init(capturedWorkout: CapturedSuggestionWorkout) {
    self.init(
      details: capturedWorkout.details.map { SuggestionCardWorkoutDetails(capturedDetails: $0) },
      iconURL: capturedWorkout.iconURL,
      route: capturedWorkout.route.map {
        JournalVault.Coordinate(latitude: $0.latitude, longitude: $0.longitude)
      }
    )
  }
}

private extension SuggestionCardWorkoutGroup {

  init(capturedWorkoutGroup: CapturedSuggestionWorkoutGroup) {
    self.init(
      workouts: capturedWorkoutGroup.workouts.map { SuggestionCardWorkout(capturedWorkout: $0) },
      iconURL: capturedWorkoutGroup.iconURL,
      activeEnergyKilocalories: capturedWorkoutGroup.activeEnergyKilocalories,
      averageHeartRateBeatsPerMinute: capturedWorkoutGroup.averageHeartRateBeatsPerMinute,
      duration: capturedWorkoutGroup.duration
    )
  }
}

private extension SuggestionCardStateOfMind {

  init(capturedStateOfMind: CapturedSuggestionStateOfMind) {
    self.init(
      date: capturedStateOfMind.date,
      kindRawValue: capturedStateOfMind.kindRawValue,
      valence: capturedStateOfMind.valence,
      valenceClassificationRawValue: capturedStateOfMind.valenceClassificationRawValue,
      labelRawValues: capturedStateOfMind.labelRawValues,
      associationRawValues: capturedStateOfMind.associationRawValues
    )
  }
}
