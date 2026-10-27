import Foundation

/// A local freshness policy, independent of model routing and evidence capacity.
/// Pass the original current question, never an expanded/serialized context.
/// Quoted material, history, files and OCR do not get to opt into network access.
enum WebSearchPolicy {
  static func needsFreshInformation(_ prompt: String, now: Date = Date()) -> Bool {
    needsFreshInformation(normalized: questionText(prompt), now: now)
  }

  /// `needsFreshInformation` for text already normalized by `questionText`.
  /// The person's own communications never search, even when Messages isn't
  /// recognized: their contents must not become a web query.
  static func needsFreshInformation(normalized text: String, now: Date = Date()) -> Bool {
    guard !text.isEmpty, !matches(optOut, text), !isAboutOwnCommunications(text), !matches(thisChat, text) else {
      return false
    }
    if LocationIntent.needsLocation(normalized: text) { return true }
    return needsFreshFacts(text, now: now)
  }

  /// The date window a question asks for. When several match, the shortest wins.
  static func recency(_ prompt: String, now: Date = Date()) -> SearchRecency? {
    let text = questionText(prompt)
    if matches(dayWindow, text) { return .day }
    if matches(weekWindow, text) { return .week }
    if matches(monthWindow, text) { return .month }
    let year = String(Calendar(identifier: .gregorian).component(.year, from: now))
    if matches(yearWindow, text) || fourDigitWord.matches(in: text, range: NSRange(text.startIndex..., in: text))
      .contains(where: { Range($0.range, in: text).map { text[$0] == year } ?? false }) { return .year }
    return nil
  }

  static func questionText(_ prompt: String) -> String {
    let question = ThinkCommand.message(prompt).content
    let text = literalMaterial.stringByReplacingMatches(in: question,
      range: NSRange(question.startIndex..., in: question),
      withTemplate: " ")
      .replacingOccurrences(of: "’", with: "'")
      .lowercased()
    // "whats" typed without its apostrophe reads as "what's", so every pattern sees one spelling.
    let spelled = whatsWithoutApostrophe.stringByReplacingMatches(in: text,
      range: NSRange(text.startIndex..., in: text), withTemplate: "what's")
    // Collapse whitespace runs to one space. A regex is much faster than splitting
    // and joining, and the composer resolves every draft on each keystroke.
    let collapsed = whitespaceRun.stringByReplacingMatches(in: spelled,
      range: NSRange(spelled.startIndex..., in: spelled), withTemplate: " ")
    return collapsed.trimmingCharacters(in: [" "])
  }

  static func isOfflineOrTransformation(_ text: String) -> Bool {
    matches(optOut, text) || matches(transformation, text) || matches(localTask, text)
  }

  /// "the most recent messages from my dad", "what's new in my texts", "what did Jordan send me",
  /// "what did Mom say today". News about others ("the latest message from the White House")
  /// still searches, and so do drafts that can't tell, such as "what's the latest from Sam".
  /// Nouns that only ever mean personal messages (texts, voicemails, DMs) veto search with
  /// any first-person word anywhere: "who's been blowing up my phone with texts today".
  /// Ambiguous ones (messages, chats, calls, mail) need the person next to them.
  static func isAboutOwnCommunications(_ text: String) -> Bool {
    guard matches(communicationWord, text) else { return false }
    return (matches(personalTerm, text) && matches(firstPerson, text)) || matches(ownCommunications, text)
  }

  private static func needsFreshFacts(_ text: String, now: Date) -> Bool {
    if matches(explicitLookup, text) { return true }
    guard !matches(transformation, text), !matches(localTask, text) else { return false }

    if matches(recentDevelopments, text) { return true }
    let asksForFacts = matches(factualRequest, text)
    if asksForFacts && matches(recency, text) { return true }
    let year = Calendar(identifier: .gregorian).component(.year, from: now)
    let years = text.split(whereSeparator: { !$0.isNumber }).compactMap { part -> Int? in
      guard part.count == 4, let value = Int(part), (1000...2999).contains(value) else { return nil }
      return value
    }
    let historical = years.contains { $0 < year - 1 } || matches(historicalTopic, text)
    if !historical && !matches(conceptualQuestion, text) && matches(changingFact, text) { return true }

    // A year alone is not a freshness signal (arithmetic and historical questions
    // stay local). Current/recent event queries can omit words such as "latest".
    guard asksForFacts && matches(eventTopic, text) else { return false }
    let recentYears = year - 1...year + 1
    return fourDigitWord.matches(in: text, range: NSRange(text.startIndex..., in: text)).contains { match in
      Range(match.range, in: text).flatMap { Int(text[$0]) }.map(recentYears.contains) ?? false
    }
  }

