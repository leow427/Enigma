import XCTest
@testable import Enigma

/// A small in-memory bundle for `SourceQuality` tests.
enum SourceQualityFixture {
  static let suffixes = PublicSuffixList(contents: """
    // Test rules
    com
    org
    net
    example
    uk
    co.uk
    gov.uk
    nhs.uk
    jp
    *.kawasaki.jp
    !city.kawasaki.jp
    github.io
    公司.cn
    cn
    """)

  static func bundle(
    unsafe: [String] = ["malware.example"],
    spam: [String] = ["spam.example"],
    reliability: [String: SourceReliability] = [
      "reliable.example": .generallyReliable, "tabloid.example": .generallyUnreliable,
      "fabricator.example": .deprecated, "spamfarm.example": .blacklisted, "mixed.example": .noConsensus,
    ],
    authoritySuffixes: [String] = [".gov", ".gov.uk", ".edu"],
    authorityDomains: Set<String> = ["developer.apple.com", "nhs.uk"],
    unreadable: Set<String> = ["pinterest.com", "youtube.com", "tabloid.example"],
    enigmaBlocked: Set<String> = ["curated-bad.example"],
    overrides: [String: SourceOverride] = [:],
    authorityExclusions: Set<String> = []
  ) -> SearchDataBundle {
    SearchDataBundle(
      publicSuffixes: suffixes, unsafe: DomainHashSet(domains: unsafe), spam: DomainHashSet(domains: spam),
      reliability: reliability, authoritySuffixes: authoritySuffixes, authorityDomains: authorityDomains,
      unreadable: unreadable, enigmaBlocked: enigmaBlocked, overrides: overrides,
      authorityExclusions: authorityExclusions)
  }

  static func quality(userBlocked: Set<String> = []) -> SourceQuality {
    SourceQuality(data: bundle(), userBlocked: userBlocked)
  }
}

final class SourceQualityTests: XCTestCase {
  private func url(_ string: String) -> URL { URL(string: string)! }

  // MARK: Hashes and the hash set

  func testFNV1aMatchesScriptVectors() {
    XCTAssertEqual(FNV1a64.hash("example.com"), 0x5768_4663_4E27_14C6)
    XCTAssertEqual(FNV1a64.hash("bbc.co.uk"), 0x3756_0E87_B6FC_872C)
    XCTAssertEqual(FNV1a64.hash(""), 0xCBF2_9CE4_8422_2325)
    XCTAssertEqual(FNV1a64.hash("Example.COM"), FNV1a64.hash("example.com"))
  }

  func testDomainHashSetLookup() throws {
    // The script's layout: sorted little-endian UInt64s.
    var values = ["example.com", "bbc.co.uk", "spam.example"].map(FNV1a64.hash).sorted()
    let data = Data(bytes: &values, count: values.count * 8)
    let set = try DomainHashSet(data: data)
    XCTAssertEqual(set.count, 3)
    XCTAssertTrue(set.contains("example.com"))
    XCTAssertTrue(set.contains("BBC.co.uk"))
    XCTAssertTrue(set.contains("spam.example"))
    XCTAssertFalse(set.contains("example.org"))
    XCTAssertFalse(set.contains(""))
    XCTAssertFalse(try DomainHashSet(data: Data()).contains("example.com"))
    XCTAssertThrowsError(try DomainHashSet(data: Data(count: 12)))
  }

  func testDomainHashSetReadsLittleEndianBytes() throws {
    // 0x576846634e2714c6, written byte by byte as the script writes it.
    let data = Data([0xC6, 0x14, 0x27, 0x4E, 0x63, 0x46, 0x68, 0x57])
    XCTAssertTrue(try DomainHashSet(data: data).contains("example.com"))
  }

  // MARK: Public Suffix List

  func testRegistrableDomains() {
    let suffixes = SourceQualityFixture.suffixes
    XCTAssertEqual(suffixes.registrableDomain(of: "www.example.com"), "example.com")
    XCTAssertEqual(suffixes.registrableDomain(of: "a.b.example.co.uk"), "example.co.uk")
    XCTAssertEqual(suffixes.registrableDomain(of: "foo.github.io"), "foo.github.io")
    XCTAssertNil(suffixes.registrableDomain(of: "github.io"))
    XCTAssertNil(suffixes.registrableDomain(of: "localhost"))
    XCTAssertNil(suffixes.registrableDomain(of: "192.168.1.1"))
    XCTAssertEqual(suffixes.registrableDomain(of: "www.city.kawasaki.jp"), "city.kawasaki.jp")
  }

