import Foundation

/// One entity's facts from Wikidata, newest first per property, with their dates.
struct WikidataEntityFacts: Equatable, Sendable {
  struct Fact: Equatable, Sendable {
    let property: String
    /// Values as text: the value, its qualifiers in brackets ("1.99.1 (stable version; 2026-10-02; current)").
    let values: [String]
  }

  let id: String
  let label: String
  let description: String?
  let facts: [Fact]

  var url: URL { URL(string: "https://www.wikidata.org/wiki/\(id)")! }
}

/// Wikidata's keyless action API (D104, D109): the entity the question names, and a whitelist of
/// its statements with their dates. Sends only the entity's name or the Wikipedia title, never
/// the question; Wikipedia's headers (Wikimedia's User-Agent policy).
struct WikidataFacts: Sendable {
  static let maximumBytes = 6_291_456
  static let endpoint = "https://www.wikidata.org/w/api.php"

  /// The properties shown, in this order, with their English names. Values per property: 3, or
  /// 5 for winners.
  static let properties: [(id: String, name: String)] = [
    ("P348", "software version"), ("P1082", "population"), ("P1346", "winner"), ("P35", "head of state"),
    ("P6", "head of government"), ("P169", "chief executive officer"), ("P488", "chairperson"),
    ("P36", "capital"), ("P2131", "nominal GDP"), ("P2046", "area"), ("P2048", "height"), ("P2044", "elevation"),
    ("P569", "date of birth"), ("P570", "date of death"), ("P571", "inception"), ("P577", "publication date"),
    ("P112", "founded by"), ("P159", "headquarters location"), ("P1128", "employees"), ("P2139", "total revenue"),
    ("P38", "currency"), ("P856", "official website"),
  ]
  static let valuesPerProperty = 3
  static let winnerValues = 5

  /// Point in time, publication date, start time, end time; version type.
  private static let dateQualifiers = ["P585", "P577", "P580"]
  private static let endQualifier = "P582"
  private static let versionType = "P548"

  // MARK: Requests

  static func searchRequest(entity: String, language: String) -> URLRequest {
    request([("action", "wbsearchentities"), ("search", entity), ("language", language), ("uselang", language),
             ("type", "item"), ("limit", "1"), ("format", "json")])
  }

  static func sitelinkRequest(title: String, language: String) -> URLRequest {
    request([("action", "wbgetentities"), ("sites", "\(language)wiki"), ("titles", title), ("props", "info"),
             ("format", "json")])
  }

  static func entityRequest(id: String, language: String) -> URLRequest {
    request([("action", "wbgetentities"), ("ids", id), ("props", "labels|descriptions|claims"),
             ("languages", language == "en" ? "en" : "\(language)|en"), ("format", "json")])
  }

  static func labelsRequest(ids: [String], language: String) -> URLRequest {
    request([("action", "wbgetentities"), ("ids", ids.joined(separator: "|")), ("props", "labels"),
             ("languages", language == "en" ? "en" : "\(language)|en"), ("format", "json")])
  }

  private static func request(_ query: [(String, String)]) -> URLRequest {
    let items = query.map { "\(SearchFormEncoding.percentEncode($0.0))=\(SearchFormEncoding.percentEncode($0.1))" }
    var request = URLRequest(url: URL(string: endpoint + "?" + items.joined(separator: "&"))!)
    request.httpMethod = "GET"
    request.setValue(WikipediaSearch.userAgent, forHTTPHeaderField: "User-Agent")
    request.setValue("application/json", forHTTPHeaderField: "Accept")
    return request
  }

  // MARK: Lookup

