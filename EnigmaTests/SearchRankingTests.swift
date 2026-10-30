import XCTest
@testable import Enigma

final class SearchRankingTests: XCTestCase {
  private func url(_ string: String) -> URL { URL(string: string)! }

  private func result(_ link: String, position: Int, title: String = "Title", snippet: String = "Snippet") -> EngineResult {
    EngineResult(title: title, url: url(link), snippet: snippet, position: position, engine: .duckDuckGo)
  }

  private func candidate(_ link: String, score: Double, domain: String? = nil, position: Int = 1) -> RankedCandidate {
    let address = url(link)
    return RankedCandidate(url: address, title: "T", snippet: "S", positions: [.duckDuckGo: position], score: score,
                           domain: domain ?? SourceQualityFixture.suffixes.registrableDomain(of: address.host()!)!)
  }

  // MARK: Cleaning

  func testNormalizationKey() {
    let pairs = [
      ("http://www.example.com/a/", "https://example.com/a"),
      ("https://m.example.com/a#x", "https://example.com/a"),
      ("https://example.com/a?b=2&a=1", "https://example.com/a?a=1&b=2"),
      ("https://amp.example.com/a/amp", "https://example.com/a"),
      ("https://example.com/a?amp=1", "https://example.com/a"),
      ("https://mobile.example.com/a?outputType=amp", "https://EXAMPLE.com:443/a"),
      ("http://example.com:80/", "https://example.com"),
      ("https://example.com/a?utm_source=x", "https://example.com/a"),
    ]
    for (left, right) in pairs {
      XCTAssertEqual(URLNormalizer.key(url(left)), URLNormalizer.key(url(right)), "\(left) vs \(right)")
    }
    XCTAssertNotEqual(URLNormalizer.key(url("https://example.com/a")), URLNormalizer.key(url("https://example.com/b")))
    XCTAssertNotEqual(URLNormalizer.key(url("https://example.com/a?id=1")), URLNormalizer.key(url("https://example.com/a?id=2")))
    XCTAssertNotEqual(URLNormalizer.key(url("https://example.com:8443/a")), URLNormalizer.key(url("https://example.com/a")))
    XCTAssertNotEqual(URLNormalizer.key(url("https://example.com/A")), URLNormalizer.key(url("https://example.com/a")))
  }

  func testNormalizationKeyDoesNotOverMerge() {
    XCTAssertNotEqual(URLNormalizer.key(url("https://en.wikipedia.org/wiki/AMP")),
                      URLNormalizer.key(url("https://en.wikipedia.org/wiki")))
    XCTAssertNotEqual(URLNormalizer.key(url("https://example.com/doc?outputType=pdf")),
                      URLNormalizer.key(url("https://example.com/doc?outputType=html")))
    XCTAssertNotEqual(URLNormalizer.key(url("https://example.com/a?amp=0")), URLNormalizer.key(url("https://example.com/a")))
    XCTAssertEqual(URLNormalizer.key(url("https://mobile.de/x")), "mobile.de/x")
    XCTAssertEqual(URLNormalizer.key(url("https://www.mobile.de/x")), URLNormalizer.key(url("https://mobile.de/x")))
    XCTAssertEqual(URLNormalizer.key(url("https://m.example.com/x")), "example.com/x")
  }

  func testTrackingParametersRemoved() {
    XCTAssertEqual(URLNormalizer.clean(url("https://example.com/a?utm_source=x&id=7&fbclid=y")),
                   url("https://example.com/a?id=7"))
    XCTAssertEqual(URLNormalizer.clean(url("https://example.com/a?gclid=1&UTM_Medium=2&ref_src=3&_hsenc=4")),
                   url("https://example.com/a"))
    XCTAssertEqual(URLNormalizer.clean(url("https://example.com/a?b=1&a=2#top")), url("https://example.com/a?b=1&a=2#top"))
    for name in ["gclid", "dclid", "gbraid", "wbraid", "fbclid", "msclkid", "mc_cid", "mc_eid", "igshid", "yclid",
                 "_hsenc", "_hsmi", "ref_src"] {
      XCTAssertTrue(URLNormalizer.trackingParameters.contains(name), name)
    }
  }

