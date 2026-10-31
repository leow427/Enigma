import AppKit
import SwiftUI

// MARK: Pretend document

/// The selection stop's pretend app: a real window with a draft in it, so
/// Enigma's own selection panel can open under its selected line exactly as
/// it does over any app. Its right side holds the tour's card while Enigma's
/// window is away or is the panel.
@MainActor
final class TourDocumentWindow {
  static let shared = TourDocumentWindow()
  static let contentSize = NSSize(width: 560 + GuidedTourPlacement.railWidth, height: 560)
  private var window: NSPanel?
  /// On screen, as the selection stop shows it.
  var isShowing: Bool { window?.isVisible == true }
  /// The selected line, in the content's own space with a top-left origin.
  var selection: CGRect = .zero
  /// Counts fades, so a finished fade-out can't hide the window opened again since.
  private var fades = 0
  private var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

  /// Rises into place as Enigma's window fades aside.
  func open() {
    let window = self.window ?? makeWindow()
    self.window = window
    fades += 1
    let screen = NSScreen.screens.first { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) } ?? NSScreen.main
    let frame = screen.map { PanelSizeStore.centeredFrame(size: window.frame.size, in: $0.visibleFrame) } ?? window.frame
    window.setFrame(frame.offsetBy(dx: 0, dy: reduceMotion ? 0 : -16), display: false)
    window.alphaValue = 0
    window.makeKeyAndOrderFront(nil)
    NSAnimationContext.runAnimationGroup { context in
      context.duration = reduceMotion ? 0.15 : 0.38
      context.timingFunction = CAMediaTimingFunction(controlPoints: 0.2, 0.8, 0.2, 1)
      window.animator().alphaValue = 1
      window.animator().setFrame(frame, display: true)
    }
  }

  /// Fades away, behind Enigma's window.
  func close() {
    guard let window, window.isVisible else { return }
    fades += 1
    let fade = fades
    NSAnimationContext.runAnimationGroup { context in
      context.duration = reduceMotion ? 0 : 0.22
      window.animator().alphaValue = 0
    } completionHandler: {
      MainActor.assumeIsolated {
        guard fade == self.fades else { return }
        window.orderOut(nil)
        window.alphaValue = 1
      }
    }
  }

  /// Above the other apps while Enigma's window steps aside for a paste.
  func bringForward() { window?.orderFrontRegardless() }

  /// The selected line on screen, for placing the panel under it.
  var selectionOnScreen: NSRect? {
    guard let window, let content = window.contentView, window.isVisible, !selection.isEmpty else { return nil }
    let inView = content.isFlipped ? selection
      : NSRect(x: selection.minX, y: content.bounds.height - selection.maxY, width: selection.width, height: selection.height)
    return window.convertToScreen(content.convert(inView, to: nil))
  }

  private func makeWindow() -> NSPanel {
    let panel = TourDocumentPanel(contentRect: NSRect(origin: .zero, size: Self.contentSize),
                                  styleMask: [.titled, .nonactivatingPanel], backing: .buffered, defer: false)
    panel.title = "Saturday plans – Shmoogle Docs"
    panel.isFloatingPanel = true
    // Under Enigma's window and panel, as another app's window is, so it
    // never covers them, even after a click on its card, and above the rest.
    panel.level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue - 1)
    // It fades and rises on its own.
    panel.animationBehavior = .none
    panel.hidesOnDeactivate = false
    panel.isReleasedWhenClosed = false
    panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
    panel.contentView = NSHostingView(rootView: TourDocumentRoot())
    return panel
  }
}

/// Takes keys, so Return reaches the card's button.
private final class TourDocumentPanel: NSPanel {
  override var canBecomeKey: Bool { true }
}

/// The pretend document in Enigma's theme, which only its card uses.
private struct TourDocumentRoot: View {
  @ObservedObject private var appearance = EnigmaAppearancePreference.shared

  var body: some View {
    TourDocumentView(tour: .shared)
      .enigmaTheme(appearance.appearance)
  }
}

/// The draft, with its line selected, the ⌥ taps, and the replacement as
/// they happen, beside the tour's card.
struct TourDocumentView: View {
  @ObservedObject var tour: GuidedTour
  /// Tests leave the shared pretend window alone.
  var measures = true
  @Environment(\.enigmaPalette) private var palette

