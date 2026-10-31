import XCTest
@testable import Enigma

/// Answers from a table; names it doesn't list resolve to `fallback`, or fail when that's nil.
struct FakeHostResolver: HostResolver {
  var table: [String: [String]] = [:]
  var fallback: [String]? = ["93.184.216.34"]

  func addresses(for host: String) async throws -> [String] {
    if let answer = table[host.lowercased()] { return answer }
    guard let fallback else { throw URLError(.cannotFindHost) }
    return fallback
  }
}

/// A lookup that never answers until its task is cancelled.
final class HangingHostResolver: HostResolver, @unchecked Sendable {
  private let lock = NSLock()
  private var calls = 0
  var callCount: Int { lock.withLock { calls } }

  func addresses(for host: String) async throws -> [String] {
    lock.withLock { calls += 1 }
    try await Task.sleep(for: .seconds(3_600))
    return ["93.184.216.34"]
  }
}

final class PageReaderTests: XCTestCase {
  // MARK: The local-network guard (Task 4.1)

  func testRefusedHostNames() async {
    let names = ["localhost", "printer", "nas.local", "router.lan", "x.internal", "box.home.arpa",
                 "NAS.Local.", "LOCALHOST", "app.localhost", "pi.localdomain", "files.corp", "tor.onion", ""]
    for name in names {
      XCTAssertFalse(NetworkGuard.isAllowedName(name), name)
    }
    for name in ["example.com", "news.example.co.uk", "localhost.example.com", "internal.example.org"] {
      XCTAssertTrue(NetworkGuard.isAllowedName(name), name)
    }
    // Refused by name even when the name would resolve to a public address.
    let networkGuard = NetworkGuard(resolver: FakeHostResolver())
    for name in ["localhost", "printer", "nas.local", "router.lan", "x.internal", "box.home.arpa"] {
      let allowed = await networkGuard.allows(URL(string: "https://\(name)/page")!)
      XCTAssertFalse(allowed, name)
    }
  }

  func testRefusedAddresses() async {
    let refused = ["10.0.0.1", "172.16.5.4", "192.168.1.1", "127.0.0.1", "169.254.1.1", "100.64.0.1", "224.0.0.1",
                   "0.0.0.0", "::1", "fe80::1", "fc00::1", "ff02::1", "::", "::ffff:192.168.0.1",
                   // Range edges and embedded IPv4 forms (D64).
                   "10.255.255.255", "172.31.255.255", "100.127.255.255", "127.255.255.254", "255.255.255.255",
                   "239.255.255.250", "240.0.0.1", "0.1.2.3", "febf::1", "fdff:ffff::1", "fec0::1", "FE80::1",
                   "::ffff:7f00:1", "::ffff:10.1.2.3", "::127.0.0.1", "64:ff9b::192.168.0.1", "64:ff9b::a00:1",
                   "not-an-address", "", "1.2.3", "93.184.216.34.5"]
    for address in refused {
      XCTAssertFalse(NetworkGuard.isPublicAddress(address), address)
    }
    // Literal addresses in URLs never reach the resolver.
    let networkGuard = NetworkGuard(resolver: FakeHostResolver(fallback: ["93.184.216.34"]))
    for url in ["http://10.0.0.1/", "https://192.168.1.1:8443/admin", "http://[::1]/", "http://[fe80::1]:8080/",
                "http://127.0.0.1/", "http://[::ffff:192.168.0.1]/"] {
      let allowed = await networkGuard.allows(URL(string: url)!)
      XCTAssertFalse(allowed, url)
    }
  }

  func testPublicAddressesAllowed() async {
    let allowed = ["93.184.216.34", "2606:2800:220:1::1", "8.8.8.8", "1.1.1.1", "100.63.255.255", "100.128.0.1",
                   "172.15.255.255", "172.32.0.1", "192.167.255.255", "192.169.0.1", "223.255.255.255",
                   "169.253.255.255", "11.0.0.1", "::ffff:93.184.216.34", "64:ff9b::93.184.216.34", "2001:4860:4860::8888"]
    for address in allowed {
      XCTAssertTrue(NetworkGuard.isPublicAddress(address), address)
    }
    // A resolver that always fails proves literals aren't looked up.
    let networkGuard = NetworkGuard(resolver: FakeHostResolver(fallback: nil))
    for url in ["https://93.184.216.34/", "https://[2606:2800:220:1::1]/page"] {
      let isAllowed = await networkGuard.allows(URL(string: url)!)
      XCTAssertTrue(isAllowed, url)
    }
  }

