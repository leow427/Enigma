import SwiftUI

/// The sheet and alerts file mode needs: the change review, Codex consent, and
/// the delete confirmation.
struct FileModeDialogs: ViewModifier {
  @ObservedObject var files: FileModeCoordinator
  @Binding var isCloudConsentPresented: Bool
  let isBusy: Bool
  /// The appearance the review sheet takes, since a sheet is its own window.
  let reviewAppearance: EnigmaAppearance
  let useCodex: () -> Void

  private var deletionPresented: Binding<Bool> {
    Binding(get: { files.deletionPath != nil }, set: { if !$0 { files.answerDeletion(false) } })
  }

  func body(content: Content) -> some View {
    content
      .sheet(item: $files.review) { change in
        FileChangesReview(changeSet: change) { Task { await files.undo(change) } }
          .enigmaTheme(reviewAppearance)
      }
      .alert("Use Codex for these files?", isPresented: $isCloudConsentPresented) {
        Button("Use Codex", action: useCodex)
        Button("Cancel", role: .cancel) { }
      } message: {
        Text("Codex can edit the attached files. Relevant file contents may be sent to the cloud when you send your next request. Your current local task will not be sent automatically.")
      }
      .alert("Delete this file?", isPresented: deletionPresented) {
        Button("Delete", role: .destructive) { files.answerDeletion(true) }
        Button("Keep File", role: .cancel) { files.answerDeletion(false) }
      } message: {
        Text("\(files.deletionPath ?? "") will be deleted from your attached workspace. You can restore it with Undo.")
      }
  }
}
