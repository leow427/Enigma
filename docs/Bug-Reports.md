# Bug reports

Enigma sends a short bug report straight from the app, anonymously unless you
add your email. If it can't send, the report can become an email in your mail
app instead.

## Where to find it

- **The chat window's top-right corner**: a small ladybug icon
  (`ReportBugButton`). Hovering it slides a "Report a bug" label out toward
  the chat, drawn over its neighbours so nothing moves. It's the last item in
  the top bar when the bar is shown (sidebar hidden, or What's new? waiting,
  just left of it). Beside the sidebar it floats in the same spot on an opaque
  backing, but only while the chat column leaves that corner free
  (`ReportBugButton.floatsClear(ofChatIn:)`: a main page at least 680 + 2 × 46
  pt wide); in a narrower window the top bar comes back to hold it, so it never
  covers a message or a code block's Copy button. It isn't in the compact
  selection panel or during the guided tour.
- **Help** (the sidebar's Help button): **Report a Bug…** at the bottom left.
- **Settings → About → Feedback**: **Report a Bug…**. Searching Settings for
  "bug" or "feedback" finds it.
- The **menu-bar menu**: **Report a Bug…**.

Each opens the form in its own window. Opening it again while it's open, or
minimized, brings the same window, with its draft, to the front.

## The form

- **What happened?** (required), **Steps to reproduce** and **Your email, if
  you'd like a reply** (both optional). In the first two, Return starts a new
  line.
- **Include logs**, off by default. Adds Enigma's event log (below): its
  newest whole lines, up to 32 KB, as text at the end of the report
  (`EnigmaLog.text(limit:)`), whether it's sent or emailed.
- **Include this conversation**, off by default, with the note "Never turn
  this on if the chat contains anything sensitive, such as passwords, personal
  or financial details, or private messages." directly under it. When it's on,
  a **Chat** menu picks which saved chat, the open one by default
  (`BugReport.chats(in:)` and `defaultChatID(in:)`). Only the
  chat's visible text is sent, as `You:` and `Enigma:` lines: no attachments,
  screenshots, file contents, selected text or Messages data, unless they're
  already in that text. Temporary chats are never saved, so they're never
  offered; with no saved chats the switch is off and disabled.
- **What will be sent** opens the report's whole text, with where it goes, the
  reply address if you gave one, and the subject, before you send it.
- **Send Report** sends it ("Sending…" while it goes). **Cancel** (or Esc)
  meanwhile stops a report still on its way; one that already reached
  Formspree still arrives. On success the form says so and won't send the same
  report twice; **Close** closes it. If sending fails (offline, a timeout, or
  Formspree refusing it, as past its monthly cap), the form says so, **Send
  Report** can try again, and **Email Instead** opens the same text as an
  email in your mail app (below). The form stays open with its draft either
  way, and VoiceOver reads each of these notices.

Diagnostics are added automatically: Enigma's version, the macOS version, the
chip and memory, the route and model of the last request this launch, and the
local and cloud models chosen. They never include chat content.

## Sending

`BugReportSender` posts the report as JSON to the form at the
`EnigmaBugReportURL` key in `Enigma/Resources/Info.plist`
(`https://formspree.io/f/mjyyanzn`, HTTPS only), and Formspree emails it to
the bug report address. The form's address isn't a secret: it's what any
website's contact form shows. The request carries:

- `_subject`: "Enigma bug report".
- `message`: the report's text, exactly as previewed.
- `email`: only when **Your email** looks like an address
  (`BugReport.replyTo`). Formspree makes it the reply-to, so a reply goes
  straight to the reporter. Anything else typed there stays in the text only.

There's no name, account or device ID. It goes through an ephemeral
`URLSession` (no cookies or cache kept), with a 20 s timeout. Like any web
request, Formspree sees the connection's IP address, and the system's
User-Agent and language headers (Enigma's build and the macOS version, already
in the diagnostics). Enigma's own log records
only that a report was sent or failed, never its text.

Formspree's free plan takes about 50 reports a month; past that, sending fails
and the form offers the email.

## Email instead

**Email Instead** shows when sending fails (or if `EnigmaBugReportURL` is
missing). The email carries the previewed text, logs included as text; it's
sent from the user's own address, so it isn't anonymous. When Mail is the
default mail app, `BugReportMailer` uses
`NSSharingService(named: .composeEmail)`, which opens a new email with the
recipient, subject ("Enigma bug report") and body. With any other default
(such as a browser for web mail), or if Mail can't take the email, it opens a
`mailto:` link instead, so the email opens where the user reads mail. The form
then stops floating so the email can come in front of it. If nothing opens, the
form says so and gives the address.

The email address is the `EnigmaBugReportEmail` key in `Enigma/Resources/Info.plist`
(`enigmabugreporting@gmail.com`), and nowhere else.

## The event log

`EnigmaLog` (`Enigma/App/EnigmaLog.swift`) records what Enigma did, never what
anyone wrote: launches with the version, each request's route and model
(`Request started: Cloud · OpenAI · …`, and `Request moved to: Local · …` when
a request changes route, such as an offline screen request answered on this
Mac), that a request failed (not why: a
failure's text can quote a provider), model install, delete or switch
failures, and the errors that used to go to `NSLog` (shortcut registration,
moving into Applications, the memory bandwidth test), as their error domain
and code only. Never chat text, model output, prompts, queries, URLs, file
paths or an error's description.

Each event goes to the unified log (subsystem Enigma's bundle id, category
`events`) and to `~/Library/Logs/Enigma/Enigma.log`. `OSLogStore` reads only
the current launch, so the file keeps earlier ones: past 256 KB it becomes
`Enigma.previous.log`, replacing the one before, so the two never pass about
512 KB. The test host writes no file.

## Tests

`BugReportTests` covers the recipient and endpoint keys (HTTPS only), the
required field, that the request is anonymous unless a reply address is given
(and that only a real-looking address becomes one), that only a 2xx counts as
sent, that the logs go in as text only when asked, the email body
with and without each option (no chat text, attachment names or selected text
unless asked), `mailto:` encoding, that only Mail gets the sharing service, that a temporary chat is never offered or
chosen, and that a failed request logs its route but never its prompt, reply or
failure text;
`LocalInferenceTests.testRequestLogsTheModelItSettlesOn` checks a request that
settles its model on the way; `testScreenshots` renders the form when
`ENIGMA_SNAPSHOT_DIR` is set. `EnigmaLogTests` covers the file's lines,
rolling over, the no-file mode, and the newest-whole-lines text a sent report
carries. `EnigmaTextFieldMultilineTests` checks that
Return inserts a new line in a multi-line field. `AppCommandTests` checks the menu-bar
command list. `EnigmaMainWindowTests.testReportABugSitsInTheCornerClearOfTheChat`
checks the ladybug's corner, floating clear of the chat in a wide window and in
the bar in a narrow one, that it opens the form, and that the tour hides it;
`testWhatsNewSitsTopRight…` checks What's new? sits just left of it;
`BugReportTests.testScreenshots` also renders the corner, hover label included.
`BugReportTests.testFailedSendOffersEmailAndASentReportCantBeSentTwice`
presses Send Report in the real form against a fake connection: a failure
shows Email Instead and leaves Send Report on for a retry; a success turns it
off and shows no Email Instead.

## Limits

- A very long conversation can make a `mailto:` link longer than some mail
  apps accept. The sharing-service path, used with Mail, has no such limit.
- The form writes nothing to disk; the log file is the only thing Enigma
  writes for bug reports.
- A report goes through Formspree, a third party, which may keep submissions in
  its dashboard as well as emailing them.