  func testRegistrableDomainEdgeCases() {
    let suffixes = SourceQualityFixture.suffixes
    XCTAssertEqual(suffixes.registrableDomain(of: "WWW.Example.COM"), "example.com")
    XCTAssertEqual(suffixes.registrableDomain(of: "www.example.com."), "example.com")
    XCTAssertNil(suffixes.registrableDomain(of: "foo.kawasaki.jp"), "a wildcard suffix is public")
    XCTAssertEqual(suffixes.registrableDomain(of: "a.foo.kawasaki.jp"), "a.foo.kawasaki.jp")
    XCTAssertEqual(suffixes.registrableDomain(of: "city.kawasaki.jp"), "city.kawasaki.jp")
    XCTAssertNil(suffixes.registrableDomain(of: "co.uk"))
    XCTAssertNil(suffixes.registrableDomain(of: "::1"))
    XCTAssertNil(suffixes.registrableDomain(of: "[2001:db8::1]"))
    XCTAssertNil(suffixes.registrableDomain(of: ""))
    XCTAssertNil(suffixes.registrableDomain(of: "a..example.com"))
    // An unlisted top-level domain uses the default rule "*".
    XCTAssertEqual(suffixes.registrableDomain(of: "www.example.zz"), "example.zz")
    // IDN hosts compare in their punycode form, whichever form the rule or host is in.
    XCTAssertEqual(suffixes.registrableDomain(of: "www.例子.公司.cn"), "xn--fsqu00a.xn--55qx5d.cn")
    XCTAssertEqual(suffixes.registrableDomain(of: "www.xn--fsqu00a.xn--55qx5d.cn"), "xn--fsqu00a.xn--55qx5d.cn")
    XCTAssertNil(suffixes.registrableDomain(of: "xn--55qx5d.cn"))
  }

