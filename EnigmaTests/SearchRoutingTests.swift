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
    ("best pizza in Brooklyn", .places, false, nil)
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
      "what's the weather in Évian today", "is it raining in tokyo right now"]
    for question in questions {
      let decision = SearchRouting.decide(question: question)
      guard decision.route == .weather else { continue }
      XCTAssertTrue(decision.needsCurrentLocation != (decision.namedPlace != nil), question)
    }
  }

  func testWebQueryRewritesNearbyCues() {
    XCTAssertEqual(SearchRouting.webQuery("cafes near me", city: "Chicago"), "cafes near Chicago")
    XCTAssertEqual(SearchRouting.webQuery("What are some good restaurants around me?", city: "Chicago"),
      "What are some good restaurants near Chicago?")
    XCTAssertEqual(SearchRouting.webQuery("weather in my area", city: "Chicago"), "weather near Chicago")
    XCTAssertEqual(SearchRouting.webQuery("swift actors", city: "Chicago"), "swift actors")
    XCTAssertEqual(SearchRouting.webQuery("local cafes", city: "Chicago"), "cafes near Chicago")
    XCTAssertEqual(SearchRouting.webQuery("Best Local Restaurants", city: "Chicago"), "Best Restaurants near Chicago")
    XCTAssertEqual(SearchRouting.webQuery("locally-sourced honey", city: "Chicago"), "locally-sourced honey")
    XCTAssertEqual(SearchRouting.webQuery("cafes near me", city: #"St. $1 \Town"#), #"cafes near St. $1 \Town"#)
  }

  func testWebQueryDropsCueWithoutCity() {
    XCTAssertEqual(SearchRouting.webQuery("cafes near me", city: nil), "cafes")
    XCTAssertEqual(SearchRouting.webQuery("best pizza nearby", city: nil), "best pizza")
    XCTAssertEqual(SearchRouting.webQuery("local cafes", city: nil), "cafes")
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
