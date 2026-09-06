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

    /// Reports whether Contacts is readable right now, and triggers the
    /// system prompt when it has never been asked — but never waits for it.
    ///
    /// `CNContactStore.requestAccess` is a completion-handler bridge that
    /// ignores cancellation, so awaiting it can suspend forever: if TCC
    /// decides not to show the prompt (this app is rebuilt and reinstalled
    /// constantly, and TCC keys off the code signature) the continuation is
    /// simply never resumed. Racing it against a timeout doesn't help either
    /// — a task group waits for every child before it returns, cancelled or
    /// not. So the prompt is kicked off and the caller is told to try again,
    /// which costs one repeated sentence instead of a wedged assistant.
    static func requestAccess() -> AccessResult {
        switch CNContactStore.authorizationStatus(for: .contacts) {
        case .authorized, .limited: return .granted
        case .denied, .restricted: return .denied
        default:
            CNContactStore().requestAccess(for: .contacts) { _, _ in }
            return .noAnswer
        }
    }

    enum AccessResult { case granted, denied, noAnswer }

    enum LookupError: LocalizedError {
        case denied
        case noAnswer
        var errorDescription: String? {
            switch self {
            case .denied:
                "MyClicky needs Contacts access to look up a number — turn it on in "
                + "System Settings ▸ Privacy & Security ▸ Contacts, then try again."
            case .noAnswer:
                "Approve the Contacts prompt on screen (or switch MyClicky on under "
                + "System Settings ▸ Privacy & Security ▸ Contacts), then say that again."
            }
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
        switch requestAccess() {
        case .granted: break
        case .denied: throw LookupError.denied
        case .noAnswer: throw LookupError.noAnswer
        }

        let store = CNContactStore()
        // The formatter reads more than given/family (middle name, prefix,
        // suffix, phonetic names…) and raises an ObjC exception for any key
        // that wasn't fetched. On the main thread that exception is caught by
        // NSApplication's run loop and merely logged, which abandons this
        // task mid-flight: the caller awaits forever and the assistant hangs
        // with no error. Asking the formatter for its own key list is the
        // only safe way to know what it will touch.
        let keys: [CNKeyDescriptor] = [
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
        ]
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
        //
        // Mobile-ness is precomputed and the comparator reads it. The previous
        // version ignored its second argument, which is not a strict weak
        // ordering — Swift's sort is free to misbehave on one, and it also
        // re-scanned every contact on every comparison.
        let mobiles: Set<String> = Set(contacts.flatMap { contact in
            contact.phoneNumbers
                .filter { $0.label == CNLabelPhoneNumberiPhone || $0.label == CNLabelPhoneNumberMobile }
                .map(\.value.stringValue)
        })
        return matches.sorted { a, b in
            let aMobile = mobiles.contains(a.number)
            let bMobile = mobiles.contains(b.number)
            return aMobile != bMobile ? aMobile : false
        }
    }

    private static func looksLikePhoneNumber(_ text: String) -> Bool {
        let digits = text.filter(\.isNumber)
        return digits.count >= 7 && text.allSatisfy { $0.isNumber || " +-()._".contains($0) }
    }

    /// Where a spoken name landed after lookup. `numbers(for:)` returns one
    /// row per phone number, so a single person with a mobile and a home line
    /// comes back as two — that isn't ambiguity, it's a person with two
    /// numbers, and the mobile (already sorted first) is the one to text.
    enum Resolution {
        case none
        case one(Match)
        /// Several distinct people — one representative number each, mobile-first.
        case several([Match])
    }

    static func resolve(_ matches: [Match], spoken query: String) -> Resolution {
        guard !matches.isEmpty else { return .none }
        // Distinct people, keeping the first (mobile-first) number for each.
        var people: [Match] = []
        var seen: Set<String> = []
        for match in matches where seen.insert(normalize(match.name)).inserted {
            people.append(match)
        }
        if people.count == 1 { return .one(people[0]) }
        // "Dad" matches both "Dad" and "Dino Dad"; the one that IS the spoken
        // name, rather than merely containing it, is what was meant.
        let wanted = normalize(query)
        let exact = people.filter { normalize($0.name) == wanted }
        if exact.count == 1 { return .one(exact[0]) }
        return .several(people)
    }

    private static func normalize(_ name: String) -> String {
        name.lowercased()
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .joined(separator: " ")
    }
}
