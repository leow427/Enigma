import Foundation

/// Chooses weather, places or web from the typed question, however search started.
/// A query a model wrote from a screenshot or selection never chooses a route.
enum SearchRouting {
  struct Decision: Equatable, Sendable {
    let route: SearchRoute
    let needsCurrentLocation: Bool
    /// Weather only; lowercased, from the normalized question.
    let namedPlace: String?
  }

  /// `question` is the typed text with slash commands removed.
  static func decide(question: String) -> Decision {
    let text = WebSearchPolicy.questionText(question)
    let needsLocation = LocationIntent.needsLocation(normalized: text)
    // Weather needs somewhere to look up: the current location or a named place.
    if LocationIntent.asksAboutWeatherNow(normalized: text) {
      let place = LocationIntent.weatherPlace(normalized: text)
      if needsLocation || place != nil {
        return Decision(route: .weather, needsCurrentLocation: needsLocation, namedPlace: needsLocation ? nil : place)
      }
    }
    let nearby = needsLocation && LocationIntent.hasNearbyCue(normalized: text)
    let namedArea = !WebSearchPolicy.isOfflineOrTransformation(text) && !LocationIntent.matches(howTo, text)
      && LocationIntent.matches(placeInArea, text)
    return Decision(route: nearby || namedArea ? .places : .web, needsCurrentLocation: needsLocation, namedPlace: nil)
  }

  /// The query for search sites: nearby cues become "near <city>", or are dropped without one.
  /// Coordinates never go to a search site. Without a city, a query of only a cue becomes empty.
  static func webQuery(_ query: String, city: String?) -> String {
    let city = city.flatMap { $0.isEmpty ? nil : NSRegularExpression.escapedTemplate(for: $0) }
    let local = localPlace.stringByReplacingMatches(in: query, range: NSRange(query.startIndex..., in: query),
      withTemplate: city.map { "$1 near \($0)" } ?? "$1")
    guard let city else {
      // Tidy only where a cue was: the spaces before it, and the start of the query.
      let removed = nearbyWithSpace.stringByReplacingMatches(in: local,
        range: NSRange(local.startIndex..., in: local), withTemplate: "")
      return removed.trimmingCharacters(in: .whitespaces)
    }
    return nearbyPhrase.stringByReplacingMatches(in: local, range: NSRange(local.startIndex..., in: local),
      withTemplate: "near \(city)")
  }

  // Compiled once. All patterns are fixed, tested source literals, never user-provided regexes.
  // Cues are whole words: "locally-sourced" isn't one.
  static let nearbyPhrase = try! NSRegularExpression(
    pattern: #"(?<![\w-])(?:near me|nearby|around me|in my area|locally)(?![\w-])"#, options: .caseInsensitive)
  private static let nearbyWithSpace = try! NSRegularExpression(
    pattern: #"[ \t]*(?<![\w-])(?:near me|nearby|around me|in my area|locally)(?![\w-])"#, options: .caseInsensitive)
  private static let placeWords = #"(?:cafes?|coffee|restaurants?|bars?|pubs?|pharmacy|pharmacies|hospitals?|clinics?|gyms?|hotels?|museums?|parks?|bakery|bakeries|supermarkets?|grocery|gas stations?|petrol stations?|atms?|pizza|sushi|ramen|tacos|burgers?|library|libraries)"#
  static let localPlace = try! NSRegularExpression(
    pattern: #"(?<![\w-])local (\#(placeWords))(?![\w-])"#, options: .caseInsensitive)
  /// A place word, at most two words, then an area: "ramen in soho", "best pizza places in brooklyn".
  /// "Caffeine in coffee" and "calories in a burger" aren't places.
  private static let placeInArea = try! NSRegularExpression(
    pattern: #"\b\#(placeWords)(?: [\w'-]+){0,2} (?:in|at|near) (?!(?:me|my|this|the|here|a|an|home)\b)[a-z]"#)
  private static let howTo = try! NSRegularExpression(pattern: #"^how (?:to|do|does|can|should)\b"#)
}