  func testHostResolvingToPrivateAddressIsRefused() async {
    let networkGuard = NetworkGuard(resolver: FakeHostResolver(table: [
      "evil.example": ["192.168.0.10"],
      "rebind.example.com": ["127.0.0.1"],
      "mixed.example.com": ["93.184.216.34", "10.0.0.7"],
      "v6.example.com": ["2606:2800:220:1::1", "fd12::1"],
      "good.example.com": ["93.184.216.34", "2606:2800:220:1::1"],
    ]))
    for host in ["evil.example", "rebind.example.com", "mixed.example.com", "v6.example.com", "EVIL.EXAMPLE"] {
      let allowed = await networkGuard.allows(URL(string: "https://\(host)/")!)
      XCTAssertFalse(allowed, host)
    }
    let allowed = await networkGuard.allows(URL(string: "https://good.example.com/a")!)
    XCTAssertTrue(allowed)
  }

  func testUnresolvableHostIsRefused() async {
    let failing = NetworkGuard(resolver: FakeHostResolver(fallback: nil))
    let failingAllowed = await failing.allows(URL(string: "https://example.com/")!)
    XCTAssertFalse(failingAllowed)
    let empty = NetworkGuard(resolver: FakeHostResolver(fallback: []))
    let emptyAllowed = await empty.allows(URL(string: "https://example.com/")!)
    XCTAssertFalse(emptyAllowed)
    let noHost = await NetworkGuard(resolver: FakeHostResolver()).allows(URL(string: "file:///etc/hosts")!)
    XCTAssertFalse(noHost)
  }

  func testSystemResolverReturnsNumericAddresses() async throws {
    // getaddrinfo answers numeric hosts itself, with no DNS traffic.
    let addresses = try await SystemHostResolver().addresses(for: "127.0.0.1")
    XCTAssertEqual(addresses, ["127.0.0.1"])
    let v6 = try await SystemHostResolver().addresses(for: "::1")
    XCTAssertEqual(v6, ["::1"])
  }

  func testSystemResolverReturnsOnCancellation() async {
    // A lookup that never answers (a stalled DNS server) must not hold up Stop.
    let gate = DispatchSemaphore(value: 0)
    // A watchdog, so a resolver that ignores cancellation fails this test instead of hanging it.
    DispatchQueue.global().asyncAfter(deadline: .now() + 3) { gate.signal() }
    let resolver = SystemHostResolver(lookUp: { _ in
      gate.wait()
      return ["93.184.216.34"]
    })
    let task = Task { try await resolver.addresses(for: "slow.example.com") }
    try? await Task.sleep(for: .milliseconds(50))
    let started = ContinuousClock.now
    task.cancel()
    let result = await task.result
    XCTAssertLessThan(ContinuousClock.now - started, .seconds(1))
    XCTAssertThrowsError(try result.get()) { XCTAssertTrue($0 is CancellationError, "\($0)") }
  }

  func testGuardHasThreeAnswers() async {
    let networkGuard = NetworkGuard(resolver: FakeHostResolver(table: ["lan.example.com": ["10.0.0.2"],
                                                                      "empty.example.com": []]))
    let allowed = await networkGuard.check(URL(string: "https://example.com/")!)
    XCTAssertEqual(allowed, .allowed)
    for link in ["https://lan.example.com/", "https://printer/", "http://127.0.0.1/"] {
      let refused = await networkGuard.check(URL(string: link)!)
      XCTAssertEqual(refused, .refused, link)
    }
    let empty = await networkGuard.check(URL(string: "https://empty.example.com/")!)
    XCTAssertEqual(empty, .unresolved)
    let failing = await NetworkGuard(resolver: FakeHostResolver(fallback: nil)).check(URL(string: "https://example.com/")!)
    XCTAssertEqual(failing, .unresolved)
  }