  func testAMPCacheUnwrapped() {
    XCTAssertEqual(URLNormalizer.clean(url("https://example-com.cdn.ampproject.org/c/s/example.com/a")),
                   url("https://example.com/a"))
    XCTAssertEqual(URLNormalizer.clean(url("https://www.google.com/amp/s/example.com/a")), url("https://example.com/a"))
    XCTAssertEqual(URLNormalizer.clean(url("https://example-com.cdn.ampproject.org/c/example.com/a?x=1")),
                   url("http://example.com/a?x=1"))
  }

  func testRedirectWrappersUnwrapped() {
    XCTAssertEqual(
      URLNormalizer.clean(url("https://duckduckgo.com/l/?uddg=https%3A%2F%2Fexample.com%2Fa%3Fid%3D7&rut=abc")),
      url("https://example.com/a?id=7"))
    XCTAssertEqual(URLNormalizer.clean(url("https://www.google.com/url?q=https://example.com/a&sa=U")),
                   url("https://example.com/a"))
  }

  func testSearchSiteLinksDropped() {
    for link in [
      "https://duckduckgo.com/?q=swift", "https://html.duckduckgo.com/html/?q=swift",
      "https://www.startpage.com/sp/search?query=swift", "https://www.startpage.com/do/search?q=swift",
      "https://www.mojeek.com/search?q=swift", "https://www.google.com/search?q=swift",
      "https://www.google.co.uk/search?q=swift", "https://www.bing.com/search?q=swift",
      "https://duckduckgo.com/l/?uddg=https%3A%2F%2Fwww.bing.com%2Fsearch%3Fq%3Dx",
    ] {
      XCTAssertNil(URLNormalizer.clean(url(link)), link)
    }
    // Other pages on those sites aren't result pages.
    XCTAssertNotNil(URLNormalizer.clean(url("https://support.google.com/accounts/answer/1")))
    XCTAssertNotNil(URLNormalizer.clean(url("https://www.google.com/maps/place/x")))
  }

  func testUnsafeURLsDropped() {
    XCTAssertNil(URLNormalizer.clean(url("ftp://example.com/file")))
    XCTAssertNil(URLNormalizer.clean(url("javascript:alert(1)")))
    XCTAssertNil(URLNormalizer.clean(url("https://user:pw@example.com/")))
    XCTAssertNil(URLNormalizer.clean(url("https://user@example.com/")))
    XCTAssertNil(URLNormalizer.clean(url("https://example.com/" + String(repeating: "a", count: 2_040))))
    XCTAssertNotNil(URLNormalizer.clean(url("https://example.com/" + String(repeating: "a", count: 2_000))))
    XCTAssertNil(URLNormalizer.clean(url("https:///path-only")))
  }

  // MARK: Merging

  func testMergeScoresLikeSearXNG() {
    // Spec §3.3's numbers. CP0b dropped Mojeek, so the two-site case is checked on the formula itself.
    XCTAssertEqual(ResultRanking.agreementScore([(weight: 1.0, position: 1), (weight: 0.8, position: 3)]),
                   1.6 / 1 + 1.6 / 3, accuracy: 1e-9)
    XCTAssertEqual(ResultRanking.agreementScore([(weight: 1.0, position: 1), (weight: 0.8, position: 3)]),
                   2.133_333_333_3, accuracy: 1e-9)
    XCTAssertEqual(ResultRanking.agreementScore([(weight: 1.0, position: 1)]), 1.0, accuracy: 1e-9)
    XCTAssertEqual(ResultRanking.agreementScore([(weight: 0.8, position: 1)]), 0.8, accuracy: 1e-9)

    let merged = ResultRanking.merge(
      [result("https://example.com/a", position: 1), result("https://example.org/b", position: 4)],
      weights: [.duckDuckGo: 1.0], quality: SourceQualityFixture.quality())
    XCTAssertEqual(merged.map(\.url), [url("https://example.com/a"), url("https://example.org/b")])
    XCTAssertEqual(merged[0].score, 1.0, accuracy: 1e-9)
    XCTAssertEqual(merged[1].score, 0.25, accuracy: 1e-9)
    XCTAssertEqual(merged[1].domain, "example.org")
    XCTAssertEqual(merged[1].positions, [.duckDuckGo: 4])
  }

