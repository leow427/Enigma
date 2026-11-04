# Save answers as files (F39) — design

Status: draft design for the owner to review, not yet implemented. Date: 2026-11-04.

## Goal and users

Today a file reaches the Mac only through File Mode, which first needs an
attached file or folder. Someone who asks a coding question and then says
"make this python script into a file", or asks "write me a python file that
picks two random numbers" or "write me an essay about how awesome cats are",
gets the text in the chat and has to copy it into an editor and save it
themselves.

F39 lets Enigma save an answer as a file, with no attach step, two ways:

- **Save buttons** on code blocks and on whole replies, for every model.
- **A `save_file` tool** for the capable models that already choose their
  own tools (F32), so asking for a file in words is enough.

Files go into Enigma's own folder, `~/Documents/Enigma`, or into a folder you
attached to the chat. Saving never overwrites your files, and every save can
be undone.

**What the owner asked for (2026-11-04):**

- No attach step: "make this python script into a file", "write me a python
  file that calculates 2 random numbers" and "write me an essay about how
  awesome cats are" should just work.
- Both Save buttons and a tool the model calls itself. No chips: native tool
  calling decides when to save.
- The tool saves inside Enigma's folder; the model picks the name and may use
  a subfolder. It saves without asking first, then shows a card.
- File types: code and other text formats, RTF, Word and PDF. Coding file
  types must be well supported.
- A type Enigma doesn't recognize saves as Markdown.
- The reply's Save button offers a small menu of types.
- If you brought in a folder (with **+**, or by dragging once F4 lands), files
  go there, and Enigma doesn't ask for permission unless it has to.

**Success means:**

- After a coding answer, "save that as a file" (capable model) or the code
  block's Save button (any model) puts the script in the right folder with a
  sensible name and extension, and a card offers **Open**, **Show in Finder**
  and **Undo**.
- "Write me an essay about cats as a Word document" produces a `.docx` that
  opens in Pages and Word with its headings, lists and emphasis.
- With a project folder attached, a new `.py` file is created there without a
  **Use Codex** prompt or a macOS prompt.
- No existing file is ever overwritten, except Enigma's own earlier save in the
  same chat that nobody has changed since.
- Small models behave as today, plus the buttons.

## Decisions

1. **Buttons for every model, the tool for capable models only.** The tool is
   a new part of F32's `AssistantToolbox`, offered on every flagged turn the
   way Messages is. Small models get no new recognizer or chip (F32 keeps
   their rules as they are; F27's concerns about small models and tools don't
   arise because they get no tool).
   - Rejected: a `save` chip from the wording. Native tool calling replaced
     chips for capable models (owner).
2. **Enigma writes the file, not the model.** The tool takes a name and the
   content; Swift picks the folder, the type, the final name, and does the
   write. The model gets no listing, reading, editing or deleting outside File
   Mode.
3. **Reuse File Mode's `WorkspaceService`** for every save: verified
   descriptors and `O_NOFOLLOW`, atomic writes, the recovery journal,
   outside-change conflicts, Undo after restart and the Saved file changes
   list. The save folder is opened as a one-folder `WorkspaceSelection`.
   - Rejected: a separate writer that moves files to the Trash on Undo. It
     would repeat the link, escape and conflict checks, and saves wouldn't be
     in Saved file changes.
   - Rejected: auto-attaching the save folder to File Mode. The model would
     get list, read, edit and delete there; `.py` would hit the protected-edit
     Codex prompt; and attaching files turns off the other native tools.
4. **The destination is the chat's latest Read & Edit folder, else Enigma's
   folder**, for the buttons and the tool alike (§2).
5. **No ask in Enigma's folder.** Inside an attached project folder,
   `save_file` asks only for a path that is protected even as a new file
   (§3.3). Buttons never ask; the click is the request.
6. **Unknown types become Markdown.** In Enigma's folder, any type not on the
   recognized lists saves as `.md` (owner). In an attached folder, any text
   type is kept as written, because projects use many text formats macOS
   doesn't know (`.gleam`, `.prisma`); only types Enigma can't make, and
   launchers, become `.md` there (§4). This keeps today's File Mode
   `create_file` behaviour for project files.
7. **Word, PDF and RTF are made with Apple's frameworks**, from the same
   parsed Markdown the chat shows. No new dependency.