  func testLookupErrorFailsRatherThanRefuses() async {
    let client = FakeSearchHTTPClient()
    client.fallback = htmlReply()
    let outcome = await reader(client, resolver: FakeHostResolver(fallback: nil)).fetch(URL(string: "https://example.com/")!)
    XCTAssertEqual(outcome, .failed, "an unresolved name keeps its snippet")
    XCTAssertTrue(client.requests.isEmpty)
  }

  func testCancelledLookupFails() async {
    let client = FakeSearchHTTPClient()
    client.fallback = htmlReply()
    let resolver = HangingHostResolver()
    let pageReader = PageReader(client: client, networkGuard: NetworkGuard(resolver: resolver), isBlocked: { _ in false })
    let task = Task { await pageReader.fetch(URL(string: "http://example.com/")!) }
    for _ in 0..<5_000 where resolver.callCount == 0 { try? await Task.sleep(for: .milliseconds(1)) }
    task.cancel()
    let outcome = await task.value
    XCTAssertEqual(outcome, .failed)
    XCTAssertEqual(resolver.callCount, 1, "a cancelled https attempt doesn't go on to http")
    XCTAssertTrue(client.requests.isEmpty)
  }

  func testResponseFromNonPublicAddressIsRefused() async {
    for address in ["10.0.0.5", "127.0.0.1", "::1", "fe80::1%en0", "::ffff:192.168.1.1"] {
      let client = FakeSearchHTTPClient()
      client.stub(URL(string: "https://example.com/")!,
                  .response(status: 200, headers: ["Content-Type": "text/html"], body: html, remoteAddress: address))
      let outcome = await reader(client).fetch(URL(string: "https://example.com/")!)
      XCTAssertEqual(outcome, .refused, address)
    }
    // A redirect served from a private address isn't followed.
    let redirecting = FakeSearchHTTPClient()
    redirecting.stub(URL(string: "https://example.com/a")!,
                     .response(status: 302, headers: ["Location": "https://example.com/b"], body: Data(), remoteAddress: "192.168.0.1"))
    redirecting.fallback = htmlReply()
    let redirected = await reader(redirecting).fetch(URL(string: "https://example.com/a")!)
    XCTAssertEqual(redirected, .refused)
    XCTAssertEqual(redirecting.requests.count, 1)
    // Public or unknown (a proxy) is read.
    for address in ["93.184.216.34", "2606:2800:220:1::1", nil] as [String?] {
      let client = FakeSearchHTTPClient()
      client.stub(URL(string: "https://example.com/")!,
                  .response(status: 200, headers: ["Content-Type": "text/html"], body: html, remoteAddress: address))
      let outcome = await reader(client).fetch(URL(string: "https://example.com/")!)
      guard case .page = outcome else { XCTFail("\(String(describing: address)): \(outcome)"); continue }
    }
  }

  func testClientReportsRemoteAddress() async throws {
    let reply = Data("HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 2\r\nConnection: close\r\n\r\nok".utf8)
    let listener = try LoopbackListener(reply: reply)
    try await listener.start()
    defer { listener.stop() }
    let client = URLSessionSearchHTTPClient()
    let response = try await client.send(URLRequest(url: URL(string: listener.origin + "/page")!), maximumBytes: 1_000)
    XCTAssertEqual(response.body, Data("ok".utf8))
    XCTAssertEqual(response.remoteAddress, "127.0.0.1")
    XCTAssertFalse(NetworkGuard.isPublicAddress(response.remoteAddress ?? ""))
  }

  func testDeclaredUTF8KeepsTextAroundOneBadByte() {
    let body = Data("café ".utf8) + Data([0xFF]) + Data(" 東京".utf8)
    for contentType in ["text/html; charset=utf-8", "text/html"] {
      let text = PageReader.decode(body, contentType: contentType)
      XCTAssertEqual(text, "café \u{FFFD} 東京", contentType)
    }
    let meta = Data("<meta charset=\"utf-8\">café ".utf8) + Data([0xC3]) + Data(" 東京 and more".utf8)
    XCTAssertEqual(PageReader.decode(meta, contentType: nil)?.contains("café"), true)
    XCTAssertEqual(PageReader.decode(meta, contentType: nil)?.contains("東京"), true)
    // Mostly invalid: a Latin-1 page labelled UTF-8 falls back to Windows-1252.
    let latin1 = Data([0x63, 0x61, 0x66, 0xE9, 0x20, 0x63, 0x72, 0xE8, 0x6D, 0x65]) // "café crème"
    XCTAssertEqual(PageReader.decode(latin1, contentType: "text/html; charset=utf-8"), "café crème")
  }

