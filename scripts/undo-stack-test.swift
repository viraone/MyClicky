#!/usr/bin/env swift
// Manual integration test for the background-write undo flow
// (AXActions.writeTextInBackground → WriteUndoStack.undoLast).
//
// Run from a terminal that has the Accessibility permission while Messages
// has a conversation open and some OTHER app is frontmost:
//
//     swift scripts/undo-stack-test.swift
//
// It (a) reads what the compose box holds, (b) writes a marker into it the
// way `writeTextInBackground` does (previous → set → read-back, deciding
// .success vs .suspectedNoop), (c) writes the same marker again and expects
// the no-op verdict, (d) "undoes" by writing the original value back through
// the same path, and (e) asserts the frontmost app never changed and the box
// ends exactly as it started. Nothing is sent.
//
// The write logic is duplicated here (this script can't import the app's
// executable target); keep it in step with AXActions.writeTextInBackground.

import AppKit
import ApplicationServices

var failures = 0
func check(_ ok: Bool, _ what: String) {
    print("\(ok ? "PASS" : "FAIL")  \(what)")
    if !ok { failures += 1 }
}
func attribute(_ element: AXUIElement, _ name: String) -> AnyObject? {
    var value: AnyObject?
    guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
    return value
}
func search(_ element: AXUIElement, depth: Int = 0, matches: (AXUIElement) -> Bool) -> AXUIElement? {
    if depth > 40 { return nil }
    if matches(element) { return element }
    for child in attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? [] {
        if let found = search(child, depth: depth + 1, matches: matches) { return found }
    }
    return nil
}

enum Result: String { case success, suspectedNoop, verificationFailed, elementNotWritable }

/// Mirrors AXActions.writeTextInBackground: previous → settable? → set → read back.
func write(_ element: AXUIElement, _ text: String) -> (Result, previous: String) {
    var settable: DarwinBoolean = false
    guard AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success,
          settable.boolValue else { return (.elementNotWritable, "") }
    let previous = attribute(element, kAXValueAttribute) as? String ?? ""
    guard AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, text as CFString) == .success else {
        return (.elementNotWritable, previous)
    }
    let readBack = attribute(element, kAXValueAttribute) as? String ?? ""
    guard readBack == text else { return (.verificationFailed, previous) }
    return (previous == text ? .suspectedNoop : .success, previous)
}

guard AXIsProcessTrusted() else {
    print("FAIL  this process is not trusted for Accessibility — grant it to your terminal and rerun")
    exit(1)
}
guard let messages = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MobileSMS").first else {
    print("FAIL  Messages isn't running"); exit(1)
}
let frontBefore = NSWorkspace.shared.frontmostApplication
print("frontmost before: \(frontBefore?.localizedName ?? "?")")
check(frontBefore?.processIdentifier != messages.processIdentifier, "Messages is NOT the frontmost app (put another app in front)")

let app = AXUIElementCreateApplication(messages.processIdentifier)
let placeholders = ["iMessage", "Text Message", "SMS", "Message"]
guard let compose = search(app, matches: { element in
    guard let role = attribute(element, kAXRoleAttribute) as? String,
          role == kAXTextAreaRole || role == kAXTextFieldRole else { return false }
    let hints = [kAXPlaceholderValueAttribute, kAXDescriptionAttribute, kAXTitleAttribute]
        .compactMap { attribute(element, $0) as? String }
    return hints.contains { hint in placeholders.contains { hint.localizedCaseInsensitiveContains($0) } }
}) else {
    print("FAIL  no compose box in Messages' AX tree — is a conversation open?"); exit(1)
}

let original = attribute(compose, kAXValueAttribute) as? String ?? ""
print("compose box holds: \"\(original)\"")

// (b) A real change — the entry the undo stack would push.
let marker = "Clicky undo test \(Int(Date().timeIntervalSince1970))"
let first = write(compose, marker)
check(first.0 == .success, "first write: .success (was: \(first.0.rawValue)); stack entry previous=\"\(first.previous)\"")
check(first.previous == original, "snapshotted previous value equals what the box held")
usleep(300_000)

// (c) The same text again — nothing changes, must NOT be reported as a fresh write.
let again = write(compose, marker)
check(again.0 == .suspectedNoop, "identical rewrite: .suspectedNoop (was: \(again.0.rawValue)) — not pushed")
usleep(300_000)

// (d) Undo: previous value back through the same path, verified.
let undo = write(compose, first.previous)
check(undo.0 == .success || (undo.0 == .suspectedNoop && first.previous == marker),
      "undo write-back landed (\(undo.0.rawValue))")
let after = attribute(compose, kAXValueAttribute) as? String ?? ""
check(after == original, "compose box restored to its original text (\"\(after)\")")

// (e) No focus theft anywhere along the way.
let frontAfter = NSWorkspace.shared.frontmostApplication
check(frontBefore?.processIdentifier == frontAfter?.processIdentifier,
      "frontmost app unchanged (\(frontAfter?.localizedName ?? "?"))")

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILURE(S)")
exit(failures == 0 ? 0 : 1)
