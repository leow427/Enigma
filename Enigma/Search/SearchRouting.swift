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
    // "local bars in brooklyn" names an area too, unless it's a developer question ("local library in python").
    let namedArea = !WebSearchPolicy.isOfflineOrTransformation(text) && !LocationIntent.matches(howTo, text)
      && (LocationIntent.matches(placeInArea, text)
        || LocationIntent.matches(localAmbiguousInArea, text) && !LocationIntent.isDeveloperQuestion(text))
    return Decision(route: nearby || namedArea ? .places : .web, needsCurrentLocation: needsLocation, namedPlace: nil)
  }

  /// The query for search sites: nearby cues become "near <city>", or are dropped without one.
  /// Coordinates never go to a search site. Without a city, a query of only a cue becomes empty.
  static func webQuery(_ query: String, city: String?) -> String {
    let city = city.flatMap { $0.isEmpty ? nil : NSRegularExpression.escapedTemplate(for: $0) }
    guard let city else {
      // "local <place word>" stays as written: it still asks for somewhere nearby.
      // Tidy only where a cue was: the spaces before it, and the start of the query.
      let removed = nearbyWithSpace.stringByReplacingMatches(in: query,
        range: NSRange(query.startIndex..., in: query), withTemplate: "")
      return removed.trimmingCharacters(in: .whitespaces)
    }
    let local = localPlace.stringByReplacingMatches(in: query, range: NSRange(query.startIndex..., in: query),
      withTemplate: "$1 near \(city)")
    return nearbyPhrase.stringByReplacingMatches(in: local, range: NSRange(local.startIndex..., in: local),
      withTemplate: "near \(city)")
  }

  // Compiled once. All patterns are fixed, tested source literals, never user-provided regexes.
  // Cues are whole words: "locally-sourced" isn't one.
  static let nearbyPhrase = try! NSRegularExpression(
    pattern: #"(?<![\w-])(?:near me|nearby|around me|in my area|locally)(?![\w-])"#, options: .caseInsensitive)
  private static let nearbyWithSpace = try! NSRegularExpression(
    pattern: #"[ \t]*(?<![\w-])(?:near me|nearby|around me|in my area|locally)(?![\w-])"#, options: .caseInsensitive)
  /// Place words that are rarely about a place before "in": "progress bars in swiftui", "json library in
  /// python", "bar exam in california", "atm in spanish". They route only with a nearby cue.
  private static let ambiguousPlaceWords = #"(?:bars?|parks?|atms?|library|libraries)"#
  /// The place words the named-area rule uses.
  private static let areaPlaceWords = #"(?:cafes?|coffee|restaurants?|pubs?|pharmacy|pharmacies|hospitals?|clinics?|gyms?|hotels?|museums?|bakery|bakeries|supermarkets?|grocery|gas stations?|petrol stations?|pizza|sushi|ramen|tacos|burgers?)"#
  /// Every place word, for "local <place word>".
  static let placeWords = #"(?:\#(areaPlaceWords)|\#(ambiguousPlaceWords))"#
  /// "local" words that a developer question uses too ("local library", "local pub/sub"): they ask
  /// for location only outside how-to and developer questions.
  private static let localVetoWords = #"(?:\#(ambiguousPlaceWords)|pubs?)"#
  /// The place word ends at a word boundary that isn't "/" or "-": "local pub/sub" isn't a pub.
  static let localPlace = try! NSRegularExpression(
    pattern: #"(?<![\w-])local (\#(placeWords))(?![\w/-])"#, options: .caseInsensitive)
  static let localAmbiguousPlace = try! NSRegularExpression(
    pattern: #"(?<![\w-])local \#(localVetoWords)(?![\w/-]| association| exam)"#, options: .caseInsensitive)
  static let localUnambiguousPlace = try! NSRegularExpression(
    pattern: #"(?<![\w-])local (?!\#(localVetoWords)(?![\w/-]))\#(placeWords)(?![\w/-])"#, options: .caseInsensitive)
  /// An area can't start with a, an, the, home, me, my, this or here, or be a language ("in spanish").
  private static let area = #"(?:in|at|near) (?!(?:me|my|this|the|here|a|an|home)\b)(?!\#(LocationIntent.languages)\s*(?:[?.!]|$))[a-z]"#
  /// A place word, at most two words, then an area: "ramen in soho", "best pizza places in brooklyn".
  /// "Caffeine in coffee" and "calories in a burger" aren't places.
  private static let placeInArea = try! NSRegularExpression(
    pattern: #"\b\#(areaPlaceWords)(?: [\w'-]+){0,2} \#(area)"#)
  /// "local bars in brooklyn": an ambiguous word names an area only after "local".
  private static let localAmbiguousInArea = try! NSRegularExpression(
    pattern: #"(?<![\w-])local \#(ambiguousPlaceWords)(?: [\w'-]+){0,2} \#(area)"#)
  static let howTo = try! NSRegularExpression(pattern: #"^how (?:to|do|does|can|should)\b"#)
}