  // MARK: Downloading pages (Task 4.2)

  private let html = Data("<!doctype html><html><head><title>T</title></head><body><p>Hello</p></body></html>".utf8)

  private func reader(_ client: FakeSearchHTTPClient, resolver: FakeHostResolver = FakeHostResolver(),
                      blocked: Set<String> = []) -> PageReader {
    PageReader(client: client, networkGuard: NetworkGuard(resolver: resolver),
               isBlocked: { url in blocked.contains(url.host(percentEncoded: false) ?? "") },
               acceptLanguage: "en-GB,en;q=0.9")
  }

  private func htmlReply(_ body: Data? = nil) -> FakeSearchHTTPClient.Reply {
    .response(status: 200, headers: ["Content-Type": "text/html; charset=utf-8"], body: body ?? html)
  }

  private func redirect(_ status: Int = 302, to location: String) -> FakeSearchHTTPClient.Reply {
    .response(status: status, headers: ["Location": location], body: Data())
  }

  func testHttpLinksTryHttpsFirst() async {
    let client = FakeSearchHTTPClient()
    client.stub(URL(string: "https://example.com/a?b=1")!, htmlReply())
    let outcome = await reader(client).fetch(URL(string: "http://example.com/a?b=1")!)
    guard case .page(let page) = outcome else { return XCTFail("\(outcome)") }
    XCTAssertEqual(page.requestedURL, URL(string: "http://example.com/a?b=1"))
    XCTAssertEqual(page.finalURL, URL(string: "https://example.com/a?b=1"))
    XCTAssertEqual(client.requests.map(\.url), [URL(string: "https://example.com/a?b=1")])

    // App Transport Security blocks plain http, so a failed https attempt isn't retried over http (D71).
    let fallback = FakeSearchHTTPClient()
    fallback.stub(URL(string: "https://example.com/a")!, .failure(.secureConnectionFailed))
    fallback.stub(URL(string: "http://example.com/a")!, htmlReply())
    let second = await reader(fallback).fetch(URL(string: "http://example.com:80/a")!)
    XCTAssertEqual(second, .failed)
    XCTAssertEqual(fallback.requests.map(\.url), [URL(string: "https://example.com/a")])

    // An https link never falls back to http.
    let secure = FakeSearchHTTPClient()
    secure.stub(URL(string: "http://example.com/a")!, htmlReply())
    let third = await reader(secure).fetch(URL(string: "https://example.com/a")!)
    XCTAssertEqual(third, .failed)
    XCTAssertEqual(secure.requests.map(\.url), [URL(string: "https://example.com/a")])
  }

  func testRedirectToHttpFails() async {
    let client = FakeSearchHTTPClient()
    client.stub(URL(string: "https://example.com/a")!, redirect(301, to: "http://example.com/b"))
    client.fallback = htmlReply()
    let outcome = await reader(client).fetch(URL(string: "https://example.com/a")!)
    XCTAssertEqual(outcome, .failed, "the page only moved, so its snippet stays usable")
    XCTAssertEqual(client.requests.count, 1)
  }

  func testRefusedHttpLinkIsNotRetried() async {
    let client = FakeSearchHTTPClient()
    client.fallback = htmlReply()
    let resolver = FakeHostResolver(table: ["nas.example.com": ["192.168.1.20"]])
    let outcome = await reader(client, resolver: resolver).fetch(URL(string: "http://nas.example.com/")!)
    XCTAssertEqual(outcome, .refused)
    XCTAssertTrue(client.requests.isEmpty)
  }

