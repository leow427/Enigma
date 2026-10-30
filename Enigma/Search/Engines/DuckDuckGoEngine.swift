// Ported from ddgs v9.16.1, ddgs/engines/duckduckgo.py (MIT). XPaths are verbatim; see UPSTREAM.json.
import Foundation

/// DuckDuckGo's HTML endpoint, which serves Bing's index (spec §2).
struct DuckDuckGoEngine: SearchEngine {
  static let searchURL = URL(string: "https://html.duckduckgo.com/html/")!
  /// Results pages stop at 2 MB (spec §2, "Limits").
  static let maximumBytes = 2_097_152

  static let itemsXPath = "//div[contains(@class, 'body')]"
  static let titleXPath = ".//h2//text()"
  static let hrefXPath = "./a/@href"
  static let bodyXPath = "./a//text()"

  let id = SearchEngineID.duckDuckGo
  let weight = 1.0

  func search(_ query: EngineQuery, using client: any SearchHTTPClient) async -> EngineOutcome {
    do {
      return Self.parse(try await client.send(Self.request(for: query), maximumBytes: Self.maximumBytes))
    } catch {
      return .failed
    }
  }

  /// ddgs's form, except `kl` for the region, which is the field DuckDuckGo reads (owner, CP0b).
  /// Page 2 and later add ddgs's `s` offset; nothing asks for them yet (decision D38).
  static func request(for query: EngineQuery, page: Int = 1) -> URLRequest {
    var fields: [(String, String)] = [("q", query.text), ("b", ""), ("kl", regionCode(for: query.region))]
    if page > 1 { fields.append(("s", String(10 + (page - 2) * 15))) }
    if let recency = query.recency { fields.append(("df", recency.rawValue)) }
    var request = URLRequest(url: searchURL)
    request.httpMethod = "POST"
    for (name, value) in SafariHeaders.formPost(to: searchURL, acceptLanguage: SafariHeaders.preferredAcceptLanguage) {
      request.setValue(value, forHTTPHeaderField: name)
    }
    request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
    request.httpBody = SearchFormEncoding.formBody(fields)
    return request
  }

  static func parse(_ response: SearchHTTPResponse) -> EngineOutcome {
    switch response.statusCode {
    case 200: break
    case 202, 429: return .rateLimited
    case 403, 503: return .blocked
    // The endpoint moved or rejected the form: the port needs updating (D47).
    case 300..<400, 400, 404, 405, 410: return .unrecognized
    // A server error or a too-long query, among others: not a sign of a changed site.
    default: return .failed
    }
    let page = String(decoding: response.body, as: UTF8.self)
    if isBotCheck(page) { return .blocked }
    guard let document = SERPDocument(html: response.body) else { return .unrecognized }

    let items = document.nodes(itemsXPath, in: nil)
    var results: [EngineResult] = []
    var ads = 0
    for item in items {
      guard document.nodes("ancestor-or-self::*[contains(@class, 'result--ad')]", in: item).isEmpty else {
        ads += 1
        continue
      }
      guard let href = document.value(hrefXPath, in: item) else { continue }
      guard !href.hasPrefix("https://duckduckgo.com/y.js?") else {
        ads += 1
        continue
      }
      let title = document.text(titleXPath, in: item)
      guard let url = resultURL(href), !title.isEmpty else { continue }
      results.append(EngineResult(title: title, url: url, snippet: document.text(bodyXPath, in: item),
                                  position: results.count + 1, engine: .duckDuckGo))
    }
    if !results.isEmpty { return .results(results) }
    // A page of nothing but ads was still understood. Items without a usable link are not: that is
    // how a layout change looks, so it is reported rather than taken for an empty search.
    if hasNoResultsMarker(document) || (ads > 0 && ads == items.count) { return .noResults }
    return .unrecognized
  }

  /// "bots use DuckDuckGo too": the image challenge, served with 202 or 200 (CP0's markers).
  private static func isBotCheck(_ page: String) -> Bool {
    page.contains("id=\"challenge-form\"") || page.contains("anomaly-modal__")
      || page.range(of: "bots use DuckDuckGo too", options: .caseInsensitive) != nil
  }

