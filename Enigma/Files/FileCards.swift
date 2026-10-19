import SwiftUI

// File mode cards: the attached files over the composer, the line that offers
// Review and Undo after a task changes files, and the review sheet.

/// Attached files and folders: each with its access and a remove button,
/// what will happen to them, and any notice.
struct FileAttachmentCard: View {
  @ObservedObject var files: FileModeCoordinator
  let access: FileAccessLevel
  let isCloud: Bool
  let isBusy: Bool
  let useCodex: () -> Void
  @Environment(\.enigmaPalette) private var palette

  var body: some View {
    VStack(alignment: .leading, spacing: 6) {
      if let selection = files.selection {
        ForEach(selection.attachments) { attachment in
          HStack(spacing: 8) {
            Image(systemName: attachment.isDirectory ? "folder" : "doc")
              .font(EnigmaTypography.symbol(12))
              .foregroundStyle(palette.accentText.color)
              .accessibilityHidden(true)
            Text(attachment.name)
              .font(EnigmaTypography.ui(12.5, weight: .medium))
              .foregroundStyle(palette.textPrimary.color)
              .lineLimit(1)
            Text(access.rawValue.lowercased())
              .font(EnigmaTypography.mono(11))
              .foregroundStyle(palette.textSecondary.color)
              .lineLimit(1)
            Spacer(minLength: 4)
            Button { files.remove(id: attachment.id) } label: {
              Image(systemName: "xmark").font(EnigmaTypography.smallIconButtonSymbol)
            }
            .enigmaIconButtonStyle(size: CGSize(width: 24, height: 22))
            .accessibilityLabel("Remove \(attachment.name)")
            .disabled(isBusy || files.isWorking)
            .enigmaTestMarker("Remove \(attachment.name)")
          }
          .accessibilityElement(children: .contain)
          .accessibilityLabel("\(attachment.name) — \(access.rawValue)")
        }
        if access == .readOnly {
          HStack(alignment: .firstTextBaseline, spacing: 6) {
            note(isCloud ? "Choose Codex to work with these files." : "Choose a local model to work with these files.")
            Button("Use Codex", action: useCodex)
              .enigmaButtonStyle(.text)
              .disabled(isBusy || files.isWorking)
              .enigmaTestMarker("Use Codex")
          }
        } else {
          note(isCloud ? "Relevant file contents may be sent to Codex when you send a request."
               : "Notes and text files can be edited locally. Protected edits use Codex when available, with your permission.")
        }
      }
      if let notice = files.protectedWrite {
        EnigmaStatusLine(.problem, notice.message)
        if case .cloudRequired = notice {
          Button("Use Codex", action: useCodex)
            .enigmaButtonStyle(.secondary)
            .disabled(isBusy || files.isWorking)
            .enigmaTestMarker("Use Codex for protected edits")
        }
      }
      if let error = files.error {
        EnigmaStatusLine(.problem, error)
      }
    }
    .enigmaCard(padding: 10)
  }

  private func note(_ text: String) -> some View {
    Text(text)
      .font(EnigmaTypography.ui(12))
      .foregroundStyle(palette.textSecondary.color)
      .fixedSize(horizontal: false, vertical: true)
  }
}

/// After a task changes files: how many, with Review and Undo, and earlier
/// change sets in a menu.
struct FileChangeSummary: View {
  @ObservedObject var files: FileModeCoordinator
  let isBusy: Bool
  @Environment(\.enigmaPalette) private var palette

  var body: some View {
    if let latest = files.visibleChanges.first {
      HStack(alignment: .center, spacing: 6) {
        Text("\(latest.count) \(latest.count == 1 ? "file" : "files") changed")
          .font(EnigmaTypography.mono(11.5))
          .foregroundStyle(palette.textSecondary.color)
        Button("Review") { files.review = latest }
          .enigmaButtonStyle(.text)
          .enigmaTestMarker("Review file changes")
        Button("Undo") { Task { await files.undo(latest) } }
          .enigmaButtonStyle(.text)
          .disabled(isBusy || files.isWorking)
          .enigmaTestMarker("Undo file changes")
        if files.visibleChanges.count > 1 {
          EnigmaMenu("Earlier changes", sections: [EnigmaMenuSection(items: files.visibleChanges.dropFirst().map { change in
            EnigmaMenuItem(id: change.id, title: "\(change.selection.displayName) · \(change.count) files") {
              files.review = change
            }
          })], style: .plain) {
            Text("Earlier changes")
          }
          .fixedSize()
        }
        Spacer(minLength: 0)
      }
      .padding(.horizontal, 2)
    }
  }
}