  func testRedirectToPrivateAddressDropsPage() async {
    for location in ["https://intranet.example.com/x", "http://127.0.0.1/admin", "http://[::1]:8080/",
                     "http://192.168.0.1/", "https://router.lan/"] {
      let client = FakeSearchHTTPClient()
      client.stub(URL(string: "https://example.com/a")!, redirect(to: location))
      client.fallback = htmlReply()
      let resolver = FakeHostResolver(table: ["intranet.example.com": ["10.0.0.5"]])
      let outcome = await reader(client, resolver: resolver).fetch(URL(string: "https://example.com/a")!)
      XCTAssertEqual(outcome, .refused, location)
      XCTAssertEqual(client.requests.count, 1, location)
    }
  }

  func testRedirectToBlockedSiteDropsPage() async {
    let client = FakeSearchHTTPClient()
    client.stub(URL(string: "https://example.com/a")!, redirect(301, to: "https://spam.example.net/landing"))
    client.fallback = htmlReply()
    let outcome = await reader(client, blocked: ["spam.example.net"]).fetch(URL(string: "https://example.com/a")!)
    XCTAssertEqual(outcome, .refused)
    XCTAssertEqual(client.requests.count, 1)

    // The first hop is checked too.
    let direct = FakeSearchHTTPClient()
    direct.fallback = htmlReply()
    let first = await reader(direct, blocked: ["spam.example.net"]).fetch(URL(string: "https://spam.example.net/")!)
    XCTAssertEqual(first, .refused)
    XCTAssertTrue(direct.requests.isEmpty)
  }

  func testRedirectsFollowRelativeLocations() async {
    let client = FakeSearchHTTPClient()
    client.stub(URL(string: "https://example.com/a/b")!, redirect(307, to: "../c?d=1"))
    client.stub(URL(string: "https://example.com/c?d=1")!, redirect(308, to: "/final"))
    client.stub(URL(string: "https://example.com/final")!, htmlReply())
    let outcome = await reader(client).fetch(URL(string: "https://example.com/a/b")!)
    guard case .page(let page) = outcome else { return XCTFail("\(outcome)") }
    XCTAssertEqual(page.finalURL, URL(string: "https://example.com/final"))
    XCTAssertEqual(client.requests.count, 3)
  }

  func testRedirectToOtherSchemeIsRefused() async {
    for location in ["file:///etc/passwd", "ftp://example.com/a", "javascript:alert(1)", "data:text/html,hi"] {
      let client = FakeSearchHTTPClient()
      client.stub(URL(string: "https://example.com/a")!, redirect(to: location))
      let outcome = await reader(client).fetch(URL(string: "https://example.com/a")!)
      XCTAssertEqual(outcome, .refused, location)
      XCTAssertEqual(client.requests.count, 1, location)
    }
    let noLocation = FakeSearchHTTPClient()
    noLocation.stub(URL(string: "https://example.com/a")!, .response(status: 302, body: Data()))
    let outcome = await reader(noLocation).fetch(URL(string: "https://example.com/a")!)
    XCTAssertEqual(outcome, .failed)
  }

  func testSixthRedirectDropsPage() async {
    func chain(redirects: Int) -> FakeSearchHTTPClient {
      let client = FakeSearchHTTPClient()
      for hop in 0..<redirects {
        client.stub(URL(string: "https://example.com/\(hop)")!, redirect(to: "https://example.com/\(hop + 1)"))
      }
      client.stub(URL(string: "https://example.com/\(redirects)")!, htmlReply())
      return client
    }
    let five = chain(redirects: 5)
    let fiveOutcome = await reader(five).fetch(URL(string: "https://example.com/0")!)
    guard case .page(let page) = fiveOutcome else { return XCTFail("\(fiveOutcome)") }
    XCTAssertEqual(page.finalURL, URL(string: "https://example.com/5"))
    XCTAssertEqual(five.requests.count, 6)

    let six = chain(redirects: 6)
    let sixOutcome = await reader(six).fetch(URL(string: "https://example.com/0")!)
    XCTAssertEqual(sixOutcome, .failed)
    XCTAssertEqual(six.requests.count, 6, "the sixth redirect's target is never requested")
    XCTAssertEqual(PageReader.maximumRedirects, 5)
  }

