import XCTest
@testable import Enigma

final class SearchRoutingTests: XCTestCase {
  private let rows: [(question: String, route: SearchRoute, needsLocation: Bool, namedPlace: String?)] = [
    ("cafe near me", .places, true, nil),
    ("coffee nearby", .places, true, nil),
    ("What are some good restaurants around me?", .places, true, nil),
    ("events near me this weekend", .places, true, nil),
    ("ramen in Soho", .places, false, nil),
    ("will it rain tomorrow", .weather, true, nil),
    ("weather in Paris this weekend", .weather, false, "paris"),
    ("what's the forecast for new york tomorrow", .weather, false, "new york"),
    ("hurricane latest news", .web, false, nil),
    ("average rainfall in Seattle in May", .web, false, nil),
    ("what is weather", .web, false, nil),
    ("taxes in California", .web, false, nil),
    ("history of Rome", .web, false, nil),
    // A weather word with a nearby cue asks for a forecast here.
    ("weather near me", .weather, true, nil),
    ("weather in my area", .weather, true, nil),
    ("local weather", .weather, true, nil),
    ("snow removal near me", .places, true, nil),
    // Weather needs a place or the location; times are never places.
    ("weather in the UK today", .weather, false, "the uk"),
    ("what's the forecast for the weekend", .web, false, nil),
    ("will it rain in 2 hours", .weather, true, nil),
    ("will it rain at 5pm", .weather, true, nil),
    ("will it snow in december", .web, false, nil),
    ("is it going to rain in an hour", .web, false, nil),
    ("Don't use my location. What is the forecast today?", .web, false, nil),
    // Background words keep weather questions on the web.
    ("what's the average temperature in Seattle in May", .web, false, nil),
    ("what's the latest weather news", .web, true, nil),
    // Transformations and opt-outs never route.
    ("Rewrite: good restaurants around me", .web, false, nil),
    ("Don't use my location. cafes near me", .web, false, nil),
    ("Translate: ramen in Soho", .web, false, nil),
    ("Rewrite: will it rain tomorrow", .web, false, nil),
    // "local <place word>" is a nearby question.
    ("local restaurants", .places, true, nil),
    ("local cafes", .places, true, nil),
    // A named area needs a place word before it.
    ("calories in a burger", .web, false, nil),
    ("caffeine in coffee", .web, false, nil),
    ("best pizza at home recipe", .web, false, nil),
    ("how to use bars in matplotlib", .web, false, nil),
    ("best pizza in Brooklyn", .places, false, nil),
    // CP1b: a bare topic word needs a time word, a weather verb or "do i need".
    ("what are the best rain jackets", .web, false, nil),
    ("what's the best snow blower", .web, false, nil),
    ("what are snow tires", .web, false, nil),
    ("is it worth buying a rain gauge", .web, false, nil),
    ("what is the normal body temperature", .web, false, nil),
    ("what is the temperature to bake salmon", .web, false, nil),
    ("what is the boiling temperature of water", .web, false, nil),
    ("what is the temperature of the sun", .web, false, nil),
    ("what is the safe temperature for chicken", .web, false, nil),
    ("what's the internal temperature for medium rare steak", .web, false, nil),
    ("is it raining near me", .weather, true, nil),
    ("will it rain today", .weather, true, nil),
    ("do i need an umbrella today", .weather, true, nil),
    ("what's the temperature outside", .weather, true, nil),
    ("is it snowing in denver today", .weather, false, "denver"),
    // CP1b: every candidate is tried; a time is skipped for the next one.
    ("will it rain in the afternoon in london", .weather, false, "london"),
    ("what's the weather in the evening in rome", .weather, false, "rome"),
    ("what's the weather in rome in the evening", .weather, false, "rome"),
    // CP1b: a time, home, work or school is never the place, so the current location is used.
    ("is it going to rain at noon", .weather, true, nil),
    ("what's the weather at midnight", .weather, true, nil),
    ("will it rain at lunch", .weather, true, nil),
    ("weather at sunrise tomorrow", .weather, true, nil),
    ("what's the weather for christmas", .weather, true, nil),
    ("what's the weather at home today", .weather, true, nil),
    ("will it rain at work today", .weather, true, nil),
    // CP1b: "local" with any place word is a nearby question.
    ("local gyms", .places, true, nil),
    ("local bars", .places, true, nil),
    ("local hotels", .places, true, nil),
    ("local pharmacy", .places, true, nil),
    ("local parks", .places, true, nil),
    ("local libraries", .places, true, nil),
    ("local coffee shops", .places, true, nil),
    ("best local pizza", .places, true, nil),
    ("bars near me", .places, true, nil),
    // CP1b: the ambiguous place words skip the named-area rule.
    ("progress bars in swiftui", .web, false, nil),
    ("add error bars in matplotlib", .web, false, nil),
    ("best json library in python", .web, false, nil),
    ("what is the best logging library in python", .web, false, nil),
    ("bar exam in california", .web, false, nil),
    ("atm in spanish", .web, false, nil),
    // CP1b: with the current location, a place after it is dropped.
    ("weather near me for the marathon", .weather, true, nil),
    ("forecast nearby for hiking", .weather, true, nil),
    // Review round 1: "local" with an ambiguous word in a developer question isn't nearby (D10).
    ("how do i import a local library", .web, false, nil),
    ("pip install local library", .web, false, nil),
    ("best local library for python", .web, false, nil),
    ("how to run a local pub/sub emulator", .web, false, nil),
    ("local-library linking in cmake", .web, false, nil),
    // Review round 1: a place that starts with a holiday or a time of day keeps its name (D10).
    ("what's the weather in easter island", .weather, false, "easter island"),
    ("weather in christmas island today", .weather, false, "christmas island"),
    ("what's the weather in sunrise florida", .weather, false, "sunrise florida"),
    ("what's the weather like in dinner key", .weather, false, "dinner key"),
    ("what's the weather on christmas day", .weather, true, nil),
    // Review round 1: parts of the day use the current location, like noon (D11).
    ("will it rain in the afternoon", .weather, true, nil),
    ("will it rain in the evening", .weather, true, nil),
    ("what's the weather like in the afternoon", .weather, true, nil),
    ("is it going to snow this afternoon", .weather, true, nil),
    // Review round 1: "local <ambiguous word> in <area>" is a named area (D10).
    ("local bars in brooklyn", .places, false, nil),
    ("local parks in denver", .places, false, nil),
    ("best local bars in austin", .places, false, nil),
    // Review round 1: home and the new times are skipped for the place after them (D10).
    ("will it rain at home in boston", .weather, false, "boston"),
    ("will it rain at noon in paris", .weather, false, "paris"),
    ("what's the weather in paris at noon", .weather, false, "paris"),
    ("will it snow at christmas in denver", .weather, false, "denver"),
    // Review round 1: a language is never a named area or a weather place (D10).
    ("restaurant in spanish", .web, false, nil),
    ("what is pharmacy in spanish", .web, false, nil),
    ("hospital in french", .web, false, nil),
    ("gym in german", .web, false, nil),
    ("what's the weather in spanish", .web, false, nil),
    // Review round 1: "temperature in <named place>" is weather; units and "the ..." aren't (D12).
    ("what's the temperature in denver", .weather, false, "denver"),
    ("what's the temperature in fahrenheit", .web, false, nil),
    ("what is the body temperature in celsius", .web, false, nil),
    ("what is the temperature in the oven", .web, false, nil),
    ("what's the temperature", .web, false, nil),
    // Review round 2: "outside" counts only next to the topic word (D15).
    ("what temperature is too cold to sleep outside", .web, false, nil),
    ("what temperature should my house be when it's cold outside", .web, false, nil),
    ("what temperature is too cold for dogs outside", .web, false, nil),
    ("how to keep my dog warm outside in the snow", .web, false, nil),
    ("what's the outside temperature", .weather, true, nil),
    ("is it raining outside", .weather, true, nil),
    // Review round 2: "right now", "now" and "later" end the place (D15).
    ("is it raining in london right now", .weather, false, "london"),
    ("is it raining in tokyo right now", .weather, false, "tokyo"),
    ("what's the temperature in new york city right now", .weather, false, "new york city"),
    ("will it snow in denver later", .weather, false, "denver"),
    // Review round 2: "temperature in <place>" only when the question starts with it (D15).
    ("normal body temperature in adults", .web, false, nil),
    ("the temperature at which chocolate melts", .web, false, nil),
    ("ideal temperature in your bedroom for sleep", .web, false, nil),
    ("what is the normal temperature in dogs", .web, false, nil),
    ("what's the current temperature in denver", .weather, false, "denver"),
    // Review round 2: more weather verbs and "chance of rain" (D15).
    ("is it supposed to rain", .weather, true, nil),
    ("is it gonna rain", .weather, true, nil),
    ("is it gonna snow", .weather, true, nil),
    ("what's the chance of rain", .weather, true, nil),
    ("what are the chances of snow", .weather, true, nil),
    // Review round 2: temperature with a nearby cue is weather, not places (D15).
    ("what's the temperature near me", .weather, true, nil),
    ("what's the temperature in my area", .weather, true, nil),
    ("what's the temperature around me", .weather, true, nil),
    // Review round 2: business how-tos aren't nearby questions (D15).
    ("how to open a local bakery", .web, false, nil),
    ("how to start a local coffee shop", .web, false, nil),
    // Review round 3: "temperature now" questions use the current location (D18).
    ("what's the current temperature", .weather, true, nil),
    ("what is the current temperature", .weather, true, nil),
    ("what's the temperature now", .weather, true, nil),
    ("what temperature is it", .weather, true, nil),
    ("what temperature is it now", .weather, true, nil),
    ("what's the temperature like", .weather, true, nil),
    ("what temperature is it in chicago", .weather, false, "chicago"),
    ("current temperature of the ocean", .web, false, nil),
    ("current temperature of the sun", .web, false, nil),
    // Review round 3: a month or season after in/during is background (D18).
    ("what's the weather like in paris in may", .web, false, nil),
    ("what's the weather like in london in december", .web, false, nil),
    ("what's the weather like in hawaii in january", .web, false, nil),
    ("what's the weather like in rome in the summer", .web, false, nil),
    ("what's the weather like in winter", .web, false, nil),
    // Review round 3: "what's the weather" asks about here and now (D18).
    ("what's the weather", .weather, true, nil),
    ("what is the weather", .weather, true, nil),
    ("what's the weather?", .weather, true, nil),
    // Review round 3: rows that kill the surviving mutants.
    ("will it rain in paris for the marathon", .weather, false, "paris"),
    ("best local library in python", .web, false, nil),
    // D18: a city just before "weather", with only time words after it.
    ("nyc weather today", .weather, false, "nyc"),
    ("london weather tomorrow", .weather, false, "london"),
    ("chicago weather tomorrow", .weather, false, "chicago"),
    ("paris weather", .weather, false, "paris"),
    ("new york city weather forecast", .weather, false, "new york city"),
    ("my weather today", .weather, true, nil),
    ("current weather today", .weather, true, nil),
    ("today weather", .weather, true, nil),
    ("nice weather today", .weather, true, nil),
    ("python weather api", .web, false, nil),
    // Review round 4: "temperature now" patterns match only the whole question (D20).
    ("how do i check my cpu's current temperature?", .web, false, nil),
    ("my baby has a fever, what should i do about her temperature now?", .web, false, nil),
    ("how do i lower my cpu temperature now", .web, false, nil),
    ("nest thermostat current temperature", .web, false, nil),
    ("car outside temperature sensor not working", .web, false, nil),
    ("what's the temperature like in paris", .weather, false, "paris"),
    ("what's the temperature now in london", .weather, false, "london"),
    // Review round 4: descriptive words before "weather" are never the city (D20).
    ("nearby weather", .weather, true, nil),
    ("hourly weather today", .weather, true, nil),
    ("todays weather", .weather, true, nil),
    ("area weather today", .weather, true, nil),
    ("hiking weather today", .weather, true, nil),
    ("perfect weather today", .weather, true, nil),
    // Review round 4: rows that kill the city rule's mutants.
    ("monday weather", .web, false, nil),
    ("home weather today", .weather, true, nil),
    ("swift weather today", .weather, true, nil),
    ("nyc weather is crazy", .web, false, nil),
    ("los angeles county fire weather", .web, false, nil),
    // Review round 5: a descriptive word rejects the city only as the first word (D22).
    ("bay area weather today", .weather, false, "bay area"),
    ("chicago area weather today", .weather, false, "chicago area"),
    ("chicago area weather forecast", .weather, false, "chicago area"),
    ("dc area weather tomorrow", .weather, false, "dc area"),
    ("boston hourly weather today", .weather, false, "boston"),
    ("nyc daily weather forecast", .weather, false, "nyc"),
    ("denver regional weather today", .weather, false, "denver"),
    ("long beach weather today", .weather, false, "long beach"),
    ("miami beach weather today", .weather, false, "miami beach"),
    ("virginia beach weather forecast", .weather, false, "virginia beach"),
    ("beach weather today", .weather, true, nil),
    ("hows the weather today", .weather, true, nil),
    // Review round 5: repeated modifiers (D22).
    ("what's the temperature outside in london", .weather, false, "london"),
    ("what temperature is it outside in london", .weather, false, "london"),
    ("what's the current outside temperature", .weather, true, nil),
    ("what is the current temperature outside now", .weather, true, nil),
    ("what temperature is it outside now?", .weather, true, nil),
    // Review round 5: "what temperature is it" only as the whole question (D22).
    ("what temperature is it safe to eat chicken", .web, false, nil),
    ("what temperature is it when water boils", .web, false, nil),
    ("how do i ask siri what temperature is it", .web, false, nil),
    // Regression probe (D23): descriptive words, languages inside place names, and non-places.
    ("lovely weather today", .weather, true, nil),
    ("camping weather this weekend", .web, false, nil),
    ("world weather", .web, false, nil),
    ("see weather today", .weather, true, nil),
    ("react weather today", .weather, true, nil),
    ("add local library to project", .web, false, nil),
    ("local bar association", .web, false, nil),
    ("weather in dutch harbor today", .weather, false, "dutch harbor"),
    ("what's the weather in latin america", .weather, false, "latin america"),
    ("what's the temperature at the moment", .weather, true, nil),
    ("temperature in refrigerator", .web, false, nil),
    ("what's the temperature in space", .web, false, nil),
    ("what's the temperature on mars", .web, false, nil),
    // Review round 6: "right now", "this weekend" and parts of the day count for a bare topic word only as
    // the whole question or with a place (D24).
    ("my baby's temperature is 101 right now", .web, false, nil),
    ("my temperature is 100.4 right now is that a fever", .web, false, nil),
    ("my baby has a fever this morning, what temperature is too high", .web, false, nil),
    ("how do i lower my cpu temperature right now", .web, false, nil),
    ("snow tires sale this weekend", .web, false, nil),
    ("vail snow this weekend", .web, false, nil),
    ("seattle rain right now", .web, false, nil),
    ("miami temperature this weekend", .web, false, nil),
    ("rain this weekend", .weather, true, nil),
    ("any snow this weekend?", .weather, true, nil),
    ("temperature right now", .weather, true, nil),
    ("rain in seattle this weekend", .weather, false, "seattle"),
    // Review round 6: "forecast" is a now word only after a topic word or as a short question (D24).
    ("sales forecast", .web, false, nil),
    ("sales forecast for q3", .web, false, nil),
    ("how to forecast demand", .web, false, nil),
    ("cash flow forecast excel", .web, false, nil),
    ("nyc forecast", .web, false, nil),
    ("is there rain in the forecast", .web, false, nil),
    ("forecast", .weather, true, nil),
    ("the forecast", .weather, true, nil),
    ("10 day forecast", .weather, true, nil),
    ("hourly forecast tomorrow", .weather, true, nil),
    ("local forecast", .weather, true, nil),
    ("rain forecast", .weather, true, nil),
    // Review round 6: rows that kill the surviving round-5 mutants.
    ("hey what's the weather", .weather, true, nil),
    ("what's the temperature like outside in london", .weather, false, "london"),
    ("cafes in spanish harlem", .places, false, nil),
    // Review round 7: "local forecast for <place>" names the place and needs no location (D27).
    ("what's the local forecast for denver", .weather, false, "denver"),
    ("local forecast for boston tomorrow", .weather, false, "boston"),
    // Review round 7: possessive and command forms of the forecast use the location (D27).
    ("tomorrow's forecast", .weather, true, nil),
    ("today's forecast", .weather, true, nil),
    ("what's tomorrow's forecast", .weather, true, nil),
    ("this weekend's forecast", .weather, true, nil),
    ("check the forecast", .weather, true, nil),
    ("show me the forecast", .weather, true, nil),
    ("how's the forecast looking", .weather, true, nil),
    ("forecast for this weekend", .weather, true, nil),
    // Review round 7: rows that kill the mutants re-opening round 6's leaks.
    ("what's the sales forecast", .web, false, nil),
    ("forecast accuracy formula", .web, false, nil),
    ("the rain this weekend ruined my plans", .web, false, nil),
    // Review round 8: in a forecast-only question, a home or time word is a time only on its own (D29).
    ("what's the forecast for home prices", .web, false, nil),
    ("what's the forecast for home sales next year", .web, false, nil),
    ("what's the forecast for school enrollment", .web, false, nil),
    ("what's the forecast for work orders next quarter", .web, false, nil),
    ("what's the forecast for thanksgiving sales", .web, false, nil),
    ("what's the forecast for breakfast sales", .web, false, nil),
    ("what's the forecast for thanksgiving", .weather, true, nil),
    ("what's the forecast for new year's eve", .weather, true, nil)
  ]

