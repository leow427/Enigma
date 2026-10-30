import CoreLocation
import Foundation
import MapKit

/// One place for CP9's map card. In memory only: never saved with a chat.
struct MapPlace: Equatable, Sendable, Identifiable {
  /// `MKMapItem.identifier`, or a stable fallback from the name and coordinate.
  let id: String
  let name: String
  let coordinate: SearchCoordinate
  /// From the user's rounded location, computed on the Mac; nil for a named area.
  let distanceMeters: Double?
}

struct PlaceResult: Equatable, Sendable {
  let place: MapPlace
  let category: String?
  let address: String?
  let phone: String?
  let website: URL?
}

protocol PlaceSearching: Sendable {
  /// Points of interest for `query`, near `coordinate` when given, otherwise with the area in the query.
  func places(matching query: String, near coordinate: SearchCoordinate?) async throws -> [PlaceResult]
}

enum PlaceSearchError: LocalizedError, Equatable {
  case timedOut

  var errorDescription: String? { "Apple Maps didn't answer in time." }
}

/// Apple Maps' local search (spec §6.5): points of interest in a 5 km region around the rounded
/// location, widened to 20 km under 3 places; a named area stays in the query with no region.
struct MapKitPlaceSearch: PlaceSearching {
  static let nearSpanMeters = 5_000.0, wideSpanMeters = 20_000.0
  static let maximumResults = 10, minimumBeforeWidening = 3
  static let timeout: Duration = .seconds(3)

  private let run: @Sendable (_ query: String, _ center: SearchCoordinate?, _ spanMeters: Double?) async throws -> [PlaceResult]
  private let clock: any Clock<Duration>

  init(run: @escaping @Sendable (_ query: String, _ center: SearchCoordinate?, _ spanMeters: Double?) async throws -> [PlaceResult]
         = MapKitPlaceSearch.live,
       clock: any Clock<Duration> = ContinuousClock()) {
    self.run = run
    self.clock = clock
  }

  func places(matching query: String, near coordinate: SearchCoordinate?) async throws -> [PlaceResult] {
    let found = try await LookupTimeLimit.run(Self.timeout, clock: clock, timeoutError: PlaceSearchError.timedOut) {
      [run] in
      guard let coordinate else { return try await run(query, nil, nil) }
      let near = try await run(query, coordinate, Self.nearSpanMeters)
      guard near.count < Self.minimumBeforeWidening else { return near }
      try Task.checkCancellation()
      return try await run(query, coordinate, Self.wideSpanMeters)
    }
    return found.prefix(Self.maximumResults).map { result in
      let distance = coordinate.map { Self.distance(from: $0, to: result.place.coordinate) }
      return PlaceResult(place: MapPlace(id: result.place.id, name: result.place.name,
                                         coordinate: result.place.coordinate, distanceMeters: distance),
                         category: result.category, address: result.address, phone: result.phone, website: result.website)
    }
  }

  static func distance(from origin: SearchCoordinate, to destination: SearchCoordinate) -> Double {
    CLLocation(latitude: origin.latitude, longitude: origin.longitude)
      .distance(from: CLLocation(latitude: destination.latitude, longitude: destination.longitude))
  }

  /// "MKPOICategoryGasStation" → "Gas Station".
  static func categoryName(_ rawValue: String) -> String {
    let name = rawValue.hasPrefix("MKPOICategory") ? String(rawValue.dropFirst("MKPOICategory".count)) : rawValue
    var words = ""
    for character in name {
      if character.isUppercase, !words.isEmpty { words.append(" ") }
      words.append(character)
    }
    return words
  }

  /// The real search. MapKit sees the query and the rounded area only.
  @MainActor static func live(_ query: String, _ center: SearchCoordinate?, _ spanMeters: Double?) async throws -> [PlaceResult] {
    let request = MKLocalSearch.Request()
    request.naturalLanguageQuery = query
    request.resultTypes = .pointOfInterest
    if let center, let spanMeters {
      request.region = MKCoordinateRegion(center: CLLocationCoordinate2D(latitude: center.latitude, longitude: center.longitude),
                                          latitudinalMeters: spanMeters, longitudinalMeters: spanMeters)
    }
    // Started and cancelled on the main actor only; the time limit cancels it.
    nonisolated(unsafe) let search = MKLocalSearch(request: request)
    let response = try await withTaskCancellationHandler { @MainActor in
      try await search.start()
    } onCancel: {
      Task { @MainActor in search.cancel() }
    }
    return response.mapItems.compactMap { item in
      guard let name = item.name, !name.isEmpty else { return nil }
      let location = item.location.coordinate
      let coordinate = SearchCoordinate(latitude: location.latitude, longitude: location.longitude)
      let id = item.identifier?.rawValue ?? "\(name)|\(location.latitude)|\(location.longitude)"
      return PlaceResult(place: MapPlace(id: id, name: name, coordinate: coordinate, distanceMeters: nil),
                         category: item.pointOfInterestCategory.map { categoryName($0.rawValue) },
                         address: item.addressRepresentations?.fullAddress(includingRegion: false, singleLine: true),
                         phone: item.phoneNumber, website: item.url)
    }
  }
}

enum PlaceSearch {
  static let sourceTitle = "Apple Maps"

  /// "https://maps.apple.com/?q=<query>": the query only, never the user's city or coordinates.
  static func sourceURL(query: String) -> URL {
    var components = URLComponents(string: "https://maps.apple.com/")!
    components.queryItems = [URLQueryItem(name: "q", value: query)]
    return components.url!
  }

  /// The text excerpt (kind `.places`), and `places` on the result for the map card.
  static func excerpt(_ places: [PlaceResult], query: String, units: MeasurementUnits) -> WebSearchResult {
    let listed = Array(places.prefix(MapKitPlaceSearch.maximumResults))
    var lines = ["Places from Apple Maps for “\(query)”:"]
    for (index, result) in listed.enumerated() {
      var details: [String] = []
      if let category = result.category, !category.isEmpty { details.append(category) }
      if let address = result.address, !address.isEmpty { details.append(address) }
      if let meters = result.place.distanceMeters { details.append(distance(meters, units: units) + " away") }
      if let phone = result.phone, !phone.isEmpty { details.append("phone " + phone) }
      if let website = result.website { details.append(website.absoluteString) }
      lines.append("\(index + 1). \(result.place.name)" + (details.isEmpty ? "" : " — " + details.joined(separator: "; ")))
    }
    return WebSearchResult(source: WebSearchSource(title: sourceTitle, url: sourceURL(query: query)),
                           snippets: [lines.joined(separator: "\n")], site: sourceTitle, kind: .places,
                           places: listed.map(\.place))
  }

  /// One decimal, in kilometres or miles.
  static func distance(_ meters: Double, units: MeasurementUnits) -> String {
    let posix = Locale(identifier: "en_US_POSIX")
    return units == .us ? String(format: "%.1f mi", locale: posix, meters / 1_609.344)
      : String(format: "%.1f km", locale: posix, meters / 1_000)
  }
}