  func testPDFIsSkipped() async {
    for type in ["application/pdf", "image/png", "application/json", "video/mp4", "application/octet-stream"] {
      let client = FakeSearchHTTPClient()
      client.stub(URL(string: "https://example.com/doc")!,
                  .response(status: 200, headers: ["Content-Type": type], body: Data("%PDF-1.7".utf8)))
      let outcome = await reader(client).fetch(URL(string: "https://example.com/doc")!)
      XCTAssertEqual(outcome, .skipped, type)
    }
  }

  func testPlainTextUsedDirectly() async {
    let client = FakeSearchHTTPClient()
    let text = "Plain notes: caf\u{E9} and na\u{EF}ve.\n<b>not markup</b>"
    client.stub(URL(string: "https://example.com/notes.txt")!,
                .response(status: 200, headers: ["Content-Type": "text/plain; charset=utf-8"], body: Data(text.utf8)))
    let outcome = await reader(client).fetch(URL(string: "https://example.com/notes.txt")!)
    XCTAssertEqual(outcome, .page(FetchedPage(requestedURL: URL(string: "https://example.com/notes.txt")!,
                                             finalURL: URL(string: "https://example.com/notes.txt")!,
                                             format: .text, content: text)))
  }

  func testHTMLTypesAreRead() async {
    for type in ["text/html", "TEXT/HTML; charset=UTF-8", "application/xhtml+xml"] {
      let client = FakeSearchHTTPClient()
      client.stub(URL(string: "https://example.com/")!, .response(status: 200, headers: ["Content-Type": type], body: html))
      let outcome = await reader(client).fetch(URL(string: "https://example.com/")!)
      guard case .page(let page) = outcome else { XCTFail(type); continue }
      XCTAssertEqual(page.format, .html, type)
      XCTAssertTrue(page.content.contains("<p>Hello</p>"), type)
    }
  }

  func testMissingContentTypeIsSniffedOnlyForHTML() async {
    let client = FakeSearchHTTPClient()
    client.stub(URL(string: "https://example.com/page")!, .response(status: 200, body: Data("\n  <!DOCTYPE HTML><p>x</p>".utf8)))
    client.stub(URL(string: "https://example.com/blob")!, .response(status: 200, body: Data("%PDF-1.4 binary".utf8)))
    let page = await reader(client).fetch(URL(string: "https://example.com/page")!)
    guard case .page(let fetched) = page else { return XCTFail("\(page)") }
    XCTAssertEqual(fetched.format, .html)
    let blob = await reader(client).fetch(URL(string: "https://example.com/blob")!)
    XCTAssertEqual(blob, .skipped)
  }

  func testUnsuccessfulStatusFails() async {
    for status in [404, 403, 500, 503, 204, 401, 451] {
      let client = FakeSearchHTTPClient()
      client.stub(URL(string: "https://example.com/")!, .response(status: status, headers: ["Content-Type": "text/html"], body: html))
      let outcome = await reader(client).fetch(URL(string: "https://example.com/")!)
      XCTAssertEqual(outcome, .failed, "\(status)")
    }
    let client = FakeSearchHTTPClient()
    client.stub(URL(string: "https://example.com/")!, .failure(.timedOut))
    let timedOut = await reader(client).fetch(URL(string: "https://example.com/")!)
    XCTAssertEqual(timedOut, .failed)
  }

  func testCancelledFetchFails() async {
    let client = FakeSearchHTTPClient()
    client.stub(URL(string: "https://example.com/")!, .hang)
    let pageReader = reader(client)
    let task = Task { await pageReader.fetch(URL(string: "https://example.com/")!) }
    await client.waitForRequests(1)
    task.cancel()
    let outcome = await task.value
    XCTAssertEqual(outcome, .failed)
    XCTAssertEqual(client.cancellations, 1)
  }

  func testCredentialsInLinkAreRefused() async {
    let client = FakeSearchHTTPClient()
    client.fallback = htmlReply()
    let outcome = await reader(client).fetch(URL(string: "https://user:secret@example.com/")!)
    XCTAssertEqual(outcome, .refused)
    XCTAssertTrue(client.requests.isEmpty)
    let other = await reader(client).fetch(URL(string: "mailto:someone@example.com")!)
    XCTAssertEqual(other, .refused)
  }

