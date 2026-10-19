import Foundation
import XCTest
@testable import Enigma

/// The yardstick for command recognition: realistic English phrasings, each tagged
/// with the one chip it should get. A miss found later becomes a line here.
final class ComposerIntentPhrasingTests: XCTestCase {
  /// September 2026, so year-based search phrasings stay stable.
  private let now = Date(timeIntervalSince1970: 1_788_825_600)

  private func resolve(_ draft: String) -> ComposerIntent {
    ComposerIntent.resolve(.init(draft: draft, infersCommands: true, searchesAutomatically: true), now: now)
  }

  private func assertResolves(_ phrasings: [String], to expected: [SlashCommand], file: StaticString = #filePath,
                              line: UInt = #line) {
    for draft in phrasings {
      let intent = resolve(draft)
      XCTAssertEqual(intent.inferred, expected, #""\#(draft)" should resolve to \#(expected.map(\.rawValue))"#,
                     file: file, line: line)
    }
  }

  func testMessagesPhrasings() {
    assertResolves(PhrasingCorpus.messages, to: [.messages])
  }

  func testMessagesPhrasingsNeverSearch() {
    for draft in PhrasingCorpus.messages {
      XCTAssertFalse(resolve(draft).search, #""\#(draft)" must not search"#)
    }
  }

  func testThinkPhrasings() {
    assertResolves(PhrasingCorpus.think, to: [.think])
  }

  func testSearchPhrasings() {
    assertResolves(PhrasingCorpus.search, to: [.search])
  }

  func testPhrasingsThatRecognizeNothing() {
    assertResolves(PhrasingCorpus.none, to: [])
  }

  func testLongRepeatedDraftsStayFast() {
    // Each cue runs its lookbehinds only after its literal word, so pathological repeats stay cheap.
    for word in ["consider ", "think ", "take ", "my ", "sam's ", "what did sam say said ", "text "] {
      let draft = String(repeating: word, count: 40_000 / word.count)
      let start = Date()
      _ = resolve(draft)
      XCTAssertLessThan(Date().timeIntervalSince(start), 2, word)
    }
  }

  func testCorpusSize() {
    let all = PhrasingCorpus.messages + PhrasingCorpus.think + PhrasingCorpus.search + PhrasingCorpus.none
    XCTAssertGreaterThanOrEqual(all.count, 300)
    XCTAssertEqual(Set(all).count, all.count, "Each phrasing appears once")
  }
}

private enum PhrasingCorpus {
  static let messages = [
    // Reading.
    "what are the most recent messages from my dad", "what did my dad text me", "show me my texts from mom",
    "did my sister message me today", "any messages from Sam?", "what was Alex's last text",
    "read me the last message from Jordan", "what has Sam been texting me about", "summarize my conversation with Alex",
    "check if mom texted", "has dad replied yet", "catch me up on the group chat", "whats new in my texts",
    "do i have any unread texts", "who messaged me today", "what was the last thing my wife sent me",
    "pull up my chat with Alex", "show my recent imessages", "what did Jordan send me yesterday", "latest text from dad",
    "read my messages from my boss", "go through my messages with Sam and tell me what we planned",
    "what were my dad's last few messages", "what's my mom been saying in our texts", "any texts from Jordan today?",
    "can you look at my messages from Sam", "see if Alex got back to me", "did my brother answer my text",
    "what did mom say in her last message", "get my latest messages", "find the message where Sam sent the address",
    "when did I last text Alex",
    "check what my sister texted me last", "what did Sam text me?", "did Mom message me today",
    "check my messages from Alex", "any new texts from Jordan?", "what did Sam say in our chat",
    "what did Sam say on iMessage", "show me the last text from Dad", "what didn’t she text me back about",
    "What did Sam text me last?", "last text from Alex", "has Jordan texted me?", "read my latest messages",
    "any new messages from Mom", "what was the last message Sam sent me", "did Alex reply", "check messages",
    "check my messages", "did Alex reply yet?", "has Mom texted back?", "what's the latest news Sam texted me",
    "who texted me last?", "what did my boss say in his last text", "summarize my texts from today",
    "show me the group chat", "did anyone text me", "what did she text me", "has Sam responded yet?",
    "what's in my latest messages", "any unread messages?", "read my last text from Jordan",
    "look through my messages with Alex for the address", "has my landlord texted me back",
    "what did my mom message me about dinner", "did Jordan get back to me", "what time did Sam text me",
    "get my texts from the group chat", "check if Alex has replied", "what were my last few texts",
    "catch me up on my messages from Sam", "did my wife text", "what's Alex been texting me about",
    "pull up my conversation with mom", "summarize the family group chat",
    "did the package arrive? check my messages", "did sam text", "what did i text alex",
    // Sending.
    "text my dad that I'll be late", "send a message to mom saying happy birthday", "send Alex a text saying I'm outside",
    "reply to Jordan with sounds good", "message the group chat that I'm on my way", "let mom know I landed via text",
    "shoot Sam a text that I'm here", "can you send my wife a message saying I'm on my way home",
    "imessage Jordan the address", "respond to my sister and say yes", "send a quick text to my boss that I'm sick today",
    "drop Alex a message saying thanks", "text Sam happy birthday", "message mom: running late", "send dad a message",
    "tell Sam over text that dinner is at 7",
    "text Alex that I'm running late", "send her a message saying hey", "send Sam a text saying hi",
    "message Sam that dinner is at 7", "reply to Mom with ok", "tell Jordan on iMessage I'm here",
    "iMessage Alex the address", "Text Alex that I’m running late", "please text Mom that I landed",
    "can you send Alex a message saying I'm late", "tell Sam by text that I'm here", "send a message to Alex saying hi",
    "text the group that I'm late", "text her I'm on my way", "message my sister saying happy birthday",
    "text Mom back that I'm fine", "text my boss I'm running ten minutes late", "send a text to Jordan saying thanks",
    "reply to my dad saying sounds good", "message Alex: see you at 8", "shoot my brother a quick text that I'm home",
    "please message the group chat that dinner moved to 7", "text my wife that I love her",
    "send Sam an imessage saying I'm outside", "respond to Alex with yes", "let Jordan know over text that I'm late",
    "ask mom by text if she needs anything", "can you text Alex the address", "i want you to text my dad happy birthday",
    "send an sms to Alex saying I'm late",
    // Review probes: replies, "sent me", counts, possessives, and "between me and …".
    "who texted me", "what did Sam text me", "what texts did I get today", "read my last 5 messages",
    "what's the last text I got from Sam", "show the texts between me and Alex",
    "when is dinner according to mom's text", "check whether Alex replied", "how many unread messages do I have",
    "answer Sam's text with yes", "respond to Alex's message saying ok",
  ]

