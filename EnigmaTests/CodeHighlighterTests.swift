import SwiftUI
import XCTest
@testable import Enigma

/// The code block tokenizer, and its cache for streamed code.
final class CodeHighlighterTests: XCTestCase {
  /// The coloured pieces of a block, in order, as (text, kind).
  private func tokens(_ code: String, _ language: CodeLanguage) -> [String] {
    var state = CodeHighlighter.State(language: language, code: code)
    return code.split(separator: "\n", omittingEmptySubsequences: false).flatMap { line in
      CodeHighlighter.segments(line, state: &state).compactMap { segment in
        segment.kind.map { "\(segment.text):\($0)" }
      }
    }
  }

  // MARK: Languages

  func testLanguageHintsMapToTheCommonLanguagesAndUnknownOnesStayPlain() {
    XCTAssertEqual(CodeLanguage(hint: "swift"), .swift)
    XCTAssertEqual(CodeLanguage(hint: "Python"), .python)
    XCTAssertEqual(CodeLanguage(hint: "py"), .python)
    for hint in ["js", "javascript", "jsx", "ts", "typescript", "tsx", "mjs"] {
      XCTAssertEqual(CodeLanguage(hint: hint), .javascript, hint)
    }
    for hint in ["bash", "sh", "zsh", "shell", "console"] {
      XCTAssertEqual(CodeLanguage(hint: hint), .shell, hint)
    }
    XCTAssertEqual(CodeLanguage(hint: "json"), .json)
    XCTAssertEqual(CodeLanguage(hint: "html"), .html)
    XCTAssertEqual(CodeLanguage(hint: "xml"), .html)
    XCTAssertEqual(CodeLanguage(hint: "css"), .css)
    XCTAssertEqual(CodeLanguage(hint: "SQL"), .sql)
    XCTAssertNil(CodeLanguage(hint: nil))
    XCTAssertNil(CodeLanguage(hint: "text"))
    XCTAssertNil(CodeLanguage(hint: "draft"))
  }

  func testSegmentsCoverTheWholeLine() {
    let line = #"let total = items.count + 42 // sum"#
    var state = CodeHighlighter.State(language: .swift, code: line)
    XCTAssertEqual(CodeHighlighter.segments(Substring(line), state: &state).map(\.text).joined(), line)
  }

  // MARK: Code

  func testSwiftKeywordsStringsNumbersCommentsTypesAndVariables() {
    let code = """
    @MainActor func load(_ url: URL) -> Int {
      let count = 0x1F + 2.5 // start
      var name: String = "a \\"quoted\\" b"
      return count
    }
    """
    XCTAssertEqual(tokens(code, .swift), [
      "@MainActor:keyword", "func:keyword", "URL:type", "Int:type",
      "let:keyword", "count:variable", "0x1F:number", "2.5:number", "// start:comment",
      "var:keyword", "name:variable", "String:type", #""a \"quoted\" b":string"#,
      "return:keyword",
    ])
  }

  func testRangesAndIdentifiersWithDigitsAreNotNumbers() {
    XCTAssertEqual(tokens("for i in 1..<n2 {}", .swift), ["for:keyword", "in:keyword", "1:number"])
  }

  func testBlockCommentsAndMultilineStringsCarryAcrossLines() {
    let code = """
    /* one
    two */ let a = \"\"\"
    text
    \"\"\"
    """
    XCTAssertEqual(tokens(code, .swift), [
      "/* one:comment", "two */:comment", "let:keyword", "a:variable", "\"\"\":string",
      "text:string", "\"\"\":string",
    ])
  }

  func testPython() {
    let code = """
    def greet(name: str) -> None:
        total = 10 # count
        return f'hi {name}' if True else None
    """
    XCTAssertEqual(tokens(code, .python), [
      "def:keyword", "str:type", "None:keyword",
      "total:variable", "10:number", "# count:comment",
      "return:keyword", "'hi {name}':string", "if:keyword", "True:keyword", "else:keyword", "None:keyword",
    ])
  }

