import Foundation

/// The commands a draft will run with: the ones typed in it, plus the ones
/// recognized from its wording. The composer's chips and Send both resolve
/// the same context with this, so they can't disagree.
///
/// Only the typed draft can infer a command. Selection text, files,
/// screenshots, earlier messages, and tool results are never inspected.
struct ComposerIntent: Equatable, Sendable {
  struct Context: Equatable, Sendable {
    var draft: String
    /// Selection Context is attached, so `edit` and `translate` can be inferred.
    var hasSelection = false
    var hasFileSelection = false
    var hasScreenshot = false
    /// The previous accepted request in this chat used Messages.
    var previousTurnUsedMessages = false
    /// `composer.inferCommands`: controls `messages`, `think`, `edit`, and `translate`.
    var infersCommands = true
    /// Automatic search is on and a search key is saved.
    var searchesAutomatically = false
    /// Inferences the person turned off for this draft.
    var dismissed: Set<SlashCommand> = []
  }

  /// The user default behind "Recognize commands from your wording".
  static let inferCommandsKey = "composer.inferCommands"
  /// Off until the person turns it on, so a new user's wording never turns on a command by surprise.
  static let infersCommandsByDefault = false

  /// The order chips appear in.
  static let chipOrder: [SlashCommand] = [.messages, .search, .think, .edit, .translate]

  /// The draft as typed.
  let draft: String
  let typed: ComposerCommands
  /// The inferred commands that will apply, in chip order.
  let inferred: [SlashCommand]
  // Effective flags: typed or inferred.
  let messages: Bool
  let search: Bool
  let think: Bool
  let edit: Bool
  let translate: Bool

  var hasPrompt: Bool { !typed.prompt.isEmpty || edit || translate }
  var submissionPrompt: String {
    (think ? "/think " : "") + (translate ? "/translate " : edit ? "/edit " : "") + typed.prompt
  }
  /// The draft as typed, with inferred `think`, `edit` and `translate` written in front, for
  /// paths such as File Mode that send the draft as typed.
  var draftWithInferredCommands: String {
    let prefix = (inferred.contains(.think) ? "/think " : "")
      + (inferred.contains(.translate) ? "/translate " : inferred.contains(.edit) ? "/edit " : "")
    return prefix + draft
  }

  static func resolve(_ context: Context, now: Date = Date()) -> ComposerIntent {
    let typed = ComposerCommands(context.draft)
    var candidates: Set<SlashCommand> = []
    // Normalize once; every matcher reads the same literal-free, lowercased text.
    let text = WebSearchPolicy.questionText(typed.prompt)
    // Screen and Snapshot are never inferred, and a capture never picks up other inferences.
    if !typed.screen {
      if context.infersCommands {
        if !typed.messages, MessagesIntentPolicy.isRequested(normalized: text)
            || (context.previousTurnUsedMessages && MessagesIntentPolicy.isFollowUpCue(normalized: text)) {
          candidates.insert(.messages)
        }
        if !typed.think, ThinkCommand.isRequested(normalized: text) { candidates.insert(.think) }
        if context.hasSelection, let command = SelectionIntentPolicy.command(normalized: text) {
          candidates.insert(command)
        }
      }
    }
    candidates.subtract(context.dismissed)

    // Drop conflicting inferences, never typed commands.
    if context.hasFileSelection || context.hasScreenshot || typed.search || typed.screen {
      candidates.remove(.messages)
    }
    // Translation stays read-only, and a typed command keeps its meaning.
    if typed.translate || typed.edit || candidates.contains(.translate) { candidates.remove(.edit) }
    if typed.translate || typed.edit { candidates.remove(.translate) }

    // Message contents must never become a web search query, and files can't be combined
    // with search. The search check is skipped when its chip couldn't apply.
    if context.searchesAutomatically, !typed.screen, !typed.search, !typed.messages,
       !candidates.contains(.messages), !context.hasFileSelection, !context.dismissed.contains(.search),
       WebSearchPolicy.needsFreshInformation(normalized: text, now: now) {
      candidates.insert(.search)
    }

    let translate = typed.translate || candidates.contains(.translate)
    return ComposerIntent(
      draft: context.draft,
      typed: typed,
      inferred: chipOrder.filter(candidates.contains),
      messages: typed.messages || candidates.contains(.messages),
      search: typed.search || candidates.contains(.search),
      think: typed.think || candidates.contains(.think),
      edit: (typed.edit || candidates.contains(.edit)) && !translate,
      translate: translate)
  }
}
