import Foundation

/// JavaScript source for the browser agent, run inside the active Chrome tab
/// through `BrowserTabReader.runJavaScriptAsync`.
///
/// Every function returns one self-contained expression — an IIFE that answers
/// a JSON string. Anything the page throws is caught and answered as
/// `{"error": "..."}` so a broken page never looks like a refused Apple Event,
/// and no returned script is longer than `maxScriptLength`. The scripts use
/// plain ES2019 DOM APIs only: no libraries, no app UI, no AppleScript.
enum BrowserAgentScripts {
    /// The longest script this type will ever return.
    static let maxScriptLength = 24_000

    // MARK: - Snapshot

    /// Every visible interactive element on the page, each tagged with a
    /// stable `data-peeky-id` the other scripts use, plus the page's opening
    /// text. Sensitive fields are listed but their values are never read.
    static func snapshot() -> String {
        capped(#"""
        (() => {
          const out = (value) => JSON.stringify(value);
          try {
            const LIMIT = 120;
            const ROLES = {"button": true, "link": true, "checkbox": true, "radio": true, "tab": true, "menuitem": true, "option": true, "switch": true};
        \#(cleanJS)
        \#(sensitiveJS)

            const roleOf = (el) => {
              const explicit = clean(el.getAttribute("role")).toLowerCase();
              if (explicit) return explicit;
              const tag = el.tagName.toLowerCase();
              if (tag === "a" && el.hasAttribute("href")) return "link";
              if (tag === "button" || tag === "summary") return "button";
              if (tag === "textarea") return "textbox";
              if (tag === "select") return "combobox";
              if (tag === "input") {
                const type = (el.type || "text").toLowerCase();
                if (type === "checkbox" || type === "radio") return type;
                if (type === "submit" || type === "button" || type === "reset" || type === "image") return "button";
                if (type === "search") return "searchbox";
                return "textbox";
              }
              return "";
            };

            const isInteractive = (el) => {
              const tag = el.tagName.toLowerCase();
              if (tag === "a" && el.hasAttribute("href")) return true;
              if (tag === "button" || tag === "select" || tag === "textarea" || tag === "summary") return true;
              if (tag === "input") return (el.getAttribute("type") || "").toLowerCase() !== "hidden";
              const role = (el.getAttribute("role") || "").toLowerCase();
              if (ROLES[role] === true) return true;
              if (el.hasAttribute("onclick")) return true;
              if ((el.getAttribute("contenteditable") || "").toLowerCase() === "true") return true;
              return false;
            };

            const isVisible = (el) => {
              if (el.closest && el.closest('[aria-hidden="true"]')) return false;
              const rect = el.getBoundingClientRect();
              if (!rect || rect.width <= 0 || rect.height <= 0) return false;
              const style = window.getComputedStyle(el);
              if (!style) return true;
              if (style.display === "none") return false;
              if (style.visibility === "hidden" || style.visibility === "collapse") return false;
              return true;
            };

            let counter = parseInt(window.__peekyNext, 10);
            if (!isFinite(counter) || counter < 1) counter = 1;

            const nextId = () => {
              while (document.querySelector('[data-peeky-id="' + counter + '"]')) counter += 1;
              const id = counter;
              counter += 1;
              window.__peekyNext = counter;
              return id;
            };

            const idOf = (el) => {
              const existing = el.getAttribute("data-peeky-id");
              if (existing != null && /^\d+$/.test(existing)) {
                const id = parseInt(existing, 10);
                if (id >= counter) {
                  counter = id + 1;
                  window.__peekyNext = counter;
                }
                return id;
              }
              const id = nextId();
              el.setAttribute("data-peeky-id", String(id));
              return id;
            };

            const textOf = (el, sensitive) => {
              const label = clean(el.getAttribute("aria-label"));
              if (label) return label.slice(0, 80);
              let text = sensitive ? "" : clean(el.innerText);
              if (!text && !sensitive && typeof el.value === "string") text = clean(el.value);
              if (!text) text = clean(el.getAttribute("title"));
              if (!text) text = clean(el.getAttribute("alt"));
              return text.slice(0, 80);
            };

            const record = (el) => {
              const tag = el.tagName.toLowerCase();
              const sensitive = isSensitive(el);
              const rect = el.getBoundingClientRect();
              const type = typeof el.type === "string" ? el.type.toLowerCase() : clean(el.getAttribute("type")).toLowerCase();
              return {
                id: idOf(el),
                tag: tag,
                role: roleOf(el),
                type: type,
                text: textOf(el, sensitive),
                name: clean(el.getAttribute("name")).slice(0, 80),
                placeholder: clean(el.getAttribute("placeholder")).slice(0, 80),
                href: tag === "a" && el.hasAttribute("href") ? clean(el.href || el.getAttribute("href")).slice(0, 120) : "",
                value: sensitive ? "" : clean(el.value).slice(0, 80),
                checked: !!el.checked,
                disabled: !!el.disabled || el.getAttribute("aria-disabled") === "true",
                inViewport: rect.bottom > 0 && rect.right > 0 && rect.top < window.innerHeight && rect.left < window.innerWidth,
                sensitive: sensitive
              };
            };

            const elements = [];
            const visit = (root) => {
              const all = root.querySelectorAll("*");
              for (let i = 0; i < all.length; i += 1) {
                if (elements.length >= LIMIT) return;
                const el = all[i];
                if (isInteractive(el) && isVisible(el)) elements.push(record(el));
                if (el.shadowRoot) visit(el.shadowRoot);
              }
            };
            visit(document);

            const pageText = (document.body && document.body.innerText ? document.body.innerText : "")
              .replace(/\n\s*\n\s*\n+/g, "\n\n")
              .trim()
              .slice(0, 2500);

            return out({
              url: location.href,
              title: document.title,
              scrollY: window.scrollY,
              scrollHeight: Math.max(
                document.documentElement ? document.documentElement.scrollHeight : 0,
                document.body ? document.body.scrollHeight : 0
              ),
              viewportHeight: window.innerHeight,
              elements: elements,
              pageText: pageText
            });
          } catch (err) {
            return out({error: String((err && err.message) || err)});
          }
        })()
        """#)
    }

    // MARK: - Describe

    /// Details of the element a snapshot gave the id `id`.
    static func describe(id: Int) -> String {
        capped(#"""
        (() => {
          const out = (value) => JSON.stringify(value);
          try {
        \#(cleanJS)
        \#(sensitiveJS)
        \#(findJS)
        \#(describeInfoJS)

            const el = find(\#(id));
            if (!el) return out(missing());
            return out(info(el));
          } catch (err) {
            return out({error: String((err && err.message) || err)});
          }
        })()
        """#)
    }

    /// The same details for `document.activeElement`. `found` is false when
    /// focus is nowhere (body or the document root).
    static func describeActive() -> String {
        capped(#"""
        (() => {
          const out = (value) => JSON.stringify(value);
          try {
        \#(cleanJS)
        \#(sensitiveJS)
        \#(describeInfoJS)

            let el = document.activeElement;
            while (el && el.shadowRoot && el.shadowRoot.activeElement) el = el.shadowRoot.activeElement;
            if (!el || el === document.body || el === document.documentElement) return out(missing());
            return out(info(el));
          } catch (err) {
            return out({error: String((err && err.message) || err)});
          }
        })()
        """#)
    }

    // MARK: - Actions

    /// Scrolls an element to the middle of the viewport, then sends the five
    /// mouse events a real click would. A dispatched `click` runs the
    /// element's activation behaviour itself, so `el.click()` is not called
    /// a second time (that would fire handlers twice and cancel the effect
    /// of a checkbox).
    static func click(id: Int) -> String {
        capped(#"""
        (() => {
          const out = (value) => JSON.stringify(value);
          try {
        \#(cleanJS)
        \#(sensitiveJS)
        \#(findJS)

            const el = find(\#(id));
            if (!el) return out({ok: false, error: "no element with id \#(id)"});
            el.scrollIntoView({block: "center", inline: "center", behavior: "instant"});
            const rect = el.getBoundingClientRect();
            const x = rect.left + rect.width / 2;
            const y = rect.top + rect.height / 2;
            const detail = {bubbles: true, cancelable: true, view: window, button: 0, clientX: x, clientY: y};
            const pressed = Object.assign({}, detail, {buttons: 1});
            el.dispatchEvent(new PointerEvent("pointerdown", Object.assign({}, pressed, {pointerId: 1, pointerType: "mouse", isPrimary: true})));
            el.dispatchEvent(new MouseEvent("mousedown", pressed));
            el.dispatchEvent(new PointerEvent("pointerup", Object.assign({}, detail, {pointerId: 1, pointerType: "mouse", isPrimary: true})));
            el.dispatchEvent(new MouseEvent("mouseup", detail));
            el.dispatchEvent(new MouseEvent("click", detail));
            const sensitive = isSensitive(el);
            const label = clean(el.getAttribute("aria-label"))
              || (sensitive ? "" : clean(el.innerText))
              || clean(el.getAttribute("title"))
              || clean(el.getAttribute("alt"));
            return out({ok: true, clicked: (el.tagName.toLowerCase() + " " + label).trim().slice(0, 100)});
          } catch (err) {
            return out({error: String((err && err.message) || err)});
          }
        })()
        """#)
    }

    /// Types into an input, textarea or contenteditable element. Inputs go
    /// through the prototype's native value setter so React and Vue notice;
    /// an input then a change event follow. Sensitive fields are refused.
    static func typeText(id: Int, text: String, clear: Bool) -> String {
        // A field should never receive more than a paragraph or two; keeping
        // the argument small also keeps the whole script under the cap even
        // after JSON escaping.
        let value = String(text.prefix(8_000))
        return capped(#"""
        (() => {
          const out = (value) => JSON.stringify(value);
          try {
        \#(findJS)
        \#(sensitiveJS)

            const TEXT = \#(jsString(value));
            const CLEAR = \#(clear);
            const el = find(\#(id));
            if (!el) return out({ok: false, error: "no element with id \#(id)"});
            if (isSensitive(el)) return out({ok: false, error: "sensitive field"});
            el.focus();
            const tag = el.tagName.toLowerCase();
            if (tag === "input" || tag === "textarea") {
              const proto = tag === "textarea" ? window.HTMLTextAreaElement.prototype : window.HTMLInputElement.prototype;
              const descriptor = Object.getOwnPropertyDescriptor(proto, "value");
              const current = typeof el.value === "string" ? el.value : "";
              const next = (CLEAR ? "" : current) + TEXT;
              if (descriptor && descriptor.set) descriptor.set.call(el, next);
              else el.value = next;
              el.dispatchEvent(new Event("input", {bubbles: true}));
              el.dispatchEvent(new Event("change", {bubbles: true}));
              return out({ok: true});
            }
            if (el.isContentEditable) {
              const selection = window.getSelection();
              if (selection) {
                const range = document.createRange();
                range.selectNodeContents(el);
                if (!CLEAR) range.collapse(false);
                selection.removeAllRanges();
                selection.addRange(range);
              }
              const inserted = document.execCommand("insertText", false, TEXT);
              if (!inserted) return out({ok: false, error: "insert failed"});
              return out({ok: true});
            }
            return out({ok: false, error: "not editable"});
          } catch (err) {
            return out({error: String((err && err.message) || err)});
          }
        })()
        """#)
    }

    /// Presses one of the agent's supported keys on the focused element,
    /// falling back to body. Enter on an input inside a form submits the
    /// form when the page did not cancel the keydown itself.
    static func pressKey(_ key: String) -> String {
        guard let spec = keySpec(for: key) else { return errorScript("unsupported key") }
        return capped(#"""
        (() => {
          const out = (value) => JSON.stringify(value);
          try {
            const KEY = \#(jsString(spec.key));
            const CODE = \#(jsString(spec.code));
            const KEY_CODE = \#(spec.keyCode);
            const CHAR_CODE = \#(spec.charCode);
            const SEND_KEYPRESS = \#(spec.sendsKeypress);
        \#(keyTargetJS)
            if (!target) return out({ok: false, error: "no active element"});
            const init = {bubbles: true, cancelable: true, view: window, key: KEY, code: CODE, keyCode: KEY_CODE, which: KEY_CODE};
            const down = new KeyboardEvent("keydown", init);
            const prevented = !target.dispatchEvent(down);
            if (SEND_KEYPRESS) {
              target.dispatchEvent(new KeyboardEvent("keypress", {bubbles: true, cancelable: true, view: window, key: KEY, code: CODE, keyCode: KEY_CODE, which: KEY_CODE, charCode: CHAR_CODE}));
            }
            target.dispatchEvent(new KeyboardEvent("keyup", init));
            if (!prevented && KEY === "Enter" && target.tagName.toLowerCase() === "input") {
              const form = target.form || (target.closest ? target.closest("form") : null);
              if (form && typeof form.requestSubmit === "function") {
                try { form.requestSubmit(); } catch (err) {}
              }
            }
            return out({ok: true});
          } catch (err) {
            return out({error: String((err && err.message) || err)});
          }
        })()
        """#)
    }

    // MARK: - Page movement

    /// Scrolls by a fraction of the viewport, or to the top or bottom.
    static func scroll(direction: String, amount: Double = 0.8) -> String {
        let dir = direction.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let fraction = amount.isFinite ? min(max(amount, 0.0), 5.0) : 0.8
        return capped(#"""
        (() => {
          const out = (value) => JSON.stringify(value);
          try {
            const DIRECTION = \#(jsString(dir));
            const AMOUNT = \#(fraction);
            const pageHeight = () => Math.max(
              document.documentElement ? document.documentElement.scrollHeight : 0,
              document.body ? document.body.scrollHeight : 0
            );
            const step = Math.round(window.innerHeight * AMOUNT);
            let top = window.scrollY;
            if (DIRECTION === "up") top = Math.max(0, window.scrollY - step);
            else if (DIRECTION === "down") top = window.scrollY + step;
            else if (DIRECTION === "top") top = 0;
            else if (DIRECTION === "bottom") top = pageHeight();
            else return out({ok: false, error: "unknown direction"});
            window.scrollTo({top: top, left: window.scrollX, behavior: "instant"});
            return out({scrollY: window.scrollY, scrollHeight: pageHeight(), viewportHeight: window.innerHeight});
          } catch (err) {
            return out({error: String((err && err.message) || err)});
          }
        })()
        """#)
    }

    /// The visible text of the page, cut to `maxChars` characters.
    static func getText(maxChars: Int = 6_000) -> String {
        let limit = max(1, min(maxChars, 200_000))
        return capped(#"""
        (() => {
          const out = (value) => JSON.stringify(value);
          try {
            const LIMIT = \#(limit);
            const body = document.body;
            const text = body && typeof body.innerText === "string" ? body.innerText.trim() : "";
            return out({text: text.slice(0, LIMIT)});
          } catch (err) {
            return out({error: String((err && err.message) || err)});
          }
        })()
        """#)
    }

    /// Where the element's centre is on screen, in screen points with a
    /// top-left origin, after scrolling it into view. The browser chrome
    /// above the viewport is `outerHeight - innerHeight`.
    static func centerOnScreen(id: Int) -> String {
        capped(#"""
        (() => {
          const out = (value) => JSON.stringify(value);
          try {
        \#(findJS)

            const el = find(\#(id));
            if (!el) return out({ok: false, error: "no element with id \#(id)"});
            el.scrollIntoView({block: "center", inline: "center", behavior: "instant"});
            const rect = el.getBoundingClientRect();
            return out({
              ok: true,
              x: window.screenX + rect.left + rect.width / 2,
              y: window.screenY + (window.outerHeight - window.innerHeight) + rect.top + rect.height / 2
            });
          } catch (err) {
            return out({error: String((err && err.message) || err)});
          }
        })()
        """#)
    }

    /// Back, forward or reload the active tab.
    static func history(direction: String) -> String {
        let dir = direction.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return capped(#"""
        (() => {
          const out = (value) => JSON.stringify(value);
          try {
            const DIRECTION = \#(jsString(dir));
            if (DIRECTION === "back") window.history.back();
            else if (DIRECTION === "forward") window.history.forward();
            else if (DIRECTION === "reload") location.reload();
            else return out({ok: false, error: "unknown direction"});
            return out({ok: true});
          } catch (err) {
            return out({error: String((err && err.message) || err)});
          }
        })()
        """#)
    }

    // MARK: - Embedding Swift strings

    /// `value` as a JavaScript string literal: quotes, backslashes, newlines
    /// and unicode are JSON-encoded, so the page can never read the argument
    /// as code. U+2028/U+2029 are escaped too, freeing the literal from older
    /// JavaScript line-terminator rules.
    static func jsString(_ value: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed]),
              let literal = String(data: data, encoding: .utf8) else {
            return "\"\""
        }
        return literal
            .replacingOccurrences(of: "\u{2028}", with: "\\u2028")
            .replacingOccurrences(of: "\u{2029}", with: "\\u2029")
    }

    // MARK: - Shared JavaScript

    /// Collapses any attribute or property into one trimmed line.
    private static let cleanJS = #"""
    const clean = (value) => String(value == null ? "" : value).replace(/\s+/g, " ").trim();
"""#

    /// The one rule that decides a field must never be read or written:
    /// password types, card autocomplete hints, and payment/identity names.
    private static let sensitiveJS = #"""
    const isSensitive = (el) => {
      if (String(el.type || "").toLowerCase() === "password") return true;
      if ((el.getAttribute("autocomplete") || "").toLowerCase().indexOf("cc-") !== -1) return true;
      const hay = [el.getAttribute("name"), el.id, el.getAttribute("placeholder"), el.getAttribute("aria-label")]
        .filter((value) => value != null).join(" ");
      return /card|cvv|cvc|security.?code|ssn|social.?security|routing|account.?number|iban/i.test(hay);
    };
"""#

    /// Finds a snapshotted element by its id, crossing open shadow roots.
    private static let findJS = #"""
    const find = (id) => {
      const want = String(id);
      const search = (root) => {
        if (root.querySelector) {
          const direct = root.querySelector('[data-peeky-id="' + want + '"]');
          if (direct) return direct;
        }
        const all = root.querySelectorAll ? root.querySelectorAll("*") : [];
        for (let i = 0; i < all.length; i += 1) {
          const host = all[i];
          if (host.shadowRoot) {
            const hit = search(host.shadowRoot);
            if (hit) return hit;
          }
        }
        return null;
      };
      return search(document);
    };
"""#

    /// `info(el)` and the not-found shape shared by both describe scripts.
    /// Relies on `clean` and `isSensitive` already being defined.
    private static let describeInfoJS = #"""
    const textOf = (el, sensitive) => {
      const label = clean(el.getAttribute("aria-label"));
      if (label) return label.slice(0, 80);
      let text = sensitive ? "" : clean(el.innerText);
      if (!text && !sensitive && typeof el.value === "string") text = clean(el.value);
      if (!text) text = clean(el.getAttribute("title"));
      if (!text) text = clean(el.getAttribute("alt"));
      return text.slice(0, 80);
    };

    const isSubmit = (el) => {
      const tag = el.tagName.toLowerCase();
      const type = (el.getAttribute("type") || "").toLowerCase();
      if (tag === "input") return type === "submit";
      if (tag === "button") {
        if (type === "submit") return true;
        if (type === "button" || type === "reset") return false;
        return !!(el.form || (el.closest && el.closest("form")));
      }
      return false;
    };

    const submitControl = (form) => {
      if (!form) return null;
      const controls = form.querySelectorAll("button, input");
      for (let i = 0; i < controls.length; i += 1) {
        const control = controls[i];
        const tag = control.tagName.toLowerCase();
        const type = (control.getAttribute("type") || "").toLowerCase();
        if (tag === "button" && (type === "submit" || type === "")) return control;
        if (tag === "input" && type === "submit") return control;
      }
      return null;
    };

    const editableOf = (el) => {
      const tag = el.tagName.toLowerCase();
      if (tag === "input" || tag === "textarea") return !el.disabled && !el.readOnly;
      if (tag === "select") return !el.disabled;
      return !!el.isContentEditable;
    };

    const info = (el) => {
      const tag = el.tagName.toLowerCase();
      const sensitive = isSensitive(el);
      const form = el.form || (el.closest ? el.closest("form") : null);
      const submitter = submitControl(form);
      const type = typeof el.type === "string" ? el.type.toLowerCase() : clean(el.getAttribute("type")).toLowerCase();
      return {
        found: true,
        tag: tag,
        type: type,
        text: textOf(el, sensitive),
        href: tag === "a" && el.hasAttribute("href") ? clean(el.href || el.getAttribute("href")).slice(0, 120) : "",
        sensitive: sensitive,
        isSubmit: isSubmit(el),
        formAction: form ? String(form.action || "").slice(0, 200) : "",
        formSubmitText: submitter ? textOf(submitter, isSensitive(submitter)) : "",
        editable: editableOf(el)
      };
    };

    const missing = () => ({
      found: false, tag: "", type: "", text: "", href: "", sensitive: false,
      isSubmit: false, formAction: "", formSubmitText: "", editable: false
    });
"""#

    /// The deepest focused element; a shadow host reports itself as
    /// `document.activeElement`, not the child that actually has focus.
    private static let keyTargetJS = #"""
    let target = document.activeElement;
    while (target && target.shadowRoot && target.shadowRoot.activeElement) target = target.shadowRoot.activeElement;
    if (!target || target === document.documentElement) target = document.body || document.documentElement;
"""#

    // MARK: - Helpers

    /// A script that answers one error object, for bad arguments and for the
    /// rare over-long script.
    private static func errorScript(_ message: String) -> String {
        #"""
        (() => {
          try {
            return JSON.stringify({error: \#(jsString(message))});
          } catch (err) {
            return '{"error":"script error"}';
          }
        })()
        """#
    }

    /// Refuses to hand back a script longer than `maxScriptLength`. Truncating
    /// the source would risk cutting a string or an expression in half, so an
    /// over-long script is replaced by a valid one that reports the problem.
    private static func capped(_ script: String) -> String {
        script.count <= maxScriptLength ? script : errorScript("script too long")
    }

    private struct KeySpec {
        let key: String
        let code: String
        let keyCode: Int
        let charCode: Int
        let sendsKeypress: Bool
    }

    /// Metadata for the keys the agent may press. Aliases are accepted so a
    /// model can say "return", "esc" or "down" without another round trip.
    private static func keySpec(for raw: String) -> KeySpec? {
        if raw == " " {
            return KeySpec(key: " ", code: "Space", keyCode: 32, charCode: 32, sendsKeypress: true)
        }
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch name {
        case "enter", "return":
            return KeySpec(key: "Enter", code: "Enter", keyCode: 13, charCode: 13, sendsKeypress: true)
        case "tab":
            return KeySpec(key: "Tab", code: "Tab", keyCode: 9, charCode: 0, sendsKeypress: false)
        case "escape", "esc":
            return KeySpec(key: "Escape", code: "Escape", keyCode: 27, charCode: 0, sendsKeypress: false)
        case "arrowdown", "down":
            return KeySpec(key: "ArrowDown", code: "ArrowDown", keyCode: 40, charCode: 0, sendsKeypress: false)
        case "arrowup", "up":
            return KeySpec(key: "ArrowUp", code: "ArrowUp", keyCode: 38, charCode: 0, sendsKeypress: false)
        case "arrowleft", "left":
            return KeySpec(key: "ArrowLeft", code: "ArrowLeft", keyCode: 37, charCode: 0, sendsKeypress: false)
        case "arrowright", "right":
            return KeySpec(key: "ArrowRight", code: "ArrowRight", keyCode: 39, charCode: 0, sendsKeypress: false)
        case "backspace":
            return KeySpec(key: "Backspace", code: "Backspace", keyCode: 8, charCode: 0, sendsKeypress: false)
        case "space", "spacebar":
            return KeySpec(key: " ", code: "Space", keyCode: 32, charCode: 32, sendsKeypress: true)
        default:
            return nil
        }
    }
}