  func testRoutes() {
    for row in rows {
      XCTAssertEqual(SearchRouting.decide(question: row.question),
        SearchRouting.Decision(route: row.route, needsCurrentLocation: row.needsLocation, namedPlace: row.namedPlace),
        row.question)
    }
  }

  func testRouteLocationMatchesLocationIntent() {
    let extra = ["Weather in Copenhagen", "What is the forecast for Paris today?", "Find nearby restaurants in Rome",
      "Explain how weather forecasting works", "Don't use my location. What is the forecast today?",
      "Where am I?", "Do I need an umbrella today?", "Rewrite: good restaurants around me", "swift actors"]
    for question in rows.map(\.question) + extra {
      XCTAssertEqual(SearchRouting.decide(question: question).needsCurrentLocation,
        LocationIntent.needsLocation(question), question)
    }
  }

  func testWeatherHasExactlyOneWayToFindItsPlace() {
    let questions = rows.map(\.question) + ["weather in Paris tomorrow", "will it rain in the morning",
      "what is the weather like at the airport today", "weather around me", "forecast nearby",
      "what's the weather in Évian today", "is it raining in tokyo right now",
      "weather near me for the marathon", "forecast nearby for hiking"]
    for question in questions {
      let decision = SearchRouting.decide(question: question)
      guard decision.route == .weather else { continue }
      XCTAssertTrue(decision.needsCurrentLocation != (decision.namedPlace != nil), question)
    }
  }

