#!/usr/bin/env swift
// Prints what an app exposes to Accessibility about its current text selection.
//
// Usage: swift scripts/selection-probe.swift [--text] [bundle-id] [delay-seconds]
//        swift scripts/selection-probe.swift [--text] --watch [seconds]
//
// With a bundle ID, the probe activates that app, waits `delay` seconds (default 1)
// and reads it. Without one, it waits `delay` seconds (default 5) so you can switch
// to the app and select text, then reads the frontmost app. With `--watch`, it polls
// the frontmost app for `seconds` (default 300) and prints a report whenever its
// selection settles on something new, so you can select text in one app after
// another.
//
// The process running the probe (for example Terminal) needs Accessibility
// permission. The probe only reads, apart from setting AXManualAccessibility (and
// AXEnhancedUserInterface in Chromium browsers) as Enigma does, and it never
// touches the clipboard. Text is reported as a character count unless `--text`
// is given, so probing a private document doesn't print it.
import AppKit
import ApplicationServices
import Carbon

let showText = CommandLine.arguments.contains("--text")
let watch = CommandLine.arguments.contains("--watch")
let arguments = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("--") }
let bundleID = arguments.first.flatMap { Double($0) == nil ? $0 : nil }
let delay = arguments.compactMap(Double.init).first ?? (watch ? 300 : bundleID == nil ? 5 : 1)

guard AXIsProcessTrusted() else {
  print("This process is not trusted for Accessibility. Enable it in System Settings → Privacy & Security → Accessibility.")
  exit(1)
}

func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
  var value: CFTypeRef?
  return AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success ? value : nil
}

func element(_ owner: AXUIElement, _ name: String) -> AXUIElement? {
  guard let value = attribute(owner, name), CFGetTypeID(value) == AXUIElementGetTypeID() else { return nil }
  return (value as! AXUIElement)
}

func parameterized(_ element: AXUIElement, _ name: String, _ parameter: CFTypeRef) -> CFTypeRef? {
  var value: CFTypeRef?
  return AXUIElementCopyParameterizedAttributeValue(element, name as CFString, parameter, &value) == .success ? value : nil
}

func names(_ element: AXUIElement) -> [String] {
  var names: CFArray?
  guard AXUIElementCopyAttributeNames(element, &names) == .success else { return [] }
  return (names as? [String]) ?? []
}

func parameterizedNames(_ element: AXUIElement) -> [String] {
  var names: CFArray?
  guard AXUIElementCopyParameterizedAttributeNames(element, &names) == .success else { return [] }
  return (names as? [String]) ?? []
}

func range(_ element: AXUIElement) -> CFRange? {
  guard let value = attribute(element, kAXSelectedTextRangeAttribute), CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
  var range = CFRange()
  return AXValueGetValue(value as! AXValue, .cfRange, &range) ? range : nil
}

func quoted(_ text: String?) -> String {
  guard let text else { return "nil" }
  guard showText else { return "\(text.count) chars" }
  let flat = text.replacingOccurrences(of: "\n", with: "⏎")
  return flat.count > 80 ? "\"\(flat.prefix(80))…\" (\(text.count) chars)" : "\"\(flat)\""
}

func describe(_ node: AXUIElement, label: String) -> [String] {
  let role = attribute(node, kAXRoleAttribute) as? String ?? "?"
  let subrole = attribute(node, kAXSubroleAttribute) as? String ?? "-"
  var lines = ["\(label): role=\(role) subrole=\(subrole)"]
  lines.append("  AXSelectedText: \(quoted(attribute(node, kAXSelectedTextAttribute) as? String))")
  if let selected = range(node) {
    lines.append("  AXSelectedTextRange: location=\(selected.location) length=\(selected.length)")
    var parameter = selected
    if selected.length > 0, let value = AXValueCreate(.cfRange, &parameter) {
      lines.append("  AXStringForRange: \(quoted(parameterized(node, kAXStringForRangeParameterizedAttribute, value) as? String))")
    }
  } else {
    lines.append("  AXSelectedTextRange: nil")
  }
  if let value = attribute(node, kAXValueAttribute) as? String { lines.append("  AXValue: \(value.count) chars") }
  if let marker = attribute(node, "AXSelectedTextMarkerRange") {
    lines.append("  AXStringForTextMarkerRange: \(quoted(parameterized(node, "AXStringForTextMarkerRange", marker) as? String))")
  } else if names(node).contains("AXSelectedTextMarkerRange") {
    lines.append("  AXSelectedTextMarkerRange: listed but unreadable")
  }
  let text = names(node).filter { $0.localizedCaseInsensitiveContains("text") || $0.contains("Selected") }
  lines.append("  text attributes: \(text.joined(separator: ", "))")
  let parameters = parameterizedNames(node).filter { $0.localizedCaseInsensitiveContains("text") || $0.contains("String") }
  if !parameters.isEmpty { lines.append("  parameterized: \(parameters.joined(separator: ", "))") }
  return lines
}

/// Apps whose accessibility attributes the probe has already set, with how long the
/// focused element took to appear afterwards.
var prepared: [pid_t: String] = [:]

