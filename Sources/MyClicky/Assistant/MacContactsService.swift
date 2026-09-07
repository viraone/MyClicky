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
        let exact = (try? store.unifiedContacts(
            matching: CNContact.predicateForContacts(matchingName: trimmed), keysToFetch: keys
        )) ?? []
        // Nothing matched what the recognizer heard? "Dino Dan" for "Dino Dad"
        // and "Dan dad" for the same person were both observed live; names
        // are exactly where speech recognition is weakest, so look for the
        // contacts that sound closest before giving up.
        let contacts = exact.isEmpty ? fuzzyContacts(like: trimmed, store: store, keys: keys) : exact

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

    /// Contacts (with phone numbers) whose names are close to what was
    /// heard: the best-scoring name, plus any within a whisker of it so a
    /// genuine toss-up ("Dan dad": Dad or Dino Dad?) is asked about rather
    /// than guessed. Empty when nothing is convincingly close.
    static func fuzzyContacts(like spoken: String, store: CNContactStore, keys: [CNKeyDescriptor]) -> [CNContact] {
        let request = CNContactFetchRequest(keysToFetch: keys)
        request.unifyResults = true
        var scored: [(contact: CNContact, score: Double)] = []
        try? store.enumerateContacts(with: request) { contact, _ in
            guard !contact.phoneNumbers.isEmpty else { return }
            let name = CNContactFormatter.string(from: contact, style: .fullName) ?? contact.organizationName
            let score = nameSimilarity(spoken, name)
            if score >= 0.6 { scored.append((contact, score)) }
        }
        guard let best = scored.map(\.score).max() else { return [] }
        return scored.filter { $0.score >= best - 0.12 }.sorted { $0.score > $1.score }.map(\.contact)
    }

    /// 0…1. The better of: the whole names compared as one string, and the
    /// average of each spoken word matched to its closest word in the name
    /// (and back, so "Dad" isn't a perfect match for "Dan Dad Smith").
    static func nameSimilarity(_ spoken: String, _ name: String) -> Double {
        let a = normalize(spoken), b = normalize(name)
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        let whole = ratio(a.replacingOccurrences(of: " ", with: ""), b.replacingOccurrences(of: " ", with: ""))
        let aw = a.split(separator: " ").map(String.init), bw = b.split(separator: " ").map(String.init)
        func side(_ xs: [String], _ ys: [String]) -> Double {
            xs.map { x in ys.map { ratio(x, $0) }.max() ?? 0 }.reduce(0, +) / Double(xs.count)
        }
        return max(whole, (side(aw, bw) + side(bw, aw)) / 2)
    }

    private static func ratio(_ a: String, _ b: String) -> Double {
        let n = max(a.count, b.count)
        return n == 0 ? 1 : 1 - Double(levenshtein(a, b)) / Double(n)
    }

    private static func levenshtein(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count), cur = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            cur[0] = i
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }

    /// Every email address belonging to a contact whose name matches `query`
    /// — the Gmail fallback for people who live in the Mac address book but
    /// not in Google Contacts. An address spoken directly passes straight
    /// through.
    static func emails(for query: String) async throws -> [ContactsService.Match] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        if trimmed.contains("@"), !trimmed.contains(" ") {
            return [ContactsService.Match(name: "", email: trimmed)]
        }
        switch requestAccess() {
        case .granted: break
        case .denied: throw LookupError.denied
        case .noAnswer: throw LookupError.noAnswer
        }

        let store = CNContactStore()
        let keys: [CNKeyDescriptor] = [
            CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
            CNContactOrganizationNameKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
        ]
        let contacts = (try? store.unifiedContacts(
            matching: CNContact.predicateForContacts(matchingName: trimmed), keysToFetch: keys
        )) ?? []

        var seen: Set<String> = []
        var matches: [ContactsService.Match] = []
        for contact in contacts {
            let name = CNContactFormatter.string(from: contact, style: .fullName)
                ?? contact.organizationName
            for entry in contact.emailAddresses {
                let email = (entry.value as String).trimmingCharacters(in: .whitespacesAndNewlines)
                guard !email.isEmpty, seen.insert(email.lowercased()).inserted else { continue }
                matches.append(ContactsService.Match(name: name ?? "", email: email))
            }
        }
        return matches
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

    static func normalize(_ name: String) -> String {
        name.lowercased()
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .joined(separator: " ")
    }
}