  /// `entity` is the rewrite's entity name; `wikipediaTitle`, the article this search found. nil
  /// when neither finds an item, a request fails, or none of the whitelisted properties is set.
  func lookup(entity: String?, wikipediaTitle: String?, preferredLanguages: [String],
              using client: any SearchHTTPClient) async -> WikidataEntityFacts? {
    let language = WikipediaSearch.language(for: preferredLanguages)
    var id: String?
    if let entity {
      // "Swift (programming language)" is a Wikipedia title: its sitelink is exact. A bare name
      // goes to the entity search, whose first hit is the best known item ("Rust" → the language).
      let bare = Self.withoutQualifier(entity)
      if bare != entity, let json = await Self.json(Self.sitelinkRequest(title: entity, language: language), client: client) {
        id = Self.parseSitelink(json)
      }
      if id == nil, let json = await Self.json(Self.searchRequest(entity: bare, language: language), client: client) {
        id = Self.parseSearch(json)
      }
    }
    if id == nil, let wikipediaTitle,
       let json = await Self.json(Self.sitelinkRequest(title: wikipediaTitle, language: language), client: client) {
      id = Self.parseSitelink(json)
    }
    guard let id, let json = await Self.json(Self.entityRequest(id: id, language: language), client: client),
          let entity = Self.parseEntity(json, id: id) else { return nil }
    let wanted = Self.referencedIDs(entity)
    var labels: [String: String] = [:]
    if !wanted.isEmpty {
      // The API takes up to 50 IDs per call.
      if let json = await Self.json(Self.labelsRequest(ids: Array(wanted.prefix(50)), language: language),
                                    client: client) {
        labels = Self.parseLabels(json, language: language)
      }
    }
    return Self.facts(entity, labels: labels, language: language)
  }

  /// "Swift (programming language)" → "Swift".
  static func withoutQualifier(_ name: String) -> String {
    guard name.hasSuffix(")"), let open = name.lastIndex(of: "(") else { return name }
    let bare = name[..<open].trimmingCharacters(in: .whitespaces)
    return bare.isEmpty ? name : bare
  }

  // MARK: Parsing

  /// The statements of one entity, as the API returns them.
  struct Entity: Sendable {
    let id: String
    let labels: [String: String]
    let descriptions: [String: String]
    /// Property ID → statements.
    let claims: [String: [Statement]]
  }

  struct Statement: Equatable, Sendable {
    enum Value: Equatable, Sendable {
      case item(String)
      case quantity(amount: String, unit: String?)
      /// The API's time and its precision: 9 a year, 10 a month, 11 a day (coarser shows the year).
      case time(String, precision: Int)
      case text(String)
    }

    let value: Value
    let rank: String
    /// Qualifier property → values.
    let qualifiers: [String: [Value]]
  }

  static func parseSearch(_ json: [String: Any]) -> String? {
    guard let hits = json["search"] as? [[String: Any]], let id = hits.first?["id"] as? String,
          isItemID(id) else { return nil }
    return id
  }

  static func parseSitelink(_ json: [String: Any]) -> String? {
    guard let entities = json["entities"] as? [String: Any] else { return nil }
    return entities.keys.filter(isItemID).sorted().first
  }

  static func parseEntity(_ json: [String: Any], id: String) -> Entity? {
    guard let entities = json["entities"] as? [String: Any], let raw = entities[id] as? [String: Any] else { return nil }
    func texts(_ key: String) -> [String: String] {
      var result: [String: String] = [:]
      for (language, value) in (raw[key] as? [String: Any]) ?? [:] {
        if let text = (value as? [String: Any])?["value"] as? String { result[language] = text }
      }
      return result
    }
    var claims: [String: [Statement]] = [:]
    let rawClaims = (raw["claims"] as? [String: Any]) ?? [:]
    for (property, _) in properties {
      guard let list = rawClaims[property] as? [[String: Any]] else { continue }
      let statements = list.compactMap { statement -> Statement? in
        guard let snak = statement["mainsnak"] as? [String: Any], let value = parseValue(snak) else { return nil }
        var qualifiers: [String: [Statement.Value]] = [:]
        for (qualifier, snaks) in (statement["qualifiers"] as? [String: Any]) ?? [:] {
          let values = ((snaks as? [[String: Any]]) ?? []).compactMap(parseValue)
          if !values.isEmpty { qualifiers[qualifier] = values }
        }
        return Statement(value: value, rank: statement["rank"] as? String ?? "normal", qualifiers: qualifiers)
      }
      if !statements.isEmpty { claims[property] = statements }
    }
    return Entity(id: id, labels: texts("labels"), descriptions: texts("descriptions"), claims: claims)
  }