  static let think = [
    "i want you to tell me about some data structures, take a while to think about your answer",
    "think about this carefully", "please think hard about this", "take your time and explain recursion",
    "really think it over before answering", "give this some serious thought", "think long and hard about the best approach",
    "reason through this step by step", "be thorough, what's the best way to learn rust", "don't rush, explain how tcp works",
    "think deeply about free will", "spend some time thinking about this", "use extended thinking", "think it through",
    "consider this carefully before answering", "carefully reason about whether p equals np",
    "take a moment to think before you answer", "think more about this", "double check your answer before replying",
    "work through this methodically", "think harder", "put some real thought into this", "take as long as you need",
    "go deep on this: how does a hash map work",
    "think hard about this", "think carefully: which plan is cheaper?", "think deeply about it",
    "take your time and compare them", "walk me through it step by step", "reason it through",
    "Think harder about this one", "please think it through carefully",
    "no rush, but which sorting algorithm is best for nearly sorted data", "think before you answer: is 91 prime?",
    "reflect carefully on the tradeoffs between sql and nosql", "ponder this deeply: what is consciousness",
    "explain monads thoroughly", "be thorough when you compare these two options",
    "go deeper on why the sky is blue", "think this one over: should I use a monorepo",
    "double-check the math before answering", "take a minute and think about the edge cases",
    "solve this step-by-step: 17 times 23", "please reason carefully about this proof",
    "consider this deeply before you respond", "give it some careful thought: tabs or spaces",
    "methodically list the failure modes of this design", "really think hard before you answer this riddle",
    "think it over and tell me which laptop to buy", "mull it over: is a hot dog a sandwich",
  ]