8. **Session-only cards.** The saved-file card isn't saved with the chat, like
   the weather card; a reopened chat shows the reply text only. The save
   itself stays in **Saved file changes** in Settings.

## Design

### 1. Enigma's save folder

- **Default:** `~/Documents/Enigma`, created on the first save that needs it.
  Nothing is created before then.
- **macOS permission:** Enigma isn't sandboxed, but Documents is protected, so
  the first save there shows macOS's one-time prompt. Add
  `NSDocumentsFolderUsageDescription` to `Info.plist`:
  "Enigma saves the files you ask for in Documents › Enigma."
- **If access is denied** (or the folder can't be created), the save fails
  with a card: "Enigma can't save to Documents › Enigma." and the detail
  "Choose another folder, or allow Enigma in System Settings › Privacy &
  Security › Files and Folders." with a **Choose Folder…** button. It opens an
  `NSOpenPanel` (folders only, **New Folder** allowed, prompt "Use This
  Folder"); choosing one saves it as the save folder and retries the save. A
  tool save that fails this way returns the same reason to the model.
- **Settings → Files** (`FilesSettingsPage`) gets a **Save folder** row: the
  folder's path, shortened with `~`, and **Change…** (the same panel). When a
  custom folder is set, a **Use Default** button returns to
  `~/Documents/Enigma`. A custom folder is stored as a security-scoped
  bookmark in `UserDefaults` (key `saveFolder.bookmark`); the default needs no
  bookmark. A bookmark that no longer resolves to the same path falls back to
  the default, and the row says "The chosen folder is missing. Files go to
  Documents › Enigma."
- Page subtitle becomes "Attach files and folders, and save files from a
  chat."

### 2. Where a save goes

One rule, `SaveDestination.resolve(for reply:in session:)`, used by both
buttons and the tool:

1. Walk back from the reply to the most recent user message in this chat that
   carries **save folders** (below), including the reply's own request.
2. Use its first folder whose bookmark still resolves to the same path
   (`WorkspaceAttachment.resolve()`).
3. Otherwise use Enigma's save folder (§1).

**Save folders:** when a request is sent with attachments and access
**Read & Edit**, its user message stores the attached **folders** (not files)
as `ChatMessage.saveFolders: [WorkspaceAttachment]?`, a new saved coding key.
Chats already save draft bookmarks in `ChatSession.workspace`; this keeps a
sent request's folders after `consumeSelection` clears the draft. A chat held
in memory (no messages yet, or temporary) writes nothing, as today. Deleting
the chat deletes them.

Enigma uses its own folder instead of asking, whenever asking would be the
only way to write elsewhere:

| Case | Where it goes | Card detail |
| --- | --- | --- |
| A Read & Edit folder is attached (now or earlier in the chat) | That folder | "In MyProject" |
| Only files were attached (a file's grant doesn't cover its folder) | Enigma's folder | "In Documents › Enigma" |
| The folder was attached Read Only | Enigma's folder | "In Documents › Enigma" |
| The folder was moved, renamed or deleted | Enigma's folder | "MyProject isn't available, so it was saved in Documents › Enigma." |

An attached folder already carries its picker grant, so saving there never
shows a macOS prompt. Drag and drop (F4) attaches through the same path, so
F39 needs nothing extra for it.

**During a File Mode turn** (files attached to that message), the model works
through File Mode's own tools, so `save_file` isn't offered (the plan is empty
on those turns, as today). §3.3 covers what changes in File Mode.

### 3. Saving

#### 3.1 `SaveService`

A small `@MainActor` service in `Enigma/Files/SaveService.swift`:

```swift
func save(name: String, content: SaveContent, folder: String?,
          destination: SaveDestination, conversationID: UUID) async throws -> SavedFile
```

- `SaveContent` is `.text(String)` (written as given, or converted for
  `.docx`, `.pdf`, `.rtf`) or `.markdown(String)` (a reply's Markdown).
- It picks the type (§4), cleans the name (§5), picks a free name, opens a
  `WorkspaceService` on the destination folder with access Read & Edit and a
  new write policy case `.approved` that never asks (the service has already
  decided), and applies one mutation.
- `folder` is optional and one level deep. File Mode today needs an existing
  parent folder, so `saveData` (below) may create that one missing subfolder
  inside the destination, through `WorkspaceAccess`'s verified descriptors
  (mode `0o700`), and Undo removes it again if it is then empty. A deeper
  path, a hidden name, or a name that is an existing file is refused with
  "Enigma can save into one new folder at most."
- It returns `SavedFile(name:, folderName:, url:, changeSetID:, note:)`, where
  `note` is the Markdown-fallback or unavailable-folder line.
- The change set is tagged with the chat's `conversationID`, so it shows in
  the chat's **Earlier changes** and in **Saved file changes**, and Undo uses
  `FileModeCoordinator.undo`.

**New mutation.** `WorkspaceMutation.saveData(path:data:replacingSaved:)`
writes ready-made bytes (needed for `.docx` and `.pdf`). Host code only: no
`AgentFileTools` tool maps to it. It creates the file with
`createdBySpotlight: true` and mode `0o600` like `.create` (so scripts are
never executable), or, when `replacingSaved` is true, replaces a file only if
its current bytes match the `after` state of a change this chat saved
(matching `conversationID` and absolute path). Anything else is
`FileModeError.alreadyExists`, and the service picks the next free name.

**Never overwrite.** If the name is taken and the replacement rule doesn't
apply, the file is saved as `name 2.ext`, `name 3.ext`, … up to `name 99.ext`,
then fails with "There are too many files named ‹name›."

**Replacing Enigma's own file.** Saving the same name to the same destination
again in the same chat replaces Enigma's earlier save there, if nobody has
changed it since. This makes "now make it add three numbers" update
`random_numbers.py` instead of making `random_numbers 2.py`. Undo restores the
earlier version. The tool description says so; the buttons always make a new
file (a click on an old reply shouldn't replace a newer save).

#### 3.2 The `save_file` tool

A new tool part, `SaveTools` (`Enigma/Files/SaveTools.swift`, an
`AgentToolbox`), added as `NativeToolPart.saving`. `NativeToolPlan.make`
inserts it on every plan it builds, after `.messages` (so turns with files or
a screenshot, which return `.empty`, don't get it).

| | |
| --- | --- |
| Name | `save_file` |
| Description | "Save a new file on the user's Mac, only when they ask for a file (for example \"make this a file\", \"write me a python file that…\", \"save it as a Word document\"). Use the name they asked for, or a short descriptive one, with the right extension. For a Word document use .docx and for a PDF use .pdf, and write content as Markdown. Every other type is saved exactly as written. Saving the same name again in this chat replaces your earlier file. Never call it unless the user asked for a file." |
| `name` (required) | "The file name with its extension, such as random_numbers.py or Cats.docx. No folders." |
| `content` (required) | "The whole file." |
| `folder` (optional) | "A subfolder to save in, one level deep. It is created if needed." |
| Phase | a new `AssistantActivity.Phase.savingFile`, shown as "Saving file…" |
| Instructions | none beyond the description |

- It runs `SaveService.save` with `replacingSaved: true` and
  `SaveDestination.resolve` for the reply being written.
- **Result text** (what the model reads; `success` as noted):
  - "Saved random_numbers.py in Documents › Enigma." (success)
  - "Saved as Budget.md in Documents › Enigma: Enigma can't make .xlsx files.
    Tell the user it was saved as Markdown." (success)
  - "The user didn't allow creating .github/workflows/ci.yml in MyProject."
    (failure)
  - The error's message for every other failure (failure).
- Each successful save adds a saved-file card to the reply (§6).
- The tool returns names and folders only; it never reads a file.

#### 3.3 Protected new files, and File Mode

`WorkspaceWriteClassifier` gains `classifyNewFile(path:) -> WorkspaceWriteClass`:
a new file is **protected** only when its path has a hidden component (`.github`,
`.envrc`), an agent instruction name (`sensitiveNames`), a secret-like name
(`secret`, `credential`, `password`, `private-key`, `private_key`), or a
config stem or folder (today's `config`, `configuration`, `settings`,
`manifest`, `package`, `project`, `database` rule). Everything else is safe,
whatever its extension or content, because nothing existing changes and Undo
removes it. The allowed dotfiles in §4 are still hidden components, so they
are protected in a project folder.

- **`save_file` in an attached folder:** a protected new file asks first on a
  `SaveApprovalCard` in the reply, styled like `MessagesSendApprovalCard`:
  title "Create ci.yml in MyProject?", the relative path as detail, buttons
  **Don't Create** (cancel, Escape) and **Create** (accent). Stop counts as
  Don't Create. In Enigma's folder it never asks.
- **File Mode's `create_file`** (Local and Auto): `WorkspaceService.apply`
  classifies a path that a `.create` or `.saveData` mutation creates with
  `classifyNewFile` instead of `classify`, so a new source file no longer
  raises the **Use Codex** prompt. Every other path keeps today's `classify`
  exactly, including a move's destination (it is new, but its content isn't),
  edits, appends, patches and deletes. Cloud through Codex skips the check, as
  today.
- **`create_file` file types:** `WorkspaceDocument.create` makes `.docx` and
  `.pdf` from Markdown (§4), and a type Enigma can't make, or a launcher,
  becomes `.md` (the attached-folder column of §4). The tool receipt names
  the path actually written. The read-back check after a create compares the
  written bytes' hash for `.docx` and `.pdf` instead of reading text. The
  `create_file` description becomes "Create a new file in an existing
  directory; never overwrite a file. Write .docx and .pdf content as Markdown;
  other types are saved exactly as written."
- `.rtf` keeps today's behaviour in both places: the content is plain text in
  a rich-text document.

### 4. File types

`SaveFileType.resolve(name:, in: .enigmaFolder | .attachedFolder)` returns
`.text`, `.docx`, `.pdf`, `.rtf` or `.markdownFallback(reason:)`.

| Type | Enigma's folder | Attached folder |
| --- | --- | --- |
| `.docx`, `.pdf` | Made from Markdown | Made from Markdown |
| `.rtf` | Plain text in RTF (`WorkspaceDocument.create`) | Same |
| Recognized text and code (below) | As written, UTF-8 | As written, UTF-8 |
| Other text extensions | `.md` | As written, UTF-8 |
| Formats Enigma can't make (below) | `.md` | `.md` |
| Launchers (below) | `.md` | `.md` |
| No extension, not a known name | `.md` | `.md` |

**Recognized text and code** is either:

- an extension whose `UTType` conforms to `.sourceCode`, `.script`,
  `.plainText`, `.json`, `.xml`, `.yaml`, `.commaSeparatedText`,
  `.tabSeparatedText` or `.html`; or
- one of a fixed list for types macOS doesn't know, kept in
  `SaveFileType.extraTextExtensions`: `ts`, `tsx`, `jsx`, `mjs`, `cjs`, `vue`,
  `svelte`, `astro`, `kt`, `kts`, `dart`, `scala`, `sc`, `gradle`, `groovy`,
  `toml`, `ini`, `cfg`, `conf`, `env`, `properties`, `lock`, `prisma`,
  `graphql`, `gql`, `proto`, `tf`, `tfvars`, `hcl`, `nix`, `zig`, `nim`,
  `jl`, `ex`, `exs`, `erl`, `hrl`, `clj`, `cljs`, `edn`, `elm`, `fs`, `fsx`,
  `ml`, `mli`, `hs`, `rkt`, `lisp`, `el`, `vim`, `ps1`, `psm1`, `bat`, `cmd`,
  `fish`, `zsh`, `bash`, `sql`, `scss`, `sass`, `less`, `styl`, `md`,
  `markdown`, `mdx`, `rst`, `adoc`, `tex`, `bib`, `ipynb`, `sol`, `v`, `sv`,
  `vhd`, `asm`, `s`, `wat`, `cu`, `metal`, `glsl`, `hlsl`, `wgsl`, `cmake`,
  `mk`, `d`, `cr`, `pas`, `f90`, `cob`, `ada`, `pl`, `pm`, `r`, `rmd`,
  `log`, `diff`, `patch`, `srt`, `vtt`, `ics`, `vcf`, `svg`, `plist`; or
- one of these extensionless names: `Dockerfile`, `Containerfile`,
  `Makefile`, `GNUmakefile`, `Gemfile`, `Rakefile`, `Podfile`, `Brewfile`,
  `Procfile`, `Justfile`, `Vagrantfile`, `Jenkinsfile`, `LICENSE`, `README`,
  `CODEOWNERS`; or these dotfiles: `.gitignore`, `.gitattributes`,
  `.editorconfig`, `.dockerignore`, `.prettierrc`, `.eslintrc`, `.npmrc`,
  `.nvmrc`, `.env.example`.

A test checks that a sample of common code extensions resolves to `.text`
(`py`, `js`, `swift`, `c`, `h`, `cpp`, `hpp`, `m`, `mm`, `java`, `go`, `rs`,
`rb`, `php`, `cs`, `sh`, `lua`, `pl`, `css`, `html`, `json`, `yml`, `xml`,
`csv`, `txt`) on the CI image, so a missing `UTType` shows up there.

**Formats Enigma can't make:** `xlsx`, `xls`, `numbers`, `pptx`, `ppt`, `key`,
`pages`, `doc`, `odt`, `ods`, `odp`, `epub`, `png`, `jpg`, `jpeg`, `gif`,
`heic`, `webp`, `mp3`, `wav`, `m4a`, `mp4`, `mov`, `zip`, `tar`, `gz`, `dmg`,
and anything else whose `UTType` conforms to `.image`, `.audiovisualContent`,
`.archive` or `.executable`. Reason text: "Enigma can't make .xlsx files."

**Launchers** (they run or open something when double-clicked) become `.md`
in both columns: `command`, `tool`, `terminal`, `app`, `pkg`, `mpkg`,
`workflow`, `scpt`, `applescript`, `webloc`, `inetloc`, `fileloc`, `url`,
`desktop`. Reason text: "Enigma doesn't save .command files, because they can
run when opened." Together with mode `0o600`, this stops a model that read an
injected web page from leaving a double-click launcher.

**Order:** launchers first, then `.docx`/`.pdf`/`.rtf`, then recognized text
(so `svg`, which `UTType` calls an image, is text), then formats Enigma can't
make, then the column's rule for other extensions.

**Markdown fallback content:** prose is saved as given. Content saved from a
code block, or tool content whose requested type was a text extension that
fell back, is wrapped in a fenced block tagged with the block's language or
the requested extension (```` ```gleam ````), so it reads correctly as
Markdown. Content for a format Enigma can't make, or a launcher, is saved as
given.

**Word, PDF from Markdown** (`SaveDocumentRenderer`, `Enigma/Files/SaveDocumentRenderer.swift`):

- Parse with `ChatMarkdown.blocks` and build the attributed string with
  `ChatCopy.richText` (F1's colour-free rich text: fonts, headings, lists,
  quotes, code and tables as tab stops).
- `.docx`: `NSAttributedString.data(from:documentAttributes:)` with
  `.documentType: .officeOpenXML`.
- `.pdf`: lay out the same string in pages with `NSLayoutManager` and
  `NSTextContainer` on `NSPrintInfo.shared.paperSize` (A4 or Letter from the
  Mac's settings) with 72 pt margins, drawn into a PDF `CGContext`.
- A conversion failure throws "Enigma couldn't make this Word document." or
  "…PDF." and nothing is written.

### 5. Names

**Cleaning** (every source): take the last path component only; replace `/`
and `:` with `-`; drop control characters; trim spaces and dots from both
ends, except a leading dot on an allowed dotfile; at most 100 characters,
cut at a word boundary before the extension; empty becomes `untitled`.

**Code block Save:** the extension comes from the language tag through
`SaveFileType.extension(forLanguage:)`, a fixed map that covers the same
languages as `CodeLanguage` and more (`python`/`py`→`py`, `javascript`/`js`→`js`,
`typescript`/`ts`→`ts`, `tsx`, `jsx`, `swift`, `kotlin`→`kt`, `java`, `go`,
`rust`→`rs`, `c`, `cpp`/`c++`→`cpp`, `csharp`/`c#`→`cs`, `objective-c`/`objc`→`m`,
`ruby`→`rb`, `php`, `dart`, `scala`, `lua`, `r`, `julia`→`jl`, `perl`→`pl`,
`haskell`→`hs`, `elixir`→`ex`, `sql`, `bash`/`sh`/`zsh`/`shell`→`sh`, `fish`,
`powershell`/`ps1`→`ps1`, `bat`, `html`, `css`, `scss`, `vue`, `svelte`,
`json`, `yaml`/`yml`→`yml`, `toml`, `xml`, `graphql`, `proto`, `terraform`/`hcl`→`tf`,
`markdown`/`md`→`md`, `latex`/`tex`→`tex`, `csv`, `text`/`plaintext`/`txt`→`txt`,
`diff`; `dockerfile` and `makefile` name the file `Dockerfile` or `Makefile`).
`console` blocks save as `.txt`. No tag, or a tag not in the map, means a
Markdown fallback (§4). The name comes from, in order:

1. a file name on the block's first line in a comment (`# calc.py`,
   `// main.swift`, `<!-- index.html -->`, `-- query.sql`);
2. a file name in the last line of the text just above the block, in
   backticks or bold (`` `calc.py` ``, `**calc.py**`);
3. `untitled.<ext>` (or `Dockerfile`/`Makefile`).

A found name with a recognized extension wins over the tag's extension; one
with an unrecognized extension keeps its stem and takes the tag's.

**Reply Save:** the reply's first heading, else its first line, with Markdown
marks removed, cut to about 40 characters at a word boundary; else
`Enigma reply`. The extension comes from the menu choice.

**Tool:** the model's `name`, cleaned.

### 6. Buttons and cards

**Code blocks** (`ChatMarkdownView`): a **Save** icon button
(`square.and.arrow.down`) just left of **Copy code**, same size and resting
style as `ChatCopyButton`, VoiceOver label "Save code". It saves at once
(§3.1, `replacingSaved: false`) and briefly shows a check mark, like Copy.
Hidden while the reply is still streaming.

**Replies** (`EnigmaMessageList`, the meta line): a **Save** icon beside
**Copy reply**, VoiceOver label "Save reply", shown when Copy reply is. It
opens an `EnigmaMenu` with **Word Document** (`.docx`), **PDF** (`.pdf`),
**Markdown** (`.md`, the reply's Markdown as written) and **Plain Text**
(`.txt`, `ChatCopy.plainText`).

**Saved-file card** (`SavedFileCard`, `Enigma/Files/SaveCards.swift`), one per
saved file, under the reply that saved it (button or tool), session-only like
`weatherCards`:

- Title: "Saved random_numbers.py" with the `doc` symbol, via
  `EnigmaCardTitle`.
- Detail: "In Documents › Enigma", "In MyProject", "In MyProject › scripts",
  plus the fallback or unavailable-folder line from §2 and §4 on its own line.
- Buttons: **Open** (`NSWorkspace.open`), **Show in Finder**
  (`activateFileViewerSelecting`), **Undo**. After Undo the title reads
  "Removed random_numbers.py" (or "Restored the earlier
  random_numbers.py" for a replacement) and the buttons go. An Undo conflict
  shows File Mode's existing conflict message on the card.
- Errors (§7) use the same card with the error as detail and, where it
  applies, **Choose Folder…**.

Controls come from `EnigmaControls.swift`; colours and type follow
`docs/design/UI-Style.md`.

### 7. Failure handling

| Failure | What happens |
| --- | --- |
| Documents access denied, or the folder can't be created | Card with **Choose Folder…** (§1); the tool gets the same reason |
| Chosen save folder missing | Falls back to the default (§1) |
| Attached folder unavailable | Enigma's folder, with the note (§2) |
| Name taken | Next free name, or replacement (§3.1) |
| Over 2 MiB (`WorkspaceAccess.fileLimit`) | "This file is too large to save (over 2 MB)." |
| Disk full, other write errors | The error's message; atomic writes leave nothing half-written |
| Conversion fails | §4 message; nothing written |
| Protected new file declined | Tool gets "The user didn't allow …"; nothing written |
| Stop during a save | The write either finished (card shown, Undo available) or never started |

### 8. Privacy

- Saving writes only the answer's own text, on this Mac. Nothing is sent
  anywhere, and no file is read.
- The model can only create files in the destination, never list, read,
  overwrite (except §3.1's replacement), move or delete.
- Recovery copies of each save go into File Changes as for File Mode edits,
  and are listed in **Saved file changes**.
- Logs name the tool (`Native tool call: save_file`) as today, never the name,
  folder or content.
- Save folders are stored with the chat as bookmarks, like the draft's
  attachments today; they never reach a model. Only folder names appear in
  tool results and cards.

## Testing

- **`SaveFileTypeTests`** (new, pure): every row of the §4 table for both
  columns; the code extension sample; launchers; extensionless names and
  dotfiles; the language map, including `dockerfile`, `makefile`, `console`
  and an unknown tag.
- **`SaveNamingTests`** (new, pure): cleaning, the three code-name sources in
  order, reply names, free names up to 99.
- **`SaveServiceTests`** (new, temporary folders, fake bookmarks): default
  folder creation; denied access; never overwriting; replacement only for
  this chat's unchanged save (changed by hand → new name; another chat → new
  name); one-level subfolders and refused deeper ones; 2 MiB; Undo removes a
  new file and restores a replaced one, after recreating the service (restart).
- **`SaveDocumentRendererTests`** (new): a `.docx` read back with
  `NSAttributedString(url:)` keeps the text, a heading's bold font and list
  markers; a `.pdf` read back with `PDFDocument` has the text and more than
  one page for a long input.
- **`SaveDestinationTests`** (new): each row of the §2 table, the most recent
  folder winning, a Read Only folder skipped, and `saveFolders` round-tripping
  through chat persistence (`ChatPersistenceTests`).
- **`WorkspaceWritePolicyTests`**: `classifyNewFile` for source, docs, hidden,
  agent, secret and config paths; File Mode `create_file` of a new `.py` makes
  no protected notice; an edit of the same file still does.
- **`FileAgentTests`**: `create_file` of `.docx`, `.pdf`, `.xlsx` (→ `.md`) and
  `.command` (→ `.md`), each receipt naming the written path.
- **`NativeToolPlanTests`**: `.saving` on every built plan, absent from
  `.empty`. **`NativeToolPartsTests`** / **`NativeToolsTests`**: `save_file`
  results for each §3.2 case with a fake model call; the approval card for a
  protected new file, Create, Don't Create and Stop.
- **Hosted UI** (`EnigmaConversationTests` or a new `SaveUITests`): code block
  Save, the reply menu, the card's Open / Show in Finder (fake workspace) and
  Undo, VoiceOver labels; the Settings row.
- Tests stay offline and deterministic: temporary folders, a fake
  `NSWorkspace` opener, `UserDefaults(suiteName:)`.

## Docs

- New `docs/Saving-Files.md` (how to save, where files go, types, Undo,
  privacy, how it works, limitations, tests), listed in `docs/README.md`.
- `docs/File-Mode.md`: the safe/protected table (new files), `create_file`
  types, the tool list.
- `docs/Chat.md`: the Save buttons beside Copy.
- `docs/Slash-Commands.md`: `save_file` in the list of tools capable models
  choose.
- `docs/Welcome-and-Settings.md`: the Save folder row.

## Delivery

Three checkpoints, each built by a worker and audited by fresh reviewers
(`docs/Agent-Workflow.md`):

1. **CP1 — Save service and buttons.** `SaveFileType`, naming,
   `SaveDocumentRenderer`, `WorkspaceMutation.saveData`, the `.approved`
   policy, `SaveService` with Enigma's folder only, the Settings row,
   `Info.plist`, both buttons and the card.
2. **CP2 — The tool.** `SaveTools`, `NativeToolPart.saving`, the phase, the
   result texts, cards from tool saves, replacement.
3. **CP3 — Attached folders.** `saveFolders`, `SaveDestination`,
   `classifyNewFile`, the approval card, and File Mode's `create_file` changes.

## Related items

- **F1** (done): the Copy buttons and `ChatCopy.richText`, reused here.
- **F4**: drag and drop attaches through the same path; best built first,
  since both change `FileModeCoordinator`'s attach code. No dependency either
  way.
- **F22**: draft blocks could get a Save button later.
- **F27**: unaffected; small models get no tool.
- **F32** (done): the toolbox and plan this extends.

## Out of scope

- Excel, PowerPoint, Keynote, Numbers, Pages and image files (CSV and Markdown
  instead).
- Saving anywhere other than Enigma's folder or an attached folder, or a save
  panel per save.
- Overwriting or editing existing files outside File Mode, except §3.1's
  replacement.
- A save chip or wording rules for small models.
- Dragging a reply or code block out of the chat.
- Saving screenshots, attachments or whole chats.