  private static func parseValue(_ snak: [String: Any]) -> Statement.Value? {
    guard snak["snaktype"] as? String == "value", let data = snak["datavalue"] as? [String: Any] else { return nil }
    let value = data["value"]
    switch data["type"] as? String {
    case "wikibase-entityid":
      guard let id = (value as? [String: Any])?["id"] as? String, isItemID(id) else { return nil }
      return .item(id)
    case "quantity":
      guard let fields = value as? [String: Any], let amount = fields["amount"] as? String else { return nil }
      let unit = (fields["unit"] as? String).flatMap { $0 == "1" ? nil : $0.split(separator: "/").last.map(String.init) }
      return .quantity(amount: amount, unit: unit.flatMap { isItemID($0) ? $0 : nil })
    case "time":
      guard let fields = value as? [String: Any], let time = fields["time"] as? String else { return nil }
      return .time(time, precision: (fields["precision"] as? Int) ?? 11)
    case "string":
      guard let text = value as? String else { return nil }
      return .text(text)
    case "monolingualtext":
      guard let text = (value as? [String: Any])?["text"] as? String else { return nil }
      return .text(text)
    default:
      return nil
    }
  }

  static func parseLabels(_ json: [String: Any], language: String) -> [String: String] {
    var labels: [String: String] = [:]
    for (id, raw) in (json["entities"] as? [String: Any]) ?? [:] {
      let all = ((raw as? [String: Any])?["labels"] as? [String: Any]) ?? [:]
      let chosen = (all[language] as? [String: Any]) ?? (all["en"] as? [String: Any])
      if let text = chosen?["value"] as? String { labels[id] = text }
    }
    return labels
  }

  /// The items whose labels the facts need: values, units and version types, in property order.
  static func referencedIDs(_ entity: Entity) -> [String] {
    var ids: [String] = []
    var seen = Set<String>()
    func add(_ value: Statement.Value) {
      switch value {
      case .item(let id): if seen.insert(id).inserted { ids.append(id) }
      case .quantity(_, let unit?): if seen.insert(unit).inserted { ids.append(unit) }
      default: break
      }
    }
    for (property, _) in properties {
      for statement in shown(entity.claims[property] ?? [], property: property) {
        add(statement.value)
        statement.qualifiers[versionType]?.forEach(add)
      }
    }
    return ids
  }

  /// Deprecated statements dropped; newest first by their date qualifier, then preferred first;
  /// capped per property.
  static func shown(_ statements: [Statement], property: String) -> [Statement] {
    let live = statements.filter { $0.rank != "deprecated" }
    let ordered = live.enumerated().sorted { left, right in
      let leftDate = date(of: left.element), rightDate = date(of: right.element)
      if leftDate != rightDate { return (leftDate ?? .min) > (rightDate ?? .min) }
      if (left.element.rank == "preferred") != (right.element.rank == "preferred") {
        return left.element.rank == "preferred"
      }
      return left.offset < right.offset
    }.map(\.element)
    let limit = property == "P1346" ? winnerValues : valuesPerProperty
    // The preferred value always shows, even when newer normal ones fill the cap.
    var kept = Array(ordered.prefix(limit))
    if let preferred = ordered.first(where: { $0.rank == "preferred" }), !kept.contains(preferred) {
      kept[kept.count - 1] = preferred
    }
    return kept
  }

  /// The statement's own date (a time value) or its first date qualifier, as a signed number
  /// (year × 10,000 + month × 100 + day), so dates before the common era sort too.
  private static func date(of statement: Statement) -> Int? {
    if case .time(let time, _) = statement.value { return sortKey(time) }
    for qualifier in dateQualifiers {
      if case .time(let time, _)? = statement.qualifiers[qualifier]?.first { return sortKey(time) }
    }
    return nil
  }

  static func sortKey(_ time: String) -> Int? {
    guard let match = time.firstMatch(of: /^([+-])(\d{1,16})-(\d{2})-(\d{2})T/),
          let year = Int(match.2), let month = Int(match.3), let day = Int(match.4) else { return nil }
    return (match.1 == "-" ? -year : year) * 10_000 + month * 100 + day
  }

