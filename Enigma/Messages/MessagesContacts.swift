import Contacts
import Foundation

struct MessagesContact: Sendable, Equatable {
  let name: String
  let phones: [String]
  let emails: [String]
  /// The phones labelled mobile or iPhone; a subset of `phones`.
  var mobilePhones: [String] = []
  var organization: String? = nil
  /// Contacts' label for each handle, such as mobile, home or work.
  var labels: [String: String] = [:]

  var handles: [String] { phones + emails }

  /// Handles in the order a new conversation prefers them: mobiles, other phones, then emails.
  var preferredHandles: [String] {
    var seen = Set<String>()
    return (mobilePhones + phones + emails).filter { seen.insert(MessagesHandle.key($0)).inserted }
  }

  /// What tells this card apart from another with the same name: company and labelled handles,
  /// led by the one a send would use, the handle of `latestChat` if there is one.
  func distinguishingDescription(latestChat: (handle: String, chatID: String)? = nil) -> String {
    let chatKey = latestChat.map { MessagesHandle.key($0.handle) }
    let handles = preferredHandles
    let listed = (handles.filter { MessagesHandle.key($0) == chatKey } + handles.filter { MessagesHandle.key($0) != chatKey })
      .map { handle in
        let text = labels[handle].map { "\($0) \(handle)" } ?? handle
        guard MessagesHandle.key(handle) == chatKey, let latestChat else { return text }
        return text + " (chat_id \(latestChat.chatID))"
      }
    let company = organization.flatMap { $0.isEmpty || $0 == name ? nil : " (\($0))" } ?? ""
    return "\(name)\(company): \(listed.joined(separator: ", "))"
  }

  /// Cards with the same name and exactly the same handles are one person saved twice, so
  /// they count once. Their mobile labels and other labels are combined, so which card
  /// Contacts lists first doesn't change the number chosen.
  static func mergingDuplicates(_ contacts: [MessagesContact]) -> [MessagesContact] {
    var merged: [MessagesContact] = []
    var indexes: [[String]: Int] = [:]
    for contact in contacts {
      let key = [contact.name.lowercased()] + Set(contact.handles.map(MessagesHandle.key)).sorted()
      guard let index = indexes[key] else { indexes[key] = merged.count; merged.append(contact); continue }
      let kept = merged[index]
      func own(_ handle: String) -> String {
        kept.handles.first { MessagesHandle.key($0) == MessagesHandle.key(handle) } ?? handle
      }
      let mobileKeys = Set(kept.mobilePhones.map(MessagesHandle.key))
      merged[index].mobilePhones += contact.mobilePhones.filter { !mobileKeys.contains(MessagesHandle.key($0)) }.map(own)
      for (handle, label) in contact.labels where merged[index].labels[own(handle)] == nil {
        merged[index].labels[own(handle)] = label
      }
      if kept.organization?.isEmpty ?? true { merged[index].organization = contact.organization }
    }
    return merged
  }
}

enum MessagesContactsAccess: String, Sendable, Equatable {
  case granted, denied
}

protocol MessagesContactDirectory: Sendable {
  /// Requests access the first time; afterwards reports the saved decision.
  func requestAccess() async -> MessagesContactsAccess
  func contacts() async throws -> [MessagesContact]
}

struct SystemContactDirectory: MessagesContactDirectory {
  func requestAccess() async -> MessagesContactsAccess {
    switch CNContactStore.authorizationStatus(for: .contacts) {
    case .authorized, .limited: return .granted
    case .notDetermined:
      let granted = (try? await CNContactStore().requestAccess(for: .contacts)) ?? false
      return granted ? .granted : .denied
    default: return .denied
    }
  }

  func contacts() async throws -> [MessagesContact] {
    try await Task.detached(priority: .userInitiated) {
      let keys = [CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
        CNContactOrganizationNameKey as CNKeyDescriptor, CNContactNicknameKey as CNKeyDescriptor,
        CNContactPhoneNumbersKey as CNKeyDescriptor, CNContactEmailAddressesKey as CNKeyDescriptor]
      var contacts: [MessagesContact] = []
      var localizedLabels: [String: String] = [:]
      try CNContactStore().enumerateContacts(with: CNContactFetchRequest(keysToFetch: keys)) { contact, _ in
        let formatted = CNContactFormatter.string(from: contact, style: .fullName)
        let name = [formatted, contact.nickname, contact.organizationName]
          .compactMap { $0 }.first { !$0.isEmpty }
        let phones = contact.phoneNumbers.map(\.value.stringValue)
        let mobiles = contact.phoneNumbers.filter {
          $0.label == CNLabelPhoneNumberMobile || $0.label == CNLabelPhoneNumberiPhone
        }.map(\.value.stringValue)
        let emails = contact.emailAddresses.map { $0.value as String }
        guard let name, !(phones.isEmpty && emails.isEmpty) else { return }
        var labels: [String: String] = [:]
        let labelled = contact.phoneNumbers.map { ($0.value.stringValue, $0.label) }
          + contact.emailAddresses.map { ($0.value as String, $0.label) }
        for (handle, label) in labelled {
          guard let label, labels[handle] == nil else { continue }
          let text = localizedLabels[label] ?? CNLabeledValue<NSString>.localizedString(forLabel: label)
          localizedLabels[label] = text
          if !text.isEmpty { labels[handle] = text }
        }
        contacts.append(MessagesContact(name: name, phones: phones, emails: emails, mobilePhones: mobiles,
          organization: contact.organizationName, labels: labels))
      }
      return contacts
    }.value
  }
}

/// Phone handles are stored in E.164 form while people type them in many local forms.
/// Comparing the last ten digits matches both without knowing the user's country.
enum MessagesHandle {
  static func key(_ handle: String) -> String {
    let trimmed = handle.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.contains("@") { return trimmed.lowercased() }
    let digits = trimmed.filter(\.isASCII).filter(\.isNumber)
    guard digits.count >= 7 else { return digits.isEmpty ? trimmed.lowercased() : String(digits) }
    return String(digits.suffix(10))
  }

  static func isAddress(_ text: String) -> Bool {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    if trimmed.contains("@") { return trimmed.range(of: #"^[^@\s]+@[^@\s]+\.[^@\s]+$"#, options: .regularExpression) != nil }
    let allowed = CharacterSet(charactersIn: "+0123456789 ()-.")
    return trimmed.unicodeScalars.allSatisfy(allowed.contains) && trimmed.filter(\.isNumber).count >= 3
  }
}

/// Resolves handles to names once per request. Without Contacts access, names are omitted.
actor MessagesNameBook {
  private let directory: any MessagesContactDirectory
  private var loaded: (access: MessagesContactsAccess, contacts: [MessagesContact], names: [String: String])?

  init(directory: any MessagesContactDirectory) { self.directory = directory }

  var access: MessagesContactsAccess { get async { await load().access } }

  func contacts() async -> [MessagesContact] { await load().contacts }

  func name(for handle: String?) async -> String? {
    guard let handle else { return nil }
    return await load().names[MessagesHandle.key(handle)]
  }

  private func load() async -> (access: MessagesContactsAccess, contacts: [MessagesContact], names: [String: String]) {
    if let loaded { return loaded }
    let access = await directory.requestAccess()
    let contacts = access == .granted ? ((try? await directory.contacts()) ?? []) : []
    var names: [String: String] = [:]
    for contact in contacts {
      for handle in contact.handles where names[MessagesHandle.key(handle)] == nil {
        names[MessagesHandle.key(handle)] = contact.name
      }
    }
    let result = (access, contacts, names)
    loaded = result
    return result
  }
}