  func testJavaScriptAndTypeScript() {
    let code = "const user: User = await fetch(`/api/${id}`); // go"
    XCTAssertEqual(tokens(code, .javascript), [
      "const:keyword", "user:variable", "User:type", "await:keyword", "`/api/${id}`:string", "// go:comment",
    ])
    // Arrow functions and comparisons aren't assignments.
    XCTAssertEqual(tokens("a => a == b", .javascript), [])
  }

  func testJSONKeysAreVariablesAndValuesKeepTheirKinds() {
    XCTAssertEqual(tokens(#"{"name": "Enigma", "size": 1.5e3, "ok": true, "x": null}"#, .json), [
      #""name":variable"#, #""Enigma":string"#, #""size":variable"#, "1.5e3:number",
      #""ok":variable"#, "true:keyword", #""x":variable"#, "null:keyword",
    ])
  }

  func testHTMLTagsAttributesStringsAndComments() {
    XCTAssertEqual(tokens(#"<a href="/x">Hello</a> <!-- note -->"#, .html), [
      "a:keyword", "href:variable", #""/x":string"#, "a:keyword", "<!-- note -->:comment",
    ])
    // Quotes and `=` in text content aren't attributes; hyphenated attributes stay whole.
    XCTAssertEqual(tokens(#"<p data-id="1">Don't panic, a = b</p>"#, .html), [
      "p:keyword", "data-id:variable", #""1":string"#, "p:keyword",
    ])
    // A tag can span lines.
    XCTAssertEqual(tokens("<img\n  alt='x'>", .html), ["img:keyword", "alt:variable", "'x':string"])
  }

  func testCSSPropertiesNumbersAndAtRules() {
    XCTAssertEqual(tokens("@media screen { .card { margin: 10px 0; color: #fff; } } /* c */", .css), [
      "@media:keyword", "margin:variable", "10px:number", "0:number", "color:variable", "#fff:number",
      "/* c */:comment",
    ])
    // Outside a rule, `name:` is a selector with a pseudo-class, and `#id` isn't a colour.
    XCTAssertEqual(tokens("a:hover, #fade::before { color: red; }", .css), ["color:variable"])
    XCTAssertEqual(tokens(".a {\n  color: red;\n}\na:hover {}", .css), ["color:variable"])
    // Hyphenated properties and custom properties are one name.
    XCTAssertEqual(tokens(":root { --main-color: red; background-color: var(--main-color); }", .css), [
      "--main-color:variable", "background-color:variable",
    ])
  }

  func testSQLKeywordsIgnoreCase() {
    XCTAssertEqual(tokens("select name FROM users WHERE id = 3 -- one", .sql), [
      "select:keyword", "FROM:keyword", "WHERE:keyword", "3:number", "-- one:comment",
    ])
  }

  // MARK: Terminal