  func testMergeUsesTheTunedEngineWeight() {
    XCTAssertEqual(DuckDuckGoEngine().weight, RankingTuning.engineWeights[.duckDuckGo])
    let merged = ResultRanking.merge([result("https://example.com/a", position: 2)], weights: [.duckDuckGo: 0.5],
                                     quality: SourceQualityFixture.quality())
    XCTAssertEqual(merged[0].score, 0.25, accuracy: 1e-9)
  }

  func testMergeKeepsLongerTitleAndSnippet() {
    let merged = ResultRanking.merge([
      result("https://www.example.com/a/", position: 1, title: "Short", snippet: "A much longer snippet here"),
      result("https://example.com/a?utm_source=x", position: 3, title: "A longer title", snippet: "Short"),
    ], weights: [.duckDuckGo: 1.0], quality: SourceQualityFixture.quality())
    XCTAssertEqual(merged.count, 1)
    XCTAssertEqual(merged[0].title, "A longer title")
    XCTAssertEqual(merged[0].snippet, "A much longer snippet here")
    XCTAssertEqual(merged[0].positions, [.duckDuckGo: 1], "best position per site")
    XCTAssertEqual(merged[0].score, 1.0, accuracy: 1e-9)
    XCTAssertEqual(merged[0].url, url("https://www.example.com/a/"), "the first link is kept for fetching")
  }

  func testMergeDropsUncleanLinks() {
    let merged = ResultRanking.merge([
      result("https://duckduckgo.com/?q=x", position: 1),
      result("https://example-com.cdn.ampproject.org/c/s/example.com/a", position: 2),
    ], weights: [.duckDuckGo: 1.0], quality: SourceQualityFixture.quality())
    XCTAssertEqual(merged.map(\.url), [url("https://example.com/a")])
    XCTAssertEqual(merged[0].positions, [.duckDuckGo: 2])
  }

  // MARK: Selecting

  func testSelectAppliesTrustThenCutoff() {
    let quality = SourceQualityFixture.quality()
    let selection = ResultRanking.select([
      candidate("https://top.example/", score: 2.0),
      candidate("https://dropped.example/", score: 0.29),
      candidate("https://kept.example/", score: 0.31),
    ], quality: quality)
    XCTAssertEqual(selection.readQueue.map(\.domain), ["top.example", "kept.example"])
    XCTAssertTrue(selection.snippetOnly.isEmpty)

    // Trust applies before the cut-off (0.3): 0.25 × 1.3 = 0.325 stays, 0.7 × 0.5 = 0.35 stays, 0.25 goes.
    let trusted = ResultRanking.select([
      candidate("https://top.example/", score: 2.0),
      candidate("https://www.cdc.gov/flu", score: 0.25),
      candidate("https://www.pinterest.com/pin/1", score: 0.7),
      candidate("https://plain.example/", score: 0.25),
    ], quality: quality)
    XCTAssertEqual(trusted.readQueue.map(\.domain), ["top.example", "cdc.gov"])
    XCTAssertEqual(trusted.readQueue[1].score, 0.325, accuracy: 1e-9)
    XCTAssertEqual(trusted.snippetOnly.map(\.domain), ["pinterest.com"])
    XCTAssertEqual(trusted.snippetOnly[0].score, 0.35, accuracy: 1e-9)

    // A trusted page can overtake the top one; the cut-off is measured from the new top.
    let overtaken = ResultRanking.select([
      candidate("https://top.example/", score: 1.0),
      candidate("https://reliable.example/", score: 0.9),
    ], quality: quality)
    XCTAssertEqual(overtaken.readQueue.map(\.domain), ["reliable.example", "top.example"])
  }

