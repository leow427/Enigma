# Slash commands

Recognized commands stay blue in the composer and work at the start, middle, or
end of a message. `/search` applies only to the current message and stays visible
until acceptance. Deleting it cancels explicit search; subsequent messages follow
the automatic-search preference in Settings → Cloud & Search → Web Search · Brave.
Automatic search defaults to on and requires a saved Brave key. Capture commands
run when you submit.
`/think` applies only to the current answer, including File Mode requests.

| Command | Action |
| --- | --- |
| `/search` | Search the web for this message only |
| `/screen` | Capture all displays |
| `/snapshot` | Select a screen region |
| `/think` | Request more careful reasoning |

Type `/` anywhere after whitespace to see commands, icons, and descriptions.
`/search` is offered only with a saved Brave key, including in Help and the welcome
tour. Saving or removing a key updates suggestions immediately without editing
the draft. The automatic-search preference does not hide deliberate `/search`.
Suggestions filter by the text before the caret, case-insensitively. Use ↑/↓ to
select, Tab or Return to complete, or click a suggestion. Escape dismisses the
list before hiding the panel. Shift-Return inserts a newline. Completion edits
only the command at the caret and supports Undo.

The menu floats above the latest Enigma composer without moving its attachment,
model, or send controls. Search uses blue, Screen purple, Snapshot orange, and
Think pink; each menu icon and its command label share the same color. Draft
commands retain their blue highlighting. Compact and wide layouts use the
app’s existing text sizes, and history remains hidden at startup.

Commands must be separate tokens; punctuation may follow them. Quoted examples,
backtick code, URLs, paths, and unknown commands remain literal text. Repeated
commands activate once; `/snapshot` takes precedence over `/screen` if both occur.
Screen and Search remain incompatible with attached File Mode selections.

Submitting `/screen` or `/snapshot` alone attaches an image and waits for your
question. Both the full panel and compact selection bar show a thumbnail with
**Retake** and **Remove**. Retake repeats the capture type; Remove excludes the
image and extracted OCR from your next request. Cloud image consent previews
the capture and names its scope and selected provider. See
[Screen](Screen-Skill.md) for the saved permission and OCR distinction.

![Command suggestions with icons and a blue command in the draft](images/slash-commands.png)

The screenshot above is intentionally checked in as UI review documentation.
Build products and generated test renders remain outside the repository. The
rendering test also retains the screenshot as an XCTest attachment.

Verification uses `scripts/verify-xcode.sh build`, `test`, and `analyze`.
Regression coverage includes placement, boundaries, Unicode caret offsets,
completion, undo, keyboard navigation, multiline entry, capture cancellation,
focus restoration, and conversation scrolling.