  static func facts(_ entity: Entity, labels: [String: String], language: String) -> WikidataEntityFacts? {
    var facts: [WikidataEntityFacts.Fact] = []
    for (property, name) in properties {
      let values = shown(entity.claims[property] ?? [], property: property).compactMap { statement -> String? in
        guard let text = describe(statement.value, labels: labels) else { return nil }
        var notes: [String] = []
        if let type = statement.qualifiers[versionType]?.first, let label = describe(type, labels: labels) {
          notes.append(label)
        }
        if case .time = statement.value {} else {
          for qualifier in dateQualifiers {
            if case .time(let time, let precision)? = statement.qualifiers[qualifier]?.first,
               let day = formatTime(time, precision: precision) {
              notes.append(qualifier == "P580" ? "since \(day)" : day)
              break
            }
          }
        }
        if case .time(let end, let precision)? = statement.qualifiers[endQualifier]?.first,
           let day = formatTime(end, precision: precision) {
          notes.append("until \(day)")
        }
        if statement.rank == "preferred" { notes.append("current") }
        return notes.isEmpty ? text : "\(text) (\(notes.joined(separator: "; ")))"
      }
      if !values.isEmpty { facts.append(.init(property: name, values: values)) }
    }
    guard !facts.isEmpty else { return nil }
    let label = entity.labels[language] ?? entity.labels["en"] ?? entity.id
    return WikidataEntityFacts(id: entity.id, label: label,
                               description: entity.descriptions[language] ?? entity.descriptions["en"], facts: facts)
  }

  private static func describe(_ value: Statement.Value, labels: [String: String]) -> String? {
    switch value {
    case .item(let id):
      return labels[id]
    case .quantity(let amount, let unit):
      let number = formatAmount(amount)
      guard let unit else { return number }
      return labels[unit].map { "\(number) \($0)" } ?? number
    case .time(let time, let precision):
      return formatTime(time, precision: precision)
    case .text(let text):
      return text
    }
  }

  /// "+123802000" → "123,802,000"; decimals kept.
  static func formatAmount(_ amount: String) -> String {
    let trimmed = amount.hasPrefix("+") ? String(amount.dropFirst()) : amount
    let parts = trimmed.split(separator: ".", maxSplits: 1)
    guard let whole = parts.first, whole.allSatisfy({ $0.isNumber || $0 == "-" }) else { return trimmed }
    let negative = whole.hasPrefix("-")
    let digits = Array(whole.drop(while: { $0 == "-" }))
    var grouped = ""
    for (index, digit) in digits.enumerated() {
      if index > 0, (digits.count - index) % 3 == 0 { grouped.append(",") }
      grouped.append(digit)
    }
    return (negative ? "-" : "") + grouped + (parts.count > 1 ? "." + parts[1] : "")
  }

  /// "+2026-10-02T00:00:00Z" at day precision (11) → "2026-10-02"; month precision (10) →
  /// "2026-10"; year precision (9) or coarser → "2026". "-00" parts shorten it too.
  static func formatTime(_ time: String, precision: Int = 11) -> String? {
    guard let match = time.firstMatch(of: /^([+-])(\d{1,16})-(\d{2})-(\d{2})T/) else { return nil }
    let year = String(Int(match.2) ?? 0)
    let prefix = match.1 == "-" ? "-" : ""
    if precision <= 9 || match.3 == "00" { return prefix + year }
    if precision == 10 || match.4 == "00" { return "\(prefix)\(year)-\(match.3)" }
    return "\(prefix)\(year)-\(match.3)-\(match.4)"
  }

  /// The facts as one evidence excerpt.
  static func excerpt(_ facts: WikidataEntityFacts) -> WebSearchResult {
    var lines = ["Wikidata facts for \(facts.label)" + (facts.description.map { " (\($0))" } ?? "")
                 + ". Values are newest first; dates are when each value applied or was published."]
    for fact in facts.facts {
      lines.append("- \(fact.property): \(fact.values.joined(separator: "; "))")
    }
    return WebSearchResult(source: WebSearchSource(title: "\(facts.label) — Wikidata", url: facts.url),
                           snippets: [lines.joined(separator: "\n")], site: "Wikidata", kind: .facts)
  }

  static func isItemID(_ id: String) -> Bool {
    id.count > 1 && id.first == "Q" && id.dropFirst().allSatisfy(\.isNumber)
  }

  private static func json(_ request: URLRequest, client: any SearchHTTPClient) async -> [String: Any]? {
    // A cancelled search stops between requests (D124).
    guard !Task.isCancelled, let response = try? await client.send(request, maximumBytes: maximumBytes), response.statusCode == 200,
          !response.truncated else { return nil }
    return (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any]
  }
}
