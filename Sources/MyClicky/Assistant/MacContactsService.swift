import Contacts
import Foundation

/// The Mac's own address book, for turning a spoken name into a phone number.
///
/// Distinct from `ContactsService`, which reads *Google* contacts for Gmail.
/// Messages takes its names from the macOS address book — "Dino Dad - Comedy"
/// is a card in Contacts.app, not a Google entry — so resolving a Messages
/// recipient against Google would miss most of them.
@MainActor
enum MacContactsService {

    struct Match: Hashable {
        let name: String
        let number: String
        var display: String { name.isEmpty ? number : "\(name) — \(number)" }
    }

    /// Asks once; afterwards macOS remembers the answer.
    static func requestAccess() async -> Bool {
        let store = CNContactStore()
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized, .limited: return true
        case .denied, .restricted: return false
        default:
            return (try? await store.requestAccess(for: .contacts)) ?? false
        }
    }

    enum LookupError: LocalizedError {
        case denied
        var errorDescription: String? {
            "MyClicky needs Contacts access to look up a number — "
            + "System Settings ▸ Privacy & Security ▸ Contacts."
        }
    }

    /// Every phone number belonging to a contact whose name matches `query`.
    /// A number spoken directly is passed straight through, since there's
    /// nothing to look up.
    static func numbers(for query: String) async throws -> [Match] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        if looksLikePhoneNumber(trimmed) {
            return [Match(name: "", number: trimmed)]
        }
        guard await requestAccess() else { throw LookupError.denied }

        let store = CNContactStore()
        let keys = [CNContactGivenNameKey, CNContactFamilyNameKey,
                    CNContactOrganizationNameKey, CNContactNicknameKey,
                    CNContactPhoneNumbersKey] as [CNKeyDescriptor]
        let contacts = (try? store.unifiedContacts(
            matching: CNContact.predicateForContacts(matchingName: trimmed), keysToFetch: keys
        )) ?? []

        var seen: Set<String> = []
        var matches: [Match] = []
        for contact in contacts {
            let name = CNContactFormatter.string(from: contact, style: .fullName)
                ?? contact.organizationName
            for phone in contact.phoneNumbers {
                let number = phone.value.stringValue
                let key = number.filter(\.isNumber)
                guard !key.isEmpty, seen.insert(key).inserted else { continue }
                matches.append(Match(name: name ?? "", number: number))
            }
        }
        // A mobile number is what a text should go to; a landline or fax
        // silently fails to deliver, so put mobiles first.
        return matches.sorted { a, _ in
            contacts.contains { contact in
                contact.phoneNumbers.contains { phone in
                    phone.value.stringValue == a.number
                        && (phone.label == CNLabelPhoneNumberiPhone || phone.label == CNLabelPhoneNumberMobile)
                }
            }
        }
    }

    private static func looksLikePhoneNumber(_ text: String) -> Bool {
        let digits = text.filter(\.isNumber)
        return digits.count >= 7 && text.allSatisfy { $0.isNumber || " +-()._".contains($0) }
    }
}