  /// A named-city weather question still searches automatically (D20).
  func testNamedCityWeatherNeedsFreshInformation() {
    for question in ["nyc weather today", "london weather tomorrow", "nyc weather forecast",
      "seattle weather this weekend", "what temperature is it in chicago"] {
      XCTAssertFalse(LocationIntent.needsLocation(question), question)
      XCTAssertTrue(WebSearchPolicy.needsFreshInformation(question), question)
    }
  }

  /// A weather question about software isn't fresh information through the weather rule (D22).
  func testWeatherSoftwareQuestionsAreNotWeatherFreshness() {
    for question in ["what's the weather api for python", "what's the best weather app for iphone"] {
      XCTAssertFalse(WebSearchPolicy.needsFreshInformation(question), question)
    }
  }

  /// "local forecast for zip 10001" names its own area: no location (D27). The everyday forecast forms
  /// still count as fresh.
  func testForecastFormsLocationAndFreshness() {
    XCTAssertFalse(LocationIntent.needsLocation("local forecast for zip 10001"))
    for question in ["tomorrow's forecast", "check the forecast", "how's the forecast looking",
      "forecast for this weekend"] {
      XCTAssertTrue(WebSearchPolicy.needsFreshInformation(question), question)
    }
  }

  /// A long draft with many candidates must stay linear: every keystroke runs these patterns.
  /// The bound is far above the expected few milliseconds; the quadratic version took seconds.
  func testLongDraftStaysFast() {
    // Every candidate is a time or home, so the loop has to try them all before "paris".
    let draft = String(repeating: "weather at home in the morning ", count: 2_800) + "in paris"
    let start = Date()
    XCTAssertEqual(LocationIntent.weatherPlace(normalized: draft), "paris")
    _ = SearchRouting.decide(question: draft)
    XCTAssertLessThan(Date().timeIntervalSince(start), 2.0)
  }