  static let search = [
    "What happened in the news today?", "Latest AI news", "What happened last night?", "What's new with Apple?",
    "What are the recent developments in fusion research?", "Who is the president of France?",
    "Who is the CEO of Apple?", "Weather in Copenhagen", "Will it rain tomorrow?", "What's Apple's stock price?",
    "What is the price of Bitcoin?", "USD EUR exchange rate", "Who won the match last night?",
    "What is the latest stable Swift release?", "What was announced at WWDC 2026?",
    "Search the web for the meaning of serendipity", "what's the latest AI news",
    "what's the latest message from the white house on tariffs", "what are the most recent developments in sms marketing",
    "what are the latest messages in the kafka topic", "what did the president say in his latest message to congress",
    "latest news about apple's imessage update", "what's the weather today",
    // Not Messages, but "explain" with "most recent" reads as a request for fresh facts.
    "explain the most recent text in the book",
    // Review probes: news about others' replies, and "call", "chat", "mail" and "dm" that aren't personal.
    "did Microsoft respond to the allegations today", "did Nvidia respond to the latest export rules",
    "did Ukraine respond to the peace plan this week", "what's the latest version of my messages app",
    "when is the next earnings call for my stock nvda", "what time is my team's call of duty match today",
    "what were the controversial calls in our game last night",
    "what's the latest on the call for proposals for my conference", "latest news about calls for my resignation",
    "what are the latest chats about my favorite show on reddit",
    "what time does my local post office mail pickup happen today",
    "latest dm news for my dungeon master group this week",
    // Ambiguous: Sam or Jordan could be anyone, so these still search. Typing /messages decides.
    "what's the latest from Sam", "summarize what Jordan sent yesterday",
  ]