/// The files a task changed, before and after, with Undo, as in
/// `FileChangesReview`. Undo Changes is the sheet's one `accent` button.
struct FileChangesReview: View {
  let changeSet: WorkspaceChangeSet
  let undo: () -> Void
  @Environment(\.dismiss) private var dismiss
  @Environment(\.enigmaPalette) private var palette

  static let size = CGSize(width: 660, height: 480)

  var body: some View {
    VStack(alignment: .leading, spacing: 14) {
      HStack(alignment: .top) {
        VStack(alignment: .leading, spacing: 4) {
          Text("\(changeSet.count) files changed")
            .font(EnigmaTypography.ui(19, weight: .semibold))
            .tracking(-0.3)
            .foregroundStyle(palette.textPrimary.color)
            .accessibilityAddTraits(.isHeader)
          Text(changeSet.selection.displayName)
            .font(EnigmaTypography.mono(11.5))
            .foregroundStyle(palette.textSecondary.color)
        }
        Spacer()
        Button("Done") { dismiss() }
          .enigmaButtonStyle(.secondary)
          .enigmaTestMarker("Done reviewing")
      }
      ScrollView {
        VStack(alignment: .leading, spacing: 0) {
          ForEach(changeSet.changes.filter { $0.before != $0.after }) { change in
            FileChangeRow(change: change)
          }
        }
        .overlay(alignment: .bottom) { EnigmaHairline() }
      }
      HStack(alignment: .center) {
        Text("Undo restores the files to how they were before this task.")
          .font(EnigmaTypography.ui(12))
          .foregroundStyle(palette.textSecondary.color)
        Spacer()
        Button("Undo Changes", action: undo)
          .enigmaButtonStyle(.primary)
          .enigmaTestMarker("Undo Changes")
      }
    }
    .padding(24)
    .frame(width: Self.size.width, height: Self.size.height)
    .background(palette.background.color)
  }
}

/// One changed file: what happened and its path, opening to its contents
/// before and after.
private struct FileChangeRow: View {
  let change: WorkspaceChange
  @Environment(\.enigmaPalette) private var palette

  var body: some View {
    VStack(alignment: .leading, spacing: 0) {
      EnigmaDisclosure("\(change.kind) · \(change.path)") {
        VStack(alignment: .leading, spacing: 10) {
          preview("Before", data: change.before.data)
          preview("After", data: change.after.data)
        }
        .padding(.top, 4)
        .padding(.bottom, 8)
      }
      .padding(.vertical, 6)
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .overlay(alignment: .top) { EnigmaHairline() }
  }

  private func preview(_ title: String, data: Data?) -> some View {
    let shape = RoundedRectangle(cornerRadius: 8, style: .continuous)
    return VStack(alignment: .leading, spacing: 4) {
      Text(title.lowercased())
        .font(EnigmaTypography.mono(11))
        .foregroundStyle(palette.textTertiary.color)
        .accessibilityLabel(title)
      Text(data.flatMap { try? WorkspaceDocument.text(path: change.path, data: $0) }.map { String($0.prefix(12_000)) }
           ?? (data == nil ? "File does not exist" : "Binary file"))
        .font(EnigmaTypography.mono(11.5))
        .foregroundStyle(palette.textPrimary.color)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(10)
        .background(palette.surface.color, in: shape)
        .enigmaEdge(shape)
      if (data?.count ?? 0) > 12_000 {
        Text("Preview shortened. The full file is saved for Undo.")
          .font(EnigmaTypography.ui(11.5))
          .foregroundStyle(palette.textSecondary.color)
      }
    }
  }
}