/// Keep in step with `SelectionCapturePolicy.chromiumBrowsers`.
let chromiumBrowsers: Set<String> = [
  "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary",
  "org.chromium.Chromium", "com.microsoft.edgemac", "com.microsoft.edgemac.Beta", "com.microsoft.edgemac.Dev",
  "com.microsoft.edgemac.Canary", "com.brave.Browser", "com.brave.Browser.beta", "com.brave.Browser.nightly",
  "company.thebrowser.Browser", "company.thebrowser.dia", "com.vivaldi.Vivaldi", "com.vivaldi.Vivaldi.snapshot",
  "com.operasoftware.Opera", "com.operasoftware.OperaNext", "com.operasoftware.OperaDeveloper",
  "com.operasoftware.OperaGX", "com.operasoftware.OperaAir"]

@MainActor
func report(_ app: NSRunningApplication) -> [String] {
  let application = AXUIElementCreateApplication(app.processIdentifier)
  AXUIElementSetMessagingTimeout(application, 0.5)
  var lines = ["app: \(app.localizedName ?? "?") bundle=\(app.bundleIdentifier ?? "?") secureInput=\(IsSecureEventInputEnabled())"]
  if prepared[app.processIdentifier] == nil {
    let manual = AXUIElementSetAttributeValue(application, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    // Chrome answers notImplemented (-25208) here, yet builds its tree.
    let enhanced = chromiumBrowsers.contains(app.bundleIdentifier ?? "")
      ? AXUIElementSetAttributeValue(application, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue) : nil
    let start = Date()
    var found = false
    for _ in 0..<60 {
      if element(application, kAXFocusedUIElementAttribute) != nil { found = true; break }
      Thread.sleep(forTimeInterval: 0.05)
    }
    prepared[app.processIdentifier] = "AXManualAccessibility \(manual == .success ? "ok" : "error \(manual.rawValue)"); "
      + (enhanced.map { "AXEnhancedUserInterface \($0 == .success ? "ok" : "error \($0.rawValue)"); " } ?? "")
      + (found ? String(format: "focused element after %.0f ms", Date().timeIntervalSince(start) * 1000) : "no focused element within 3 s")
  }
  lines.append(prepared[app.processIdentifier]!)
  guard let focused = element(application, kAXFocusedUIElementAttribute) else {
    lines.append("focused element: none")
    // Some Electron apps never report a focused element; look for web areas in the window.
    guard let window = element(application, kAXFocusedWindowAttribute) ?? element(application, kAXMainWindowAttribute) else {
      return lines + ["focused window: none"]
    }
    var queue = [(window, 0)], visited = 0
    while !queue.isEmpty, visited < 2000 {
      let (node, depth) = queue.removeFirst()
      visited += 1
      if attribute(node, kAXRoleAttribute) as? String == "AXWebArea" { lines += describe(node, label: "window web area (depth \(depth))") }
      guard depth < 30, let children = attribute(node, kAXChildrenAttribute) as? [AXUIElement] else { continue }
      queue += children.map { ($0, depth + 1) }
    }
    return lines
  }
  lines += describe(focused, label: "focused")
  var current = element(focused, kAXParentAttribute)
  var depth = 1
  while let node = current, depth < 80 {
    let role = attribute(node, kAXRoleAttribute) as? String ?? "?"
    if role == "AXWebArea" { lines += describe(node, label: "ancestor \(depth) (web area)") }
    if role == kAXApplicationRole { lines.append("application is ancestor \(depth)"); break }
    current = element(node, kAXParentAttribute)
    depth += 1
  }
  return lines
}

if watch {
  print("Watching the frontmost app for \(Int(delay)) s. Select text in one app after another.")
  let ownApps: Set<String> = ["com.apple.Terminal", "com.googlecode.iterm2"]
  var lastPoll: [String] = [], lastPrinted: [pid_t: [String]] = [:]
  let end = Date(timeIntervalSinceNow: delay)
  while Date() < end {
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.5))
    guard let app = NSWorkspace.shared.frontmostApplication, !ownApps.contains(app.bundleIdentifier ?? "") else { continue }
    let lines = MainActor.assumeIsolated { report(app) } // Top-level code runs on the main thread.
    // Print only once a selection has held for one poll and differs from the last one printed.
    if lines == lastPoll, lastPrinted[app.processIdentifier] != lines {
      print("--- \(Date().formatted(date: .omitted, time: .standard))")
      lines.forEach { print($0) }
      fflush(stdout)
      lastPrinted[app.processIdentifier] = lines
    }
    lastPoll = lines
  }
  exit(0)
}

var target: NSRunningApplication?
if let bundleID {
  target = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
  guard let target else { print("\(bundleID) is not running."); exit(1) }
  target.activate(options: [])
}
RunLoop.current.run(until: Date(timeIntervalSinceNow: delay)) // Lets NSWorkspace see the new frontmost app.
guard let app = target ?? NSWorkspace.shared.frontmostApplication else { print("No frontmost app."); exit(1) }
print("frontmost: \(NSWorkspace.shared.frontmostApplication?.bundleIdentifier ?? "?")")
MainActor.assumeIsolated { report(app) }.forEach { print($0) }