  func testPageReadAtMostThreeMegabytes() async {
    XCTAssertEqual(PageReader.maximumBytes, 3_145_728)
    let client = FakeSearchHTTPClient()
    client.stub(URL(string: "https://example.com/a")!, redirect(to: "https://example.com/b"))
    var big = Data("<html><body><p>".utf8)
    big.append(Data(repeating: UInt8(ascii: "a"), count: 3_200_000))
    client.stub(URL(string: "https://example.com/b")!, htmlReply(big))
    let outcome = await reader(client).fetch(URL(string: "https://example.com/a")!)
    XCTAssertEqual(client.maximumBytes, [3_145_728, 3_145_728])
    guard case .page(let page) = outcome else { return XCTFail("\(outcome)") }
    XCTAssertEqual(page.content.utf8.count, 3_145_728, "a page cut at the limit is still read")
  }

  func testCharsetFromHeaderThenMetaThenUTF8ThenWindows1252() {
    let latin1Body = Data([0x63, 0x61, 0x66, 0xE9]) // "café" in ISO-8859-1
    // 1. The header wins over the page's own declaration.
    let declaredUTF8 = Data("<meta charset=\"utf-8\">".utf8) + latin1Body
    XCTAssertEqual(PageReader.decode(declaredUTF8, contentType: "text/html; charset=ISO-8859-1"), "<meta charset=\"utf-8\">café")
    XCTAssertEqual(PageReader.decode(latin1Body, contentType: "text/html;charset=\"windows-1252\""), "café")

    // 2. Then <meta charset> or http-equiv in the first 2,048 bytes.
    let cyrillic = "Привет"
    let cp1251 = Data("<html><head><meta charset='windows-1251'></head><body>".utf8)
      + cyrillic.data(using: .windowsCP1251)!
    XCTAssertEqual(PageReader.decode(cp1251, contentType: "text/html"), "<html><head><meta charset='windows-1251'></head><body>" + cyrillic)
    let japanese = "東京の天気"
    let prefix = "<META HTTP-EQUIV=\"Content-Type\" CONTENT=\"text/html; charset=Shift_JIS\">"
    let sjis = Data(prefix.utf8) + japanese.data(using: .shiftJIS)!
    XCTAssertEqual(PageReader.decode(sjis, contentType: nil), prefix + japanese)
    // An unknown header charset falls through to the meta declaration.
    XCTAssertEqual(PageReader.decode(cp1251, contentType: "text/html; charset=x-made-up")?.hasSuffix(cyrillic), true)

    // A declaration past the first 2,048 bytes doesn't count.
    let padding = String(repeating: " ", count: 2_100)
    let late = Data((padding + "<meta charset=\"windows-1251\">ünïcode").utf8)
    XCTAssertEqual(PageReader.decode(late, contentType: "text/html"), padding + "<meta charset=\"windows-1251\">ünïcode")

    // 3. Then UTF-8.
    XCTAssertEqual(PageReader.decode(Data("naïve — 東京".utf8), contentType: "text/html"), "naïve — 東京")

    // 4. Then Windows-1252 (0x93 and 0x94 are curly quotes there, not in ISO-8859-1).
    XCTAssertEqual(PageReader.decode(Data([0x93, 0x68, 0x69, 0x94, 0x20, 0xE9]), contentType: nil), "\u{201C}hi\u{201D} é")
    // Bytes Windows-1252 leaves undefined still decode.
    XCTAssertNotNil(PageReader.decode(Data([0x81, 0x8D, 0x41]), contentType: nil))
  }

  func testByteOrderMarkWinsAndCutUTF8TailIsTrimmed() {
    let bom = Data([0xEF, 0xBB, 0xBF]) + Data("<meta charset=\"windows-1252\">é".utf8)
    XCTAssertEqual(PageReader.decode(bom, contentType: "text/html; charset=iso-8859-1"), "<meta charset=\"windows-1252\">é")
    let utf16 = Data([0xFF, 0xFE]) + "hi".data(using: .utf16LittleEndian)!
    XCTAssertEqual(PageReader.decode(utf16, contentType: nil), "hi")
    // A multi-byte character cut at the byte limit doesn't push the page to Windows-1252.
    var cut = Data("東京は晴れ".utf8)
    cut.removeLast()
    XCTAssertEqual(PageReader.decode(cut, contentType: "text/html"), "東京は晴")
  }