  func testBundledDataLoads() throws {
    let bundle = try XCTUnwrap(SearchDataBundle.bundled)
    XCTAssertGreaterThan(bundle.unsafe.count, 0)
    XCTAssertGreaterThan(bundle.spam.count, 0)
    XCTAssertFalse(bundle.reliability.isEmpty)
    XCTAssertFalse(bundle.authoritySuffixes.isEmpty)
    XCTAssertTrue(bundle.unreadable.contains("pinterest.com"))
    XCTAssertEqual(bundle.publicSuffixes.registrableDomain(of: "www.example.com"), "example.com")
    XCTAssertEqual(bundle.publicSuffixes.registrableDomain(of: "news.bbc.co.uk"), "bbc.co.uk")

    let folder = try XCTUnwrap(Bundle.main.url(forResource: "SearchData", withExtension: nil))
    let files = try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.fileSizeKey])
    let total = try files.reduce(0) { $0 + (try $1.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) }
    XCTAssertLessThanOrEqual(total, 3_145_728)
    let manifest = try JSONSerialization.jsonObject(with: Data(contentsOf: folder.appending(path: "manifest.json")))
    let sources = try XCTUnwrap((manifest as? [String: Any])?["sources"] as? [[String: Any]])
    XCTAssertTrue(sources.allSatisfy { ($0["licence"] as? String)?.isEmpty == false })
  }

  func testBundleLoadRejectsMalformedHashFile() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: "SearchData-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    for name in ["public_suffix_list.dat", "reliability.tsv", "authority.txt", "unreadable.txt", "enigma-blocked.txt"] {
      try Data("com\n".utf8).write(to: folder.appending(path: name))
    }
    try Data(count: 8).write(to: folder.appending(path: "spam.bin"))
    try Data(count: 9).write(to: folder.appending(path: "unsafe.bin"))
    XCTAssertThrowsError(try SearchDataBundle.load(from: folder))
    try Data(count: 16).write(to: folder.appending(path: "unsafe.bin"))
    XCTAssertEqual(try SearchDataBundle.load(from: folder).unsafe.count, 2)
  }

  func testBundleLoadParsesTextFiles() throws {
    let folder = FileManager.default.temporaryDirectory.appending(path: "SearchData-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let files = [
      "public_suffix_list.dat": "com\nexample\n",
      "reliability.tsv": "reliable.example\tgr\nodd.example\tzz\n\nbad.example\tb\n",
      "authority.txt": "# comment\n.gov\n\nDeveloper.Apple.com\n!Academia.edu\n",
      "unreadable.txt": "# comment\npinterest.com\n",
      "enigma-blocked.txt": "# header only\n",
      "overrides.tsv": "# comment\nWikipedia.org\tneutral\nmsn.com\tallow\nodd.example\tboost\nbad line\n",
    ]
    for (name, text) in files { try Data(text.utf8).write(to: folder.appending(path: name)) }
    try Data().write(to: folder.appending(path: "unsafe.bin"))
    try Data().write(to: folder.appending(path: "spam.bin"))
    let bundle = try SearchDataBundle.load(from: folder)
    XCTAssertEqual(bundle.reliability, ["reliable.example": .generallyReliable, "bad.example": .blacklisted])
    XCTAssertEqual(bundle.authoritySuffixes, [".gov"])
    XCTAssertEqual(bundle.authorityDomains, ["developer.apple.com"])
    XCTAssertEqual(bundle.authorityExclusions, ["academia.edu"])
    XCTAssertEqual(bundle.unreadable, ["pinterest.com"])
    XCTAssertEqual(bundle.enigmaBlocked, [])
    XCTAssertEqual(bundle.overrides, ["wikipedia.org": .neutral, "msn.com": .allow])
  }

  // MARK: SourceQuality

  func testBlocksSubdomainsOfListedDomain() {
    let quality = SourceQualityFixture.quality()
    XCTAssertTrue(quality.isBlocked(url("https://a.b.spam.example/x")))
    XCTAssertTrue(quality.isBlocked(url("https://spam.example/")))
    XCTAssertTrue(quality.isBlocked(url("https://www.malware.example/download")))
    XCTAssertTrue(quality.isBlocked(url("https://news.curated-bad.example/")))
    XCTAssertFalse(quality.isBlocked(url("https://notspam.example/")))
    XCTAssertFalse(quality.isBlocked(url("https://example.com/")))
  }

  func testBlockStopsAtTheRegistrableDomain() {
    // A listed public suffix doesn't block every site under it.
    let data = SourceQualityFixture.bundle(unsafe: ["github.io", "co.uk"])
    let quality = SourceQuality(data: data, userBlocked: [])
    XCTAssertFalse(quality.isBlocked(url("https://someone.github.io/")))
    XCTAssertFalse(quality.isBlocked(url("https://www.bbc.co.uk/")))
    XCTAssertTrue(quality.isBlocked(url("https://github.io/")))
  }

  func testUserBlockWins() {
    let quality = SourceQualityFixture.quality(userBlocked: ["reliable.example", "Example.ORG"])
    XCTAssertTrue(quality.isBlocked(url("https://www.reliable.example/story")))
    XCTAssertTrue(quality.isBlocked(url("https://docs.example.org/")))
    XCTAssertFalse(SourceQualityFixture.quality().isBlocked(url("https://www.reliable.example/story")))
  }

  func testDeprecatedAndBlacklistedSourcesAreBlocked() {
    let quality = SourceQualityFixture.quality()
    XCTAssertTrue(quality.isBlocked(url("https://fabricator.example/a")))
    XCTAssertTrue(quality.isBlocked(url("https://www.spamfarm.example/a")))
    XCTAssertFalse(quality.isBlocked(url("https://tabloid.example/a")))
    XCTAssertFalse(quality.isBlocked(url("https://mixed.example/a")))
  }

  func testURLsWithoutAHostAreBlocked() {
    XCTAssertTrue(SourceQualityFixture.quality().isBlocked(url("file:///etc/hosts")))
  }

  func testUnreadable() {
    let quality = SourceQualityFixture.quality()
    XCTAssertTrue(quality.isUnreadable(url("https://www.pinterest.com/pin/1")))
    XCTAssertTrue(quality.isUnreadable(url("https://m.youtube.com/watch?v=1")))
    XCTAssertFalse(quality.isUnreadable(url("https://example.com/")))
  }

  func testRegistrableDomainOfURL() {
    let quality = SourceQualityFixture.quality()
    XCTAssertEqual(quality.registrableDomain(of: url("https://news.bbc.co.uk/x")), "bbc.co.uk")
    XCTAssertNil(quality.registrableDomain(of: url("https://127.0.0.1/")))
  }

  func testTrustFactors() {
    let quality = SourceQualityFixture.quality()
    XCTAssertEqual(quality.trustFactor(for: url("https://www.gov.uk/x")), 1.3, accuracy: 1e-9)
    XCTAssertEqual(quality.trustFactor(for: url("https://developer.apple.com/documentation")), 1.3, accuracy: 1e-9)
    XCTAssertEqual(quality.trustFactor(for: url("https://www.cdc.gov/flu")), 1.3, accuracy: 1e-9)
    XCTAssertEqual(quality.trustFactor(for: url("https://www.nhs.uk/conditions")), 1.3, accuracy: 1e-9)
    XCTAssertEqual(quality.trustFactor(for: url("https://reliable.example/a")), 1.15, accuracy: 1e-9)
    XCTAssertEqual(quality.trustFactor(for: url("https://mixed.example/a")), 1.0, accuracy: 1e-9)
    XCTAssertEqual(quality.trustFactor(for: url("https://www.pinterest.com/pin/1")), 0.5, accuracy: 1e-9)
    XCTAssertEqual(quality.trustFactor(for: url("https://example.com")), 1.0, accuracy: 1e-9)
    // ".gov" is a suffix rule, not a substring.
    XCTAssertEqual(quality.trustFactor(for: url("https://notagov.com/")), 1.0, accuracy: 1e-9)
    XCTAssertEqual(quality.trustFactor(for: url("https://apple.com/")), 1.0, accuracy: 1e-9)
  }

  func testAuthorityDomainThatIsAPublicSuffix() {
    // nhs.uk is itself on the Public Suffix List, so www.nhs.uk is its own registrable domain.
    let quality = SourceQualityFixture.quality()
    XCTAssertNil(SourceQualityFixture.suffixes.registrableDomain(of: "nhs.uk"))
    XCTAssertEqual(quality.trustFactor(for: url("https://www.nhs.uk/conditions/flu/")), 1.3, accuracy: 1e-9)
    XCTAssertEqual(quality.trustFactor(for: url("https://notnhs.uk/")), 1.0, accuracy: 1e-9)
  }

  // MARK: Overrides (decisions D55, D56)

  private func overridden(_ overrides: [String: SourceOverride], unsafe: [String] = ["malware.example"],
                          userBlocked: Set<String> = []) -> SourceQuality {
    let data = SourceQualityFixture.bundle(
      unsafe: unsafe, spam: ["msn.com", "spam.example"],
      reliability: ["wikipedia.org": .generallyUnreliable, "stackoverflow.com": .generallyUnreliable,
                    "healthline.com": .blacklisted, "fabricator.example": .deprecated],
      enigmaBlocked: ["curated-bad.example"], overrides: overrides)
    return SourceQuality(data: data, userBlocked: userBlocked)
  }

  func testNeutralOverrideIgnoresPerennialStatus() {
    let plain = overridden([:])
    XCTAssertEqual(plain.trustFactor(for: url("https://en.wikipedia.org/wiki/Swift")), 0.5, accuracy: 1e-9)
    let quality = overridden(["wikipedia.org": .neutral, "stackoverflow.com": .neutral])
    XCTAssertEqual(quality.trustFactor(for: url("https://en.wikipedia.org/wiki/Swift")), 1.0, accuracy: 1e-9)
    XCTAssertEqual(quality.trustFactor(for: url("https://stackoverflow.com/questions/1")), 1.0, accuracy: 1e-9)
    XCTAssertEqual(quality.reliability(of: url("https://en.wikipedia.org/wiki/Swift")), nil)
    // A neutral entry doesn't lift a block.
    XCTAssertTrue(overridden(["fabricator.example": .neutral]).isBlocked(url("https://fabricator.example/")))
  }

  func testAllowOverrideLiftsSpamAndPerennialBlocks() {
    let plain = overridden([:])
    XCTAssertTrue(plain.isBlocked(url("https://www.msn.com/en-us/news/x")))
    XCTAssertTrue(plain.isBlocked(url("https://www.healthline.com/health/flu")))
    let quality = overridden(["msn.com": .allow, "healthline.com": .allow])
    XCTAssertFalse(quality.isBlocked(url("https://www.msn.com/en-us/news/x")))
    XCTAssertFalse(quality.isBlocked(url("https://www.healthline.com/health/flu")))
    XCTAssertTrue(quality.isBlocked(url("https://spam.example/")), "only the listed domain is lifted")
  }

  func testOverrideNeverLiftsSecurityBlock() {
    // An override domain that is also in the unsafe set stays blocked, and so does a listed subdomain.
    let quality = overridden(["msn.com": .allow, "healthline.com": .allow],
                             unsafe: ["healthline.com", "zone.msn.com"])
    XCTAssertTrue(quality.isBlocked(url("https://www.healthline.com/health/flu")))
    XCTAssertTrue(quality.isBlocked(url("https://zone.msn.com/game")))
    XCTAssertFalse(quality.isBlocked(url("https://www.msn.com/en-us/news/x")))
  }

  func testOverrideNeverLiftsUserOrCuratedBlock() {
    let quality = overridden(["msn.com": .allow, "curated-bad.example": .allow], userBlocked: ["msn.com"])
    XCTAssertTrue(quality.isBlocked(url("https://www.msn.com/")))
    XCTAssertTrue(quality.isBlocked(url("https://curated-bad.example/")))
  }

  func testBundledOverrides() throws {
    let bundle = try XCTUnwrap(SearchDataBundle.bundled)
    for domain in ["wikipedia.org", "stackoverflow.com", "stackexchange.com", "superuser.com", "serverfault.com",
                   "askubuntu.com", "investopedia.com"] {
      XCTAssertEqual(bundle.overrides[domain], .neutral, domain)
    }
    XCTAssertEqual(bundle.overrides["msn.com"], .allow)
    XCTAssertEqual(bundle.overrides["healthline.com"], .allow)
    let quality = SourceQuality(data: bundle, userBlocked: [])
    XCTAssertFalse(quality.isBlocked(url("https://www.msn.com/en-us/news")))
    XCTAssertFalse(quality.isBlocked(url("https://www.healthline.com/health")))
    XCTAssertEqual(quality.trustFactor(for: url("https://en.wikipedia.org/wiki/Swift")), 1.0, accuracy: 1e-9)
    XCTAssertEqual(quality.trustFactor(for: url("https://stackoverflow.com/questions/1")), 1.0, accuracy: 1e-9)
    XCTAssertEqual(quality.trustFactor(for: url("https://www.investopedia.com/terms/x")), 1.0, accuracy: 1e-9)
  }

  func testAuthorityExclusionBeatsSuffix() {
    let data = SourceQualityFixture.bundle(authorityExclusions: ["academia.edu"])
    let quality = SourceQuality(data: data, userBlocked: [])
    XCTAssertEqual(quality.trustFactor(for: url("https://www.academia.edu/123/paper")), 1.0, accuracy: 1e-9)
    XCTAssertEqual(quality.trustFactor(for: url("https://www.mit.edu/")), 1.3, accuracy: 1e-9)
  }

  func testBundledRoundOneOverrides() throws {
    // Decision D57: crowdfunding and petition sites are readable; preprints and AWS docs aren't
    // penalised; academia.edu isn't an authority; real misinformation stays blocked.
    let quality = SourceQuality(data: try XCTUnwrap(SearchDataBundle.bundled), userBlocked: [])
    for link in ["https://www.kickstarter.com/projects/x", "https://www.gofundme.com/f/x",
                 "https://www.indiegogo.com/projects/x", "https://www.change.org/p/x", "https://www.lulu.com/shop/x"] {
      XCTAssertFalse(quality.isBlocked(url(link)), link)
    }
    XCTAssertTrue(quality.isBlocked(url("https://www.naturalnews.com/2020-01-01-x.html")))
    // D59: allowing msn.com never unblocks its malware-listed hosts.
    for host in ["zone.msn.com", "0.r.msn.com", "ac2.msn.com", "anrfrm.msn.com", "unicast.msn.com"] {
      XCTAssertTrue(quality.isBlocked(url("https://\(host)/x")), host)
    }
    let neutral = quality.trustFactor(for: url("https://unknown-blog.example/post"))
    XCTAssertEqual(neutral, 1.0, accuracy: 1e-9)
    XCTAssertGreaterThanOrEqual(quality.trustFactor(for: url("https://arxiv.org/abs/2101.00001")), neutral)
    XCTAssertGreaterThanOrEqual(quality.trustFactor(for: url("https://docs.aws.amazon.com/s3/")), neutral)
    XCTAssertGreaterThanOrEqual(quality.trustFactor(for: url("https://www.biorxiv.org/content/x")), neutral)
    XCTAssertGreaterThanOrEqual(quality.trustFactor(for: url("https://www.medrxiv.org/content/x")), neutral)
    XCTAssertNotEqual(quality.trustFactor(for: url("https://www.academia.edu/123/paper")), 1.3, accuracy: 1e-9)
  }

  func testTrustFactorsMultiply() {
    let quality = SourceQualityFixture.quality()
    XCTAssertEqual(quality.trustFactor(for: url("https://tabloid.example/a")), 0.25, accuracy: 1e-9)
    let data = SourceQualityFixture.bundle(reliability: ["cdc.gov": .generallyReliable])
    XCTAssertEqual(SourceQuality(data: data, userBlocked: []).trustFactor(for: url("https://www.cdc.gov/")),
                   1.3 * 1.15, accuracy: 1e-9)
  }
}