  func testShellCommandsFlagsPathsVariablesAndStrings() {
    XCTAssertEqual(tokens(#"FOO=1 git commit -m "msg" --amend ~/src | grep $HOME && ./run.sh ${X} # end"#, .shell), [
      "FOO:variable", "git:command", "-m:flag", #""msg":string"#, "--amend:flag", "~/src:path",
      "grep:command", "$HOME:variable", "./run.sh:command", "${X}:variable", "# end:comment",
    ])
    XCTAssertEqual(tokens("if [ -f /etc/hosts ]; then echo ok; fi", .shell), [
      "if:keyword", "[:command", "-f:flag", "/etc/hosts:path", "then:keyword", "echo:command", "fi:keyword",
    ])
    // A redirect's target is a path, not a command; a quoted variable value doesn't hide the command.
    XCTAssertEqual(tokens("echo 'x' >> ~/.zshrc; ls > /dev/null 2>&1", .shell), [
      "echo:command", "'x':string", "~/.zshrc:path", "ls:command", "/dev/null:path",
    ])
    XCTAssertEqual(tokens(#"FOO="a b" make build"#, .shell), ["FOO:variable", "make:command"])
    // The word after `$(…)` keeps what it was before the substitution.
    XCTAssertEqual(tokens("docker run -v $(pwd):/app node", .shell),
                   ["docker:command", "-v:flag", "pwd:command", ":/app:path"])
    XCTAssertEqual(tokens("VERSION=$(git describe) make", .shell),
                   ["VERSION:variable", "git:command", "make:command"])
    XCTAssertEqual(tokens("echo $(date) done", .shell), ["echo:command", "date:command"])
    // `export` and `local` set variables.
    XCTAssertEqual(tokens(#"export PATH="/opt/bin:$PATH" A=1"#, .shell),
                   ["export:keyword", "PATH:variable", "A:variable"])
    // An escaped quote outside quotes doesn't open a string.
    XCTAssertEqual(tokens("echo It\\'s ok\nls", .shell), ["echo:command", "ls:command"])
  }

  func testHereDocumentBodyStaysPlainUntilItsEndWord() {
    let code = """
    cat <<'EOT' > notes.txt
    ls -la here is text
    EOT
    echo done
    """
    XCTAssertEqual(tokens(code, .shell), [
      "cat:command", "'EOT':path", "notes.txt:path", "echo:command",
    ])
  }

  func testHereDocumentsWithAnEscapedEndWordEndAndShiftsDoNotStartOne() {
    XCTAssertEqual(tokens("cat <<\\EOF\nbody\nEOF\necho done", .shell),
                   ["cat:command", "\\EOF:path", "echo:command"])
    XCTAssertEqual(tokens("echo $((1 << 4))\nls -la /tmp", .shell),
                   ["echo:command", "4:path", "ls:command", "-la:flag", "/tmp:path"])
  }

  func testShellStringsCarryAcrossLines() {
    let code = """
    curl -d '{
      "name": "x"
    }' | jq '.id'
    git commit -m "Title

    Body \\" quote"
    """
    XCTAssertEqual(tokens(code, .shell), [
      "curl:command", "-d:flag", "'{:string", #"  "name": "x":string"#, "}':string", "jq:command", "'.id':string",
      "git:command", "-m:flag", #""Title:string"#, #"Body \" quote":string"#,
    ])
    // A single-quoted string has no escapes: its backslash is literal.
    XCTAssertEqual(tokens(#"echo 'a\' b"#, .shell), ["echo:command", #"'a\':string"#])
  }

  func testTerminalTokensHaveTheirOwnColoursAndOutputIsDimmed() {
    for palette in [EnigmaPalette.paper, .ink] {
      let colours = [CodeTokenKind.command, .flag, .path, .variable].map { CodeHighlightCache.color($0, palette: palette) }
      XCTAssertEqual(Set(colours.map { [$0.red, $0.green, $0.blue] }).count, 4)
      XCTAssertEqual(CodeHighlightCache.color(.output, palette: palette), palette.textSecondary)
    }
  }

  func testTerminalSessionColoursOnlyCommandsAndDimsTheOutput() {
    let code = """
    $ swift build \\
        -c release
    Compiling Enigma
    % ls src/
    main.swift
    """
    XCTAssertEqual(tokens(code, .shell), [
      "$ :output", "swift:command", "-c:flag", "Compiling Enigma:output",
      "% :output", "ls:command", "src/:path", "main.swift:output",
    ])
  }

  func testContinuationKeepsWhetherTheNextWordIsACommand() {
    XCTAssertEqual(tokens("apt-get update && \\\n  sudo apt-get install -y curl", .shell),
                   ["apt-get:command", "sudo:command", "-y:flag"])
    XCTAssertEqual(tokens("docker run \\\n  -p 3000:3000 node", .shell), ["docker:command", "-p:flag"])
    XCTAssertEqual(tokens("$ brew update && \\\n  brew install wget", .shell),
                   ["$ :output", "brew:command", "brew:command"])
  }

  func testShellWithoutPromptsIsAllCommands() {
    XCTAssertEqual(tokens("cd /tmp\nls -la", .shell), ["cd:command", "/tmp:path", "ls:command", "-la:flag"])
  }

  // MARK: Rendering and streaming

  @MainActor
  func testHighlightedTextKeepsTheCodeAndColoursItFromThePalette() {
    let cache = CodeHighlightCache()
    let code = "let a = 1 // x\nprint(a)"
    let text = cache.highlighted(code, language: .swift, palette: .paper)
    XCTAssertEqual(String(text.characters), code)
    let keyword = text.runs.first { String(text[$0.range].characters) == "let" }
    XCTAssertEqual(keyword?.foregroundColor, EnigmaPalette.paper.codeKeyword.color)
    let comment = text.runs.first { String(text[$0.range].characters) == "// x" }
    XCTAssertEqual(comment?.foregroundColor, EnigmaPalette.paper.codeComment.color)
    let ink = cache.highlighted(code, language: .swift, palette: .ink)
    let inkKeyword = ink.runs.first { String(ink[$0.range].characters) == "let" }
    XCTAssertEqual(inkKeyword?.foregroundColor, EnigmaPalette.ink.codeKeyword.color)
  }

  @MainActor
  func testStreamedCodeHighlightsOnlyTheLinesItHasNotSeen() {
    let cache = CodeHighlightCache()
    let full = "/* a\nb */\nlet x = 1\nlet y = \"s\"\nreturn x"
    var streamed = ""
    for character in full {
      streamed.append(character)
      let text = cache.highlighted(streamed, language: .swift, palette: .paper)
      XCTAssertEqual(String(text.characters), streamed)
      // Each update reads only the unfinished last line, plus the line that
      // has just finished, never the lines before it.
      let lines = streamed.split(separator: "\n", omittingEmptySubsequences: false)
      XCTAssertLessThanOrEqual(cache.lastHighlightedLength,
                               lines[lines.count - 1].utf8.count + (lines.dropLast().last?.utf8.count ?? 0) + 1)
    }
    XCTAssertEqual(cache.highlighted(full, language: .swift, palette: .paper),
                   CodeHighlightCache().highlighted(full, language: .swift, palette: .paper))
  }

  @MainActor
  func testCacheStartsAgainWhenTheCodeNoLongerExtendsWhatItRead() {
    let cache = CodeHighlightCache()
    // A closing fence arriving in pieces shows as code for a moment, then goes.
    for code in ["let a = 1\nlet b = 2\n``", "let a = 1\nlet b = 2", "struct S {}\nlet c = 3"] {
      XCTAssertEqual(cache.highlighted(code, language: .swift, palette: .paper),
                     CodeHighlightCache().highlighted(code, language: .swift, palette: .paper), code)
    }
  }

  @MainActor
  func testCacheStartsAgainWhenTheCodeOrLanguageChanges() {
    let cache = CodeHighlightCache()
    _ = cache.highlighted("let a = 1\nlet b = 2", language: .swift, palette: .paper)
    let replaced = cache.highlighted("x = 1\ny = 2", language: .python, palette: .paper)
    XCTAssertEqual(replaced, CodeHighlightCache().highlighted("x = 1\ny = 2", language: .python, palette: .paper))
    // A prompt line arriving later turns earlier lines into output.
    _ = cache.highlighted("ls\nfile", language: .shell, palette: .paper)
    let session = cache.highlighted("ls\nfile\n$ pwd", language: .shell, palette: .paper)
    XCTAssertEqual(session, CodeHighlightCache().highlighted("ls\nfile\n$ pwd", language: .shell, palette: .paper))
  }
}