  func testWebQueryRewritesNearbyCues() {
    XCTAssertEqual(SearchRouting.webQuery("cafes near me", city: "Chicago"), "cafes near Chicago")
    XCTAssertEqual(SearchRouting.webQuery("What are some good restaurants around me?", city: "Chicago"),
      "What are some good restaurants near Chicago?")
    XCTAssertEqual(SearchRouting.webQuery("weather in my area", city: "Chicago"), "weather near Chicago")
    XCTAssertEqual(SearchRouting.webQuery("swift actors", city: "Chicago"), "swift actors")
    XCTAssertEqual(SearchRouting.webQuery("local cafes", city: "Chicago"), "cafes near Chicago")
    XCTAssertEqual(SearchRouting.webQuery("local gyms", city: "Chicago"), "gyms near Chicago")
    XCTAssertEqual(SearchRouting.webQuery("local pub/sub emulator", city: "Chicago"), "local pub/sub emulator")
    XCTAssertEqual(SearchRouting.webQuery("Best Local Restaurants", city: "Chicago"), "Best Restaurants near Chicago")
    XCTAssertEqual(SearchRouting.webQuery("locally-sourced honey", city: "Chicago"), "locally-sourced honey")
    XCTAssertEqual(SearchRouting.webQuery("cafes near me", city: #"St. $1 \Town"#), #"cafes near St. $1 \Town"#)
  }

  func testWebQueryDropsCueWithoutCity() {
    XCTAssertEqual(SearchRouting.webQuery("cafes near me", city: nil), "cafes")
    XCTAssertEqual(SearchRouting.webQuery("best pizza nearby", city: nil), "best pizza")
    // "local <place word>" is kept without a city: dropping "local" would lose the nearby intent.
    XCTAssertEqual(SearchRouting.webQuery("local cafes", city: nil), "local cafes")
    XCTAssertEqual(SearchRouting.webQuery("local gyms", city: nil), "local gyms")
    XCTAssertEqual(SearchRouting.webQuery("nearby cafes", city: nil), "cafes")
    XCTAssertEqual(SearchRouting.webQuery("events locally tonight", city: nil), "events tonight")
    XCTAssertEqual(SearchRouting.webQuery("What's open around me?", city: nil), "What's open?")
    // Only the cue's surroundings are tidied; the rest stays as written.
    XCTAssertEqual(SearchRouting.webQuery("ratio 5 : 3  near me", city: nil), "ratio 5 : 3")
    for query in ["cafes near me", "best pizza nearby", "What's open around me?", "events locally tonight"] {
      XCTAssertFalse(SearchRouting.webQuery(query, city: nil).contains("current area"), query)
      XCTAssertFalse(SearchRouting.webQuery(query, city: nil).contains("  "), query)
    }
  }
}