  static let none = [
    // Messages near misses: noun compounds, other services, "send me …", how-to questions.
    "text classification with bert", "how do I send a message in slack", "what is message passing in mpi",
    "how do i reply to a recruiter", "how to text a girl", "what does the error message mean", "summarize this text",
    "send me a list of data structures", "tell me a joke",
    "what's the best way to message a landlord", "what message does the ending of inception send",
    "write my dad a text saying happy fathers day", "write a message to my landlord about rent",
    "what does this error message mean", "write a commit message for this diff", "what does this message mean",
    "explain how a message queue works", "send me a summary", "tell me about Denmark", "send an email to Alex",
    "write a text for my slide", #"what does "text Alex" mean"#, "`message Sam` is a command",
    "the error message says file not found", "what's the exit message from this script", "message me a joke", "text me a joke",
    "text me a summary", "draft a text to my boss asking for Friday off", "reply to this email politely",
    "explain this message broker", "what's on my screen", "what does “text Alex” mean", "translate this text to French",
    "check the log message", "text editor recommendations", "what is a text message", "send me the last text you wrote",
    "text wrapping in css", "text alignment in swiftui", "text generation models", "message passing in Erlang explained",
    "explain actors and message passing", "message brokers compared", "message types in protobuf",
    "message board software recommendations", "sms gateway providers", "SMS marketing best practices",
    "imessage not working on mac", "message types that protobuf supports", "text messages vs email for marketing",
    "fix my text with proper punctuation", "rewrite my text from above", "in your last message from earlier you said X",
    "what was the last message you sent me", "reply to reviewer 2 politely", "did you reply to my question",
    "check messages in the kafka queue", "check my email from my boss", "what did Sam say on slack",
    "send Alex a message on whatsapp", "text to speech apps for mac", "how do I read messages from kafka",
    "what's a good reply to a compliment", "what should I text my crush", "is it rude to text after 10pm",
    "how many messages can a kafka topic hold", "what is the text of the first amendment",
    "send us the details", "summarize the text above", "write a commit message", "explain message passing",
    "translate this text", "what does this text mean", "is this text grammatical", "make this text shorter",
    "what language is this text written in", "explain the message of the poem",
    "what's the reason he replied like that", "has anyone replied to my post", "who texted you",
    "did my professor reply to my email", "show me the messages from the server log", "read the text from the image",
    "what did my mom say on whatsapp", "find text in a file with grep",
    // No messaging word: these need a previous Messages request and a follow-up cue.
    "tell Sam I'm running late", "what did Sam say about dinner",
    // This chat.
    "what was my last message", "rewrite your last message", "summarize our conversation", "summarize this chat",
    "what did you say in your last message", "can you repeat your last reply", "what did I ask in my first message",
    "shorten your previous answer", "continue this conversation in French", "make my previous message clearer",
    "what have we talked about with you so far",
    // Drafting.
    "write a message to my landlord", "help me write a text to my boss asking for a raise",
    "draft a reply to my sister's message", "compose a message for my mom's birthday card",
    "write a text message I can send to my team", "rewrite my message to Alex so it sounds nicer",
    "come up with a funny text to send my brother", "proofread this text before I send it",
    // Think near misses.
    "what do you think about python", "i think the answer is 4", "how do people think", "think of a name for my dog",
    "what are you thinking", "do you think it will rain", "I think it's broken", "what do you think of this?",
    #"what does "think hard" mean"#, "`step by step` is a phrase", "I thought hard about it",
    "i'm thinking about buying a car", "i think more people should cook", "what do you think about rust vs go",
    "think of a word that rhymes with orange", "how long does it take to boil an egg", "does it take a while to learn piano",
    "i thoroughly enjoyed the movie, suggest a similar one", "what are some deep sea creatures",
    "i want to think more about my career, any tips?", "think tank funding sources", "how do I double check my tax return",
    "what's the reason for the season", "consider the lilies of the field meaning",
    "think long-term about investing", "i'll think it over", "let me think about it more",
    "the page takes a while to load, why", "think about whether it's over",
    // Ordinary questions.
    "explain photosynthesis", "what is a binary tree?", "hello", "thanks!", "what's 2 + 2", "write a poem about the sea",
    "how do I center a div", "who wrote pride and prejudice", "explain recursion", "what's the capital of Peru",
    "make it shorter", "translate this", "rewrite this",
    // Review probes: public figures' replies, pasted content, reviewing my own message, "my <thing>" that
    // isn't a person, titles and slang, advice, personal questions that shouldn't search, and think near misses.
    "has Apple responded to the EU ruling yet", "has Boeing replied to the FAA yet",
    "did Russia respond to the sanctions", "has Trump responded to the verdict",
    "has Israel replied to the ceasefire proposal", "did Sam Altman respond to the lawsuit",
    "did Drake respond to Kendrick", "has the White House responded", "has Meta responded to the fine",
    "did Netflix reply to the boycott", "did Google respond to my appeal",
    "find out if he replied to the thread on github", "did Kendrick reply to Drake's diss track",
    "did Taylor Swift reply to Kanye", "Sam sent me this article, summarize it",
    "my coworker sent me a pr to review, check it for bugs", "what does this mean? my dad sent me: ok",
    "check my grammar in my message to my boss", "read my message to my boss and tell me if it's too harsh",
    "read messages from my sqs queue in batches", "fetch messages from my firebase database",
    "get messages from my api", "read messages from my kafka consumer", "get all messages from my redis stream",
    "show messages from my backend", "list the messages from my mailbox server", "summarize the text from my notes",
    "summarize the text from my essay", "read me my texts from the book chapter",
    "what are my messages component props in react", "get my messages endpoint returning 500",
    "find my texts table schema", "summarize the book Text Me When You Get Home",
    "what's the meaning of the song text me back", "who sang send me a text", "what genre is the song message me",
    "who wrote the book texts from my ex", "what happened in the episode where Ross texted Rachel",
    "what does text me mean in slang", "what does message me mean", "text my ex or not?",
    "what are my chances if I text her", "latest messages from nasa to us about artemis today",
    "what did I get from mom today", "what emails came in today", "any news from my sister today",
    "what did mom say today", "deep thought from hitchhiker's guide", "what is deep thought",
    "some thought experiments about time travel", "I've given it some thought and I want to quit",
    "real thought leadership examples", "go deep sea fishing tips", "think more positively", "think more like a ceo",
    "how to think more clearly", "how to think critically", "the process can take a while, is that normal",
    "take a minute and read this email I wrote", "what does think it over mean", "mull over wine recipe",
  ]
}
