#!/usr/bin/env swift
// Manual integration test for AXActions.writeTextInBackground.
//
// Run from a terminal that has the Accessibility permission (System Settings
// → Privacy & Security → Accessibility) while some other app — VS Code, say —
// is frontmost:
//
//     swift scripts/background-write-test.swift
//
// It (a) opens Mail.app WITHOUT activating it and creates a compose window,
// (b) writes into the compose fields the same way `writeTextInBackground`
// does (settable check → AX set → read-back), (c) asserts the frontmost app
// never changed, and (d) asserts the subject text landed while the WebKit
// body correctly reports a verification failure (the fallback trigger). The
// compose is left open unsent; close it with "Don't Save" afterwards.
//
// The write logic is duplicated here (this script can't import the app's
// executable target); keep it in step with AXActions.writeTextInBackground.

import AppKit
import ApplicationServices

let marker = "Clicky background write \(Int(Date().timeIntervalSince1970))\n\nSecond paragraph — should land too."
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

guard AXIsProcessTrusted() else {
    print("FAIL  this process is not trusted for Accessibility — grant it to your terminal and rerun")
    exit(1)
}

let frontBefore = NSWorkspace.shared.frontmostApplication
print("frontmost before: \(frontBefore?.localizedName ?? "?")")

// (a) Launch Mail in the background — `activates = false` is the whole point.
let mailID = "com.apple.mail"
if NSRunningApplication.runningApplications(withBundleIdentifier: mailID).isEmpty {
    let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: mailID)!
    let config = NSWorkspace.OpenConfiguration()
    config.activates = false
    config.hides = false
    let group = DispatchGroup(); group.enter()
    NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in group.leave() }
    group.wait()
    Thread.sleep(forTimeInterval: 2)
}
guard let mail = NSRunningApplication.runningApplications(withBundleIdentifier: mailID).first else {
    print("FAIL  Mail didn't launch"); exit(1)
}

// A compose window via a mailto: URL opened in the background (no Apple
// Events → no Automation permission prompt, and Mail is not activated).
let subject = "Clicky background write test"
var components = URLComponents(string: "mailto:")!
components.queryItems = [URLQueryItem(name: "subject", value: subject)]
let openConfig = NSWorkspace.OpenConfiguration()
openConfig.activates = false
let openGroup = DispatchGroup(); openGroup.enter()
var openError: Error?
NSWorkspace.shared.open([components.url!], withApplicationAt: mail.bundleURL!, configuration: openConfig) { _, error in
    openError = error; openGroup.leave()
}
openGroup.wait()
check(openError == nil, "opened a Mail compose window via mailto: in the background \(openError.map { "(\($0))" } ?? "")")
Thread.sleep(forTimeInterval: 2)

// Locate the two fields in the window titled with our subject: the subject
// (a native AXTextField — should accept a background write) and the body (a
// WebKit AXWebArea — expected to accept the call and ignore it, which is the
// `.verificationFailed` case that must trigger the focus-and-return fallback).
let appElement = AXUIElementCreateApplication(mail.processIdentifier)
let windows = attribute(appElement, kAXWindowsAttribute) as? [AXUIElement] ?? []
let compose = windows.first { (attribute($0, kAXTitleAttribute) as? String)?.contains(subject) == true }
guard let compose,
      let subjectField = search(compose, matches: {
          (attribute($0, kAXRoleAttribute) as? String) == kAXTextFieldRole
              && (attribute($0, kAXValueAttribute) as? String)?.contains(subject) == true
      }),
      let body = search(compose, matches: { (attribute($0, kAXRoleAttribute) as? String) == "AXWebArea" }) else {
    print("FAIL  couldn't find the compose subject field and body in the AX tree"); exit(1)
}

func normalized(_ text: String) -> String {
    text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
}

/// Mirrors AXActions.writeTextInBackground: settable? → set → read back.
/// Returns (setSucceeded, readBackMatches).
func backgroundWrite(_ element: AXUIElement, _ text: String) -> (set: Bool, verified: Bool) {
    var settable: DarwinBoolean = false
    guard AXUIElementIsAttributeSettable(element, kAXValueAttribute as CFString, &settable) == .success,
          settable.boolValue else { return (false, false) }
    guard AXUIElementSetAttributeValue(element, kAXValueAttribute as CFString, text as CFString) == .success else {
        return (false, false)
    }
    let readBack = normalized(attribute(element, kAXValueAttribute) as? String ?? "")
    return (true, readBack == normalized(text))
}

// (b)+(d) Subject: native field, the write must land and verify.
let newSubject = "\(subject) — \(Int(Date().timeIntervalSince1970))"
let subjectResult = backgroundWrite(subjectField, newSubject)
check(subjectResult.set, "subject (AXTextField): AXValue settable and set returned .success")
check(subjectResult.verified, "subject (AXTextField): read-back matches → .success")

// Body: web content. The set "succeeds" but is ignored — the read-back must
// catch that so the caller falls back instead of silently losing the text.
let bodyResult = backgroundWrite(body, marker)
check(bodyResult.set, "body (AXWebArea): set call accepted (this is the misleading part)")
check(!bodyResult.verified, "body (AXWebArea): read-back does NOT match → .verificationFailed, fallback required")
if bodyResult.verified { print("       unexpected: WebKit body accepted a raw AX value set — the isWebContent guard may be unnecessary for Mail") }

// (c) Nothing came forward.
Thread.sleep(forTimeInterval: 0.5)
let frontAfter = NSWorkspace.shared.frontmostApplication
check(frontBefore?.processIdentifier == frontAfter?.processIdentifier,
      "frontmost app unchanged (\(frontAfter?.localizedName ?? "?"))")
check(!mail.isActive, "Mail is not the active app")

print(failures == 0 ? "\nALL PASSED — close the test compose with Don't Save." : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