  func testByteOrderMarkDecodesLeniently() {
    let utf8 = Data([0xEF, 0xBB, 0xBF]) + Data("café ".utf8) + Data([0xFF]) + Data(" 東京".utf8)
    XCTAssertEqual(PageReader.decode(utf8, contentType: "text/html"), "café \u{FFFD} 東京")
    var cutUTF8 = Data([0xEF, 0xBB, 0xBF]) + Data("東京".utf8)
    cutUTF8.removeLast()
    XCTAssertEqual(PageReader.decode(cutUTF8, contentType: nil), "東")

    func utf16LE(_ units: [UInt16]) -> Data { Data(units.flatMap { [UInt8($0 & 0xFF), UInt8($0 >> 8)] }) }
    let unpaired = Data([0xFF, 0xFE]) + utf16LE(Array("ab".utf16) + [0xD800] + Array(" 東京".utf16))
    XCTAssertEqual(PageReader.decode(unpaired, contentType: nil), "ab\u{FFFD} 東京")
    // A cut tail: half a code unit, or the first half of a surrogate pair.
    let cutPair = Data([0xFF, 0xFE]) + utf16LE(Array("hi".utf16) + [0xD83D])
    XCTAssertEqual(PageReader.decode(cutPair, contentType: nil), "hi")
    let oddBytes = Data([0xFF, 0xFE]) + utf16LE(Array("hi".utf16)) + Data([0x41])
    XCTAssertEqual(PageReader.decode(oddBytes, contentType: nil), "hi")
    let bigEndian = Data([0xFE, 0xFF]) + Data(Array("ok".utf16).flatMap { [UInt8($0 >> 8), UInt8($0 & 0xFF)] }) + Data([0xDC, 0x00])
    XCTAssertEqual(PageReader.decode(bigEndian, contentType: nil), "ok\u{FFFD}")
  }

  func testProxiedAddressIsUnknownAndPrivateIsRefused() {
    // Through a proxy the reached address is the proxy's, often loopback or private: unknown, kept.
    XCTAssertNil(URLSessionSearchHTTPClient.reachedAddress([(isProxy: true, address: "127.0.0.1")]))
    XCTAssertNil(URLSessionSearchHTTPClient.reachedAddress([(isProxy: true, address: "10.1.2.3")]))
    XCTAssertNil(URLSessionSearchHTTPClient.reachedAddress([]))
    XCTAssertNil(URLSessionSearchHTTPClient.reachedAddress([(isProxy: false, address: nil)]))
    // Without a proxy, the last transaction that reached an address counts.
    let direct = URLSessionSearchHTTPClient.reachedAddress([(isProxy: false, address: "93.184.216.34"),
                                                           (isProxy: false, address: "10.0.0.7"),
                                                           (isProxy: false, address: nil)])
    XCTAssertEqual(direct, "10.0.0.7")
    XCTAssertFalse(NetworkGuard.isPublicRemoteAddress(direct ?? ""), "a non-proxied private address is refused")
    XCTAssertEqual(URLSessionSearchHTTPClient.reachedAddress([(isProxy: false, address: "93.184.216.34")]), "93.184.216.34")
  }

  func testRequestsCarryOnlySafariHeaders() async {
    let client = FakeSearchHTTPClient()
    client.stub(URL(string: "https://example.com/a")!, redirect(to: "https://www.example.com/b"))
    client.stub(URL(string: "https://www.example.com/b")!, htmlReply())
    _ = await reader(client).fetch(URL(string: "https://example.com/a")!)
    XCTAssertEqual(client.requests.count, 2)
    for request in client.requests {
      XCTAssertEqual(request.httpMethod, "GET")
      XCTAssertEqual(request.allHTTPHeaderFields, SafariHeaders.standard(acceptLanguage: "en-GB,en;q=0.9"))
      XCTAssertNil(request.value(forHTTPHeaderField: "Referer"))
      XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
      XCTAssertNil(request.value(forHTTPHeaderField: "Origin"))
      XCTAssertFalse(request.httpShouldHandleCookies)
      XCTAssertNil(request.httpBody)
    }
  }
}