  /// The `no-results` message DuckDuckGo showed for a nonsense query in CP2's live probe; it sits in
  /// a `result--no-result` item that has no link.
  private static func hasNoResultsMarker(_ document: SERPDocument) -> Bool {
    !document.nodes("//*[contains(@class, 'no-results') or contains(@class, 'result--no-result')]", in: nil).isEmpty
  }

  /// Only http and https links; `//duckduckgo.com/l/?uddg=` redirects become their target.
  private static func resultURL(_ href: String) -> URL? {
    var target = href
    if href.hasPrefix("//duckduckgo.com/l/?") || href.hasPrefix("https://duckduckgo.com/l/?") {
      let absolute = href.hasPrefix("//") ? "https:" + href : href
      guard let wrapped = URLComponents(string: absolute)?.queryItems?.first(where: { $0.name == "uddg" })?.value else {
        return nil
      }
      target = wrapped
    }
    guard let url = URL(string: target), let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https",
          url.host()?.isEmpty == false else { return nil }
    return url
  }

  /// DuckDuckGo's own region values (`kl`), from the `<select name="kl">` on its results page
  /// (`duckduckgo-no-results.html`, captured 2026-10-30). A country it doesn't list gets `wt-wt`,
  /// all regions (decisions D35, D42).
  static func regionCode(for region: SearchRegion) -> String {
    guard let choices = regions[region.country] else { return "wt-wt" }
    return choices.first { $0.language == region.language }?.code ?? choices[0].code
  }

  /// Every code `regionCode(for:)` can send, besides `wt-wt`.
  static var regionCodes: [String] { regions.values.flatMap { $0.map(\.code) } }

  /// ISO country → DuckDuckGo's codes with the ISO language each serves; the first is the default.
  private static let regions: [String: [(code: String, language: String)]] = [
    "ar": [("ar-es", "es")], "au": [("au-en", "en")], "at": [("at-de", "de")],
    "be": [("be-nl", "nl"), ("be-fr", "fr")], "br": [("br-pt", "pt")], "bg": [("bg-bg", "bg")],
    "ca": [("ca-en", "en"), ("ca-fr", "fr")], "cl": [("cl-es", "es")], "cn": [("cn-zh", "zh")],
    "co": [("co-es", "es")], "hr": [("hr-hr", "hr")], "cz": [("cz-cs", "cs")], "dk": [("dk-da", "da")],
    "ee": [("ee-et", "et")], "fi": [("fi-fi", "fi")], "fr": [("fr-fr", "fr")], "de": [("de-de", "de")],
    "gr": [("gr-el", "el")], "hk": [("hk-tzh", "zh")], "hu": [("hu-hu", "hu")], "is": [("is-is", "is")],
    "in": [("in-en", "en")], "id": [("id-en", "en")], "ie": [("ie-en", "en")], "il": [("il-en", "en")],
    "it": [("it-it", "it")], "jp": [("jp-jp", "ja")], "kr": [("kr-kr", "ko")], "lv": [("lv-lv", "lv")],
    "lt": [("lt-lt", "lt")], "my": [("my-en", "en")], "mx": [("mx-es", "es")], "nl": [("nl-nl", "nl")],
    "nz": [("nz-en", "en")], "no": [("no-no", "nb")], "pk": [("pk-en", "en")], "pe": [("pe-es", "es")],
    "ph": [("ph-en", "en")], "pl": [("pl-pl", "pl")], "pt": [("pt-pt", "pt")], "ro": [("ro-ro", "ro")],
    "ru": [("ru-ru", "ru")], "sa": [("xa-ar", "ar")], "sg": [("sg-en", "en")], "sk": [("sk-sk", "sk")],
    "si": [("sl-sl", "sl")], "za": [("za-en", "en")], "es": [("es-es", "es"), ("es-ca", "ca")],
    "se": [("se-sv", "sv")], "ch": [("ch-de", "de"), ("ch-fr", "fr")], "tw": [("tw-tzh", "zh")],
    "th": [("th-en", "en")], "tr": [("tr-tr", "tr")], "us": [("us-en", "en"), ("us-es", "es")],
    "ua": [("ua-uk", "uk")], "gb": [("uk-en", "en")], "vn": [("vn-en", "en")],
  ]
}