  private static func matches(_ pattern: NSRegularExpression, _ text: String) -> Bool {
    pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
  }

  private static func expression(_ pattern: String) -> NSRegularExpression {
    // All patterns are fixed, tested source literals, never user-provided regexes.
    try! NSRegularExpression(pattern: pattern)
  }

  private static let whitespaceRun = expression(#"\p{White_Space}+"#)
  private static let whatsWithoutApostrophe = expression(#"\bwhats\b"#)
  private static let fourDigitWord = expression(#"\b[0-9]{4}\b"#)
  private static let literalMaterial = expression(#"(?s)```.*?(?:```|$)|`[^`]*(?:`|$)|"[^"\n]*(?:"|$)|“[^”]*(?:”|$)"#)
  private static let optOut = expression(#"\b(?:(?:do not|don't|dont|never) (?:\w+ ){0,3}(?:search|browse|look up|use (?:the )?(?:web|internet))|(?:without|no) (?:\w+ ){0,2}(?:web|internet|browsing|search)|(?:stay|answer|respond|keep (?:this|it)) offline|(?:use|using|from) (?:only )?(?:your (?:own |existing )?knowledge|memory only))\b"#)
  private static let explicitLookup = expression(#"^(?:(?:please|can you|could you) )?(?:search|browse|check|look up|find|verify)\b.{0,60}\b(?:web|internet|online)\b"#)
  private static let transformation = expression(#"^(?:(?:please|can you|could you|help me) )?(?:translate|rewrite|rephrase|proofread|paraphrase|(?:write|draft|compose) (?:(?:a|an|me|a short|a new) )?(?:poem|story|email|message|letter|function|script|test)|invent|imagine|roleplay|pretend|debug|refactor|implement|fix (?:this|my|the) (?:code|function|test)|summari[sz]e (?:this|the following|the attached|my))\b"#)
  private static let localTask = expression(#"\b(?:current|latest|recent) (?:file|folder|directory|selection|function|variable|branch|commit|diff|log|chat|conversation|document|draft|code|buffer|working directory)\b"#)
  private static let factualRequest = expression(#"\b(?:what|who|when|where|which|how|is|are|has|have|did|does|do|can|could|tell me|give me|show me|find|check|compare|summari[sz]e|explain|list|write|update me)\b"#)
  private static let recency = expression(#"\b(?:latest|recent|recently|newest|breaking|currently|today|yesterday|tonight|tomorrow|right now|up[- ]to[- ]date|this (?:week|weekend|month|year|season)|(?:past|last) (?:night|weekend|week|month|year|\d+ (?:hours|days|weeks))|current (?!in\b|through\b|flow\b|flows\b|density\b|account\b|assets\b|liabilities\b))\b"#)
  private static let recentDevelopments = expression(#"\b(?:(?:latest|recent|breaking|today'?s|current|new|upcoming) (?:\w+ ){0,3}(?:news|headlines|updates|developments|events|research|studies|announcements|releases|products)|(?:news|headlines|updates) (?:about|on|from|in|for)|what'?s (?:new|happening|going on)|what is (?:new|happening|going on))\b"#)
  private static let changingFact = expression(#"\b(?:(?:who (?:is|'s)|who's) (?:the )?(?:president|prime minister|ceo|governor|mayor|leader|champion)\b|(?:weather|forecast) (?:in|for|at)\b|(?:will it|is it going to) (?:rain|snow)\b|(?:stock|share|bitcoin|btc|ethereum|eth) price\b|(?:price|value) of (?:bitcoin|btc|ethereum|eth)\b|(?:exchange|mortgage) rates?\b|(?:who (?:won|is winning)|score (?:of|in)|scores? for)\b|(?:when (?:is|does)|what time (?:is|does))\b.{0,60}\b(?:next|play|start|open|close|release)\b|(?:is|are)\b.{0,50}\b(?:open now|still available|in stock)\b)"#)
  private static let personalTerm = expression(#"\b(?:texts|text messages?|imessages?|sms|voicemails?|dms|direct messages|missed calls?)\b"#)
  private static let firstPerson = expression(#"\b(?:my|me|i|i'm|im|our|us)\b"#)
  /// This chat, not anything to look up: "the first message I sent you".
  private static let thisChat = expression(#"\b(?:message|text|question|prompt)s? (?:i|we) (?:sent|asked|gave|wrote) you\b|\byou (?:sent|told|gave|wrote) (?:me|us)\b"#)
  /// A word every `ownCommunications` match contains.
  private static let communicationWord = expression(#"messag|text|mail|dm|chat|voicemail|call|inbox|sms|send|sent|did (?:i|we)|from|my |our |mom|dad|mum|phone|facetime"#)
  private static let ownCommunications: NSRegularExpression = {
    let term = #"(?:text messages?|messages?|texts?|imessages?|e-mails?|emails?|dms|direct messages?|chats?|group chats?|voicemails?|(?:missed|phone) calls?|inbox(?:es)?|sms)"#
    let relation = #"(?:dad|mom|mum|mother|father|parents|sister|brother|wife|husband|partner|girlfriend|boyfriend|son|daughter|kids|grandma|grandpa|grandmother|grandfather|nana|granny|aunt|uncle|cousin|friends?|best friend|roommate|boss|manager|coworkers?|colleagues?|landlord|family|ex)"#
    // The term sits next to the person: "my latest texts", "messages from my dad", "texts for me",
    // "what texts did I get", "what emails came in". Not "the earnings call for my stock".
    return expression(#"\b(?:my|our) (?:(?:new|unread|recent|latest|last|most|few|missed|old|own|family|work|group|text|direct|personal) ){0,3}\#(term)\b(?! (?:apps?|components?|tables?|endpoints?|apis?|views?|schemas?)\b)"#
      + #"|\b\#(term) (?:(?:from|to|with|for|between) )?(?:me|us)\b|\b\#(term) (?:from|with|by) (?:my|our) (?:\w+ )?\#(relation)\b"#
      + #"|\b\#(term) (?:did|have|has|had) (?:i|we)\b|\b\#(term) (?:\w+ )?(?:came|come|coming) in\b"#
      // "what did Jordan send me", "did I get any texts", "what did Mom say today", "any news from my sister".
      + #"|\b(?:did|has|have|had)\b(?: [\w']+){1,3} (?:send|sent) (?:me|us)\b|\bdid (?:i|we) (?:get|miss|receive)\b|\b(?:did|has|have)\b(?: [\w']+){1,2} call(?:ed)? (?:me|us)\b|\bwho called (?:me|us)\b"#
      + #"|\b(?:what|did|has) (?:did )?(?:(?:my|our) \#(relation)|mom|dad|mum) (?:say|said|send|sent|text|texted|write|wrote|tell|told)\b|\bfrom (?:my|our) \#(relation)\b"#
      // A call with family or with me: "what did Grandpa say on the phone yesterday".
      + #"|\b\#(relation)\b.{0,40}\b(?:on|over) (?:the phone|a call|facetime)\b|\b(?:on|over) (?:the phone|a call|facetime) (?:with|to) (?:me|us|(?:(?:my|our) )?\#(relation))\b|\bwhen (?:(?:my|our) )?(?:\#(relation)|he|she|they) called\b"#)
  }()
  // "live" alone would filter "where do penguins live" to the past day.
  private static let dayWindow = expression(#"\b(?:today|tonight|right now|this (?:morning|afternoon|evening)|live (?:scores?|updates|results|coverage|blog))\b"#)
  private static let weekWindow = expression(#"\b(?:latest|recent|news|breaking|this week|yesterday)\b"#)
  private static let monthWindow = expression(#"\bthis month\b"#)
  private static let yearWindow = expression(#"\bthis year\b"#)
  private static let historicalTopic = expression(#"\b(?:world war|ancient|medieval|roman empire|historical|history of)\b"#)
  private static let conceptualQuestion = expression(#"\b(?:what (?:is|are)|define|explain|how (?:does|do)) (?:a |an |the concept of )?(?:weather|stock prices?|share prices?|exchange rates?|mortgage rates?)(?: work| mean| change| fluctuate)?[?.!]*$"#)
  private static let eventTopic = expression(#"\b(?:election|elections|results|winner|winners|release|releases|announcements|conference|summit|wwdc|schedule|standings|season|tournament|olympics|world cup|budget|laws|regulations)\b"#)
}