  func testCutoffIsMeasuredAfterTrust() {
    // Pinterest's raw 2.0 is 1.0 after its 0.5 factor, so the cut-off is 0.15, not 0.3.
    let selection = ResultRanking.select([
      candidate("https://www.pinterest.com/pin/1", score: 2.0),
      candidate("https://plain.example/", score: 0.2),
    ], quality: SourceQualityFixture.quality())
    XCTAssertEqual(selection.readQueue.map(\.domain), ["plain.example"])
    XCTAssertEqual(selection.snippetOnly.map(\.domain), ["pinterest.com"])
  }

  func testCandidateExactlyAtTheCutoffIsKept() {
    let selection = ResultRanking.select([
      candidate("https://top.example/", score: 2.0),
      candidate("https://edge.example/", score: 0.3),
    ], quality: SourceQualityFixture.quality())
    XCTAssertEqual(selection.readQueue.map(\.domain), ["top.example", "edge.example"])
  }

  func testSelectOnePerDomain() {
    let selection = ResultRanking.select([
      candidate("https://example.com/a", score: 1.0),
      candidate("https://www.example.com/b", score: 0.9),
      candidate("https://example.org/c", score: 0.8),
    ], quality: SourceQualityFixture.quality())
    XCTAssertEqual(selection.readQueue.map(\.url.absoluteString), ["https://example.com/a", "https://example.org/c"])
    XCTAssertEqual(selection.snippetOnly.map(\.url.absoluteString), ["https://www.example.com/b"])
  }

  func testSelectNeverReturnsBlocked() {
    let quality = SourceQualityFixture.quality(userBlocked: ["userblocked.example"])
    let selection = ResultRanking.select([
      candidate("https://spam.example/", score: 3.0),
      candidate("https://fabricator.example/", score: 2.5),
      candidate("https://a.userblocked.example/", score: 2.2),
      candidate("https://good.example/", score: 1.0),
    ], quality: quality)
    XCTAssertEqual(selection.readQueue.map(\.domain), ["good.example"])
    XCTAssertTrue(selection.snippetOnly.isEmpty)
  }

  func testUnreadableGoesToSnippetOnly() {
    let selection = ResultRanking.select([
      candidate("https://www.youtube.com/watch?v=1", score: 3.0),
      candidate("https://good.example/", score: 1.0),
    ], quality: SourceQualityFixture.quality())
    XCTAssertEqual(selection.readQueue.map(\.domain), ["good.example"])
    XCTAssertEqual(selection.snippetOnly.map(\.domain), ["youtube.com"])
  }

  func testTiesFavourTrust() {
    // 1.0 × 1.15 and 1.15 × 1.0 tie; the reliable source goes first (decision D53).
    let selection = ResultRanking.select([
      candidate("https://plain.example/", score: 1.15),
      candidate("https://reliable.example/", score: 1.0),
    ], quality: SourceQualityFixture.quality())
    XCTAssertEqual(selection.readQueue.map(\.domain), ["reliable.example", "plain.example"])
  }

  func testEqualScoreAndTrustFavourBetterPosition() {
    // Same score and trust: position 1 beats position 3, though "a.example" sorts first by key.
    let selection = ResultRanking.select([
      candidate("https://a.example/", score: 1.0, position: 3),
      candidate("https://b.example/", score: 1.0, position: 1),
    ], quality: SourceQualityFixture.quality())
    XCTAssertEqual(selection.readQueue.map(\.domain), ["b.example", "a.example"])
  }

  func testSelectEmpty() {
    XCTAssertEqual(ResultRanking.select([], quality: SourceQualityFixture.quality()),
                   ResultRanking.Selection(readQueue: [], snippetOnly: []))
  }
}