  var body: some View {
    let scene = tour.scene
    HStack(spacing: 0) {
      VStack(alignment: .leading, spacing: 0) {
        ShmoogleDocsHeader()
        document(scene)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
      .background(Color.white)
      .overlay(alignment: .bottom) {
        // The two ⌥ taps, under the text so they never cover it.
        HStack(spacing: 10) {
          GuidedTourKeycap(key: "⌥", isPressed: scene.keys >= 1)
          GuidedTourKeycap(key: "⌥", isPressed: scene.keys >= 2)
        }
        .scaleEffect(1.4)
        .padding(.bottom, 48)
        .opacity(scene.keys > 0 ? 1 : 0)
        .animation(.easeInOut(duration: 0.2), value: scene.keys)
      }
      ZStack {
        GuidedTourRail()
        // The card stays here until the chat moves into Enigma's window, which shows its own.
        if scene.phase < .sent {
          GuidedTourCard(tour: tour, stop: .selection, onAdvance: { GuidedTour.shared.press() },
                         onFinish: { GuidedTour.shared.requestFinish() })
            .frame(width: GuidedTourPlacement.railWidth - 2 * GuidedTourPlacement.margin)
            .transition(.opacity)
        }
      }
      .frame(width: GuidedTourPlacement.railWidth)
      .animation(EnigmaMotion.pageChange.animation, value: scene.phase)
    }
    .frame(width: TourDocumentWindow.contentSize.width, height: TourDocumentWindow.contentSize.height)
  }

  private func document(_ scene: TourScene) -> some View {
    let replaced = scene.phase >= .replaced
    return VStack(alignment: .leading, spacing: 14) {
      Text("Hi Mette,")
      Text("Saturday is all set. Let’s meet at the Art Institute at 10, then lunch at Portillo’s.")
        .fixedSize(horizontal: false, vertical: true)
      ZStack(alignment: .leading) {
        // The selection sweeps across the line, as a drag would.
        Text(TourScene.original)
          .background(alignment: .leading) {
            Color(red: 0.70, green: 0.84, blue: 1)
              .padding(-2)
              .scaleEffect(x: scene.phase >= .selected ? 1 : 0, anchor: .leading)
              .animation(.easeInOut(duration: 0.8), value: scene.phase)
          }
          .opacity(replaced ? 0 : 1)
        Text(TourScene.revised)
          .background(palette.accent.color.opacity(0.22).padding(-2))
          .opacity(replaced ? 1 : 0)
      }
      .animation(.easeInOut(duration: 0.35), value: replaced)
      .onGeometryChange(for: CGRect.self) { $0.frame(in: .global) } action: { frame in
        if measures { TourDocumentWindow.shared.selection = frame }
      }
      Text("See you there,\nAlex")
    }
    .font(.system(size: 15))
    .foregroundStyle(Color(white: 0.12))
    .padding(40)
  }
}

/// The pretend app's toolbar, for fun: its logo, the draft's name, its menus and Share.
private struct ShmoogleDocsHeader: View {
  var body: some View {
    HStack(alignment: .center, spacing: 10) {
      ShmoogleDocsLogo()
      VStack(alignment: .leading, spacing: 3) {
        Text("Saturday plans")
          .font(.system(size: 15))
          .foregroundStyle(Color(white: 0.13))
        HStack(spacing: 11) {
          ForEach(["File", "Edit", "View", "Insert", "Format", "Tools"], id: \.self) { Text($0) }
        }
        .font(.system(size: 11.5))
        .foregroundStyle(Color(white: 0.35))
      }
      Spacer(minLength: 8)
      Text("Share")
        .font(.system(size: 12, weight: .medium))
        .foregroundStyle(Color(red: 0.04, green: 0.20, blue: 0.43))
        .padding(.horizontal, 14)
        .padding(.vertical, 6)
        .background(Color(red: 0.76, green: 0.87, blue: 0.99), in: Capsule())
    }
    .padding(.horizontal, 16)
    .padding(.vertical, 10)
    .background(Color(red: 0.976, green: 0.984, blue: 0.992))
    .overlay(alignment: .bottom) { Color(white: 0.88).frame(height: 1) }
    .accessibilityHidden(true)
  }
}

/// Shmoogle Docs' logo: a blue page with a folded corner and lines of text.
private struct ShmoogleDocsLogo: View {
  var body: some View {
    let blue = Color(red: 0.26, green: 0.52, blue: 0.96)
    ZStack(alignment: .topLeading) {
      ShmooglePage(fold: 6).fill(blue)
      ShmoogleFold(fold: 6).fill(Color(red: 0.63, green: 0.76, blue: 0.98))
      VStack(alignment: .leading, spacing: 2.4) {
        ForEach(0..<3, id: \.self) { _ in Capsule().fill(.white).frame(width: 11, height: 1.6) }
        Capsule().fill(.white).frame(width: 7, height: 1.6)
      }
      .offset(x: 4.5, y: 9)
    }
    .frame(width: 20, height: 26)
    .fixedSize()
  }
}

private struct ShmooglePage: Shape {
  let fold: CGFloat
  func path(in rect: CGRect) -> Path {
    Path { path in
      path.move(to: CGPoint(x: rect.minX, y: rect.minY))
      path.addLine(to: CGPoint(x: rect.maxX - fold, y: rect.minY))
      path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + fold))
      path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
      path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
      path.closeSubpath()
    }
  }
}

private struct ShmoogleFold: Shape {
  let fold: CGFloat
  func path(in rect: CGRect) -> Path {
    Path { path in
      path.move(to: CGPoint(x: rect.maxX - fold, y: rect.minY))
      path.addLine(to: CGPoint(x: rect.maxX - fold, y: rect.minY + fold))
      path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + fold))
      path.closeSubpath()
    }
  }
}
