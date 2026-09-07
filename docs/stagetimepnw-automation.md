# StageTimePNW automation — working with Clicky, Appium, and a mock backend

Repos:
- App: https://github.com/viraone/StageTimePNW (SwiftUI + Supabase Auth)
- Tests: https://github.com/viraone/StageTimePNW_Automation (pytest + Appium-Python-Client, XCUITest)

## 1. Two-screen layout + Clicky

**Screen 1 (main):** Xcode with `StageTimePNW.xcodeproj` open, iOS Simulator
(iPhone 17 Pro Max, iOS 26.5) next to it.

**Screen 2:** a Terminal split into three panes, plus Appium Inspector.

| Pane | Command | Why |
|------|---------|-----|
| A | `appium --log-level info` | Appium server on `127.0.0.1:4723`. Leave it running all day. |
| B | `cd ~/StageTimePNW_Automation && source .venv/bin/activate && pytest -s tests/` | Test runner. Re-run after every change. |
| C | `supabase start` / `supabase status` (or `python mock_supabase.py`) | The backend the app talks to during tests (section 2). |

Appium Inspector (`brew install --cask appium-inspector`) sits on Screen 2 too:
connect to `127.0.0.1:4723` with the same capabilities as `conftest.py` and use
it to read element labels/identifiers off the live simulator.

### How Clicky fits in

Clicky's assistant is editor-aware and screen-aware, so with Xcode frontmost
on Screen 1 and the test output visible on Screen 2:

- **Hold ⌥⌘C and ask** — the screen under your *cursor* is captured, so put the
  cursor over Screen 2 and ask "why did this pytest fail?" or over the simulator
  and ask "what's the accessibility label of the Create Account button?"
- **Xcode frontmost + ⌥⌘C** — Clicky reads the focused Swift file via the
  Accessibility API, so "add accessibility identifiers to every field in this
  view" works on the real source, not pixels.
- **⌃⌥X** — drag-capture a simulator frame or a red traceback to
  `~/Desktop/VIRADETH_RESUME/` and paste it into a bug report / PR.
- **⌥⌘V (Dictate)** — dictate a docstring or a commit message; it lands on the
  clipboard cleaned up.
- **Clicky Remote (iPhone)** — key `1` toggles the mic, `3` captures, `0`
  brings up Ask, so you can drive Clicky without leaving the Xcode/Terminal
  keyboard focus.

Suggested loop: run pytest (pane B) → failure → cursor on the traceback →
⌥⌘C "what element predicate should I use here?" → fix in Xcode/test → rerun.

## 2. "Mock server" — what actually needs mocking

Appium **drives the UI**; it is not a mock server and you don't mock it. The
network call under test is `AuthManager.signUp(...)` →
`SupabaseClient` → `POST https://ldodkbdzljfpbnzrpxpu.supabase.co/auth/v1/signup`.

If you run the sign-up test against production Supabase every run you will:
create a real user each time, need a unique email each time, and never be able
to complete the flow because a real verification email is sent.

So the choice is **what replaces Supabase Auth** during tests. Three options,
best first.

### Option A — Local Supabase (recommended; real API, fake email)

The Supabase CLI is already installed (`/opt/homebrew/bin/supabase`). It runs a
full local Supabase (Postgres, Auth/GoTrue, and Mailpit, which catches every
email). Requires Docker Desktop (or OrbStack): `brew install --cask docker`.

```bash
cd ~/StageTimePNW_Automation
supabase init            # once — creates supabase/config.toml
supabase start           # prints API URL, anon key, Mailpit URL (http://127.0.0.1:54324)
supabase status          # re-print them later
```

In `supabase/config.toml`, for tests only:

```toml
[auth.email]
enable_confirmations = true   # keep true to test the "check your email" message
                               # set false if you want sign-up → immediate session
```

Point the app at it (section 3), then the test can also assert the email
arrived by hitting Mailpit's API from pytest:

```python
import requests
msgs = requests.get("http://127.0.0.1:54324/api/v1/messages").json()
assert any(email in m["To"][0]["Address"] for m in msgs["messages"])
```

Pros: exact Supabase behaviour, no code mocking, resettable with `supabase db reset`.
Cons: needs Docker.

### Option B — Tiny HTTP mock (no Docker)

Emulate only the endpoints the app touches. GoTrue's contract for sign-up with
confirmations enabled returns the created user and **no session**:

```python
# mock_supabase.py  —  pip install flask
from flask import Flask, request, jsonify
import uuid, datetime

app = Flask(__name__)
users = {}

@app.post("/auth/v1/signup")
def signup():
    body = request.get_json()
    email, pw = body.get("email", "").lower(), body.get("password", "")
    if email in users:
        return jsonify(code=422, msg="User already registered"), 422
    if len(pw) < 6:
        return jsonify(code=422, msg="Password should be at least 6 characters"), 422
    now = datetime.datetime.utcnow().isoformat() + "Z"
    users[email] = {"id": str(uuid.uuid4()), "email": email, "aud": "authenticated",
                    "role": "authenticated", "created_at": now, "updated_at": now,
                    "confirmation_sent_at": now, "app_metadata": {"provider": "email"},
                    "user_metadata": {}, "identities": []}
    return jsonify(users[email]), 200          # no access_token → "verify your email"

@app.post("/auth/v1/token")
def token():
    return jsonify(error="invalid_grant", error_description="Email not confirmed"), 400

@app.get("/auth/v1/user")
def user():
    return jsonify(msg="Invalid JWT"), 401

@app.post("/__reset")                          # test hook
def reset():
    users.clear(); return "", 204

if __name__ == "__main__":
    app.run(host="127.0.0.1", port=54321)
```

Run in pane C: `python mock_supabase.py`. In a pytest fixture call
`requests.post("http://127.0.0.1:54321/__reset")` before each test so the same
email can be reused.

Pros: zero dependencies, instant, deterministic error cases. Cons: you own the
contract — if the Supabase SDK changes its expectations you fix the mock.
Off-the-shelf alternatives if you'd rather not hand-roll: WireMock
(`brew install wiremock`), MockServer, or Mockoon (GUI).

### Option C — Real Supabase, throwaway data (no mock)

Use `test+<timestamp>@yourdomain.com` and assert only that the "Account
created! Check … for a verification email" text appears. Fine for a first
smoke test, but pollutes your Auth users table and can never test login after
sign-up. Use A or B as soon as possible.

## 3. App changes needed (StageTimePNW repo)

### 3a. Make the Supabase URL switchable at launch

`SupabaseManager.swift` currently hard-codes the production URL/key. Read them
from the process environment so Appium can inject test values without a
separate build scheme:

```swift
// SupabaseManager.swift
import Foundation
import Supabase

private let env = ProcessInfo.processInfo.environment

let supabase = SupabaseClient(
    supabaseURL: URL(string: env["SUPABASE_URL"] ?? "https://ldodkbdzljfpbnzrpxpu.supabase.co")!,
    supabaseKey: env["SUPABASE_ANON_KEY"] ?? "<production anon key>"
)
```

Then in `conftest.py`:

```python
options.set_capability("appium:processArguments", {
    "env": {
        "SUPABASE_URL": "http://127.0.0.1:54321",          # local Supabase or mock
        "SUPABASE_ANON_KEY": "<anon key from `supabase status`, or any string for the mock>",
    }
})
```

`processArguments.env` is only honoured when Appium launches the app itself, so
use `options.bundle_id` (already set) with `no_reset = False`, or `options.app`.

If you use the Flask mock over plain `http://`, add to `Info.plist`
(Debug only): `NSAppTransportSecurity → NSAllowsLocalNetworking = YES`.

### 3b. Add accessibility identifiers to the sign-up screen

`LoginView.swift` already has `signin_*` identifiers; `AuthView.swift` (the
"Create your account" screen) has none, so the test would have to fall back to
fragile label matching. Add, mirroring the login naming:

| Element | Identifier |
|---------|------------|
| "Create your account" `Text` | `signup_header_title` |
| Email `TextField` | `signup_email_input` |
| Password `SecureField`/`TextField` (both branches) | `signup_password_input` |
| Confirm password field (both branches) | `signup_confirm_password_input` |
| "Create Account" `Button` | `signup_submit_button` |
| success message `Text` | `signup_success_message` |
| `authManager.errorMessage` `Text` | `signup_error_message` |
| "Log In" `Button` | `signup_to_signin_link` |

Example:

```swift
TextField("", text: $email)
    .accessibilityIdentifier("signup_email_input")
```

Tip: with `AuthView.swift` open in Xcode, hold ⌥⌘C and say "add these
accessibility identifiers" while this table is on Screen 2 — Clicky reads the
file text directly.

## 4. First test: user sign-up

Fill the two empty files in `StageTimePNW_Automation/pages/` and add the test.

`pages/base_page.py`

```python
from appium.webdriver.common.appiumby import AppiumBy
from selenium.webdriver.support.ui import WebDriverWait
from selenium.webdriver.support import expected_conditions as EC


class BasePage:
    def __init__(self, driver, timeout=15):
        self.driver = driver
        self.wait = WebDriverWait(driver, timeout)

    def find(self, accessibility_id):
        return self.wait.until(
            EC.visibility_of_element_located((AppiumBy.ACCESSIBILITY_ID, accessibility_id))
        )

    def tap(self, accessibility_id):
        self.wait.until(
            EC.element_to_be_clickable((AppiumBy.ACCESSIBILITY_ID, accessibility_id))
        ).click()

    def type(self, accessibility_id, text):
        el = self.find(accessibility_id)
        el.click()
        el.clear()
        el.send_keys(text)
        return el

    def text_of(self, accessibility_id):
        return self.find(accessibility_id).text

    def dismiss_keyboard(self):
        if self.driver.is_keyboard_shown():
            self.driver.hide_keyboard()
```

`pages/auth_page.py`

```python
from .base_page import BasePage


class SignInPage(BasePage):
    HEADER = "signin_header_title"
    TO_SIGNUP = "signin_to_signup_link"

    def is_loaded(self):
        return self.find(self.HEADER).is_displayed()

    def go_to_sign_up(self):
        self.tap(self.TO_SIGNUP)
        return SignUpPage(self.driver)


class SignUpPage(BasePage):
    HEADER = "signup_header_title"
    EMAIL = "signup_email_input"
    PASSWORD = "signup_password_input"
    CONFIRM = "signup_confirm_password_input"
    SUBMIT = "signup_submit_button"
    SUCCESS = "signup_success_message"
    ERROR = "signup_error_message"

    def is_loaded(self):
        return self.find(self.HEADER).is_displayed()

    def sign_up(self, email, password, confirm=None):
        self.type(self.EMAIL, email)
        self.type(self.PASSWORD, password)
        self.type(self.CONFIRM, password if confirm is None else confirm)
        self.dismiss_keyboard()
        self.tap(self.SUBMIT)
        return self

    def success_text(self):
        return self.text_of(self.SUCCESS)

    def error_text(self):
        return self.text_of(self.ERROR)
```

`tests/test_signup.py`

```python
import time
import pytest
from pages.auth_page import SignInPage


@pytest.fixture
def unique_email():
    return f"qa+{int(time.time())}@stagetimepnw.test"


def test_signup_happy_path_shows_verification_message(driver, unique_email):
    """Sign in → Sign up → valid form → 'check your email' confirmation."""
    signup = SignInPage(driver).go_to_sign_up()
    assert signup.is_loaded()

    signup.sign_up(unique_email, "Passw0rd!")

    msg = signup.success_text()
    assert "Account created" in msg
    assert unique_email in msg, "Success message should echo the email used"


def test_signup_rejects_short_password(driver, unique_email):
    signup = SignInPage(driver).go_to_sign_up()
    signup.sign_up(unique_email, "12345")
    assert signup.error_text() == "Password must be at least 6 characters."


def test_signup_rejects_mismatched_passwords(driver, unique_email):
    signup = SignInPage(driver).go_to_sign_up()
    signup.sign_up(unique_email, "Passw0rd!", confirm="Passw0rd?")
    assert signup.error_text() == "Passwords do not match."


def test_signup_rejects_empty_email(driver):
    signup = SignInPage(driver).go_to_sign_up()
    signup.sign_up("", "Passw0rd!")
    assert signup.error_text() == "Please enter your email address."
```

The three validation tests never hit the network (`handleSignUp` guards run
before `authManager.signUp`), so they pass against any backend. Only the happy
path needs Option A/B; with Option A you can extend it to read Mailpit and
assert the confirmation email arrived.

## 5. One-time setup checklist

```bash
# Appium (not currently installed)
npm i -g appium
appium driver install xcuitest
appium driver doctor xcuitest          # checks Xcode CLT, Carthage not needed on modern versions
brew install --cask appium-inspector

# Test repo
cd ~/StageTimePNW_Automation
python3 -m venv .venv && source .venv/bin/activate
pip install -r requirements.txt flask requests

# Simulator (must match conftest.py)
xcrun simctl list devices available | grep "iPhone 17 Pro Max"
open -a Simulator

# Build + install the app once so bundle_id works
# Xcode → Product → Run (⌘R) on the simulator, then stop it.
```

Run order on Screen 2 each session: pane C (backend) → pane A (`appium`) →
pane B (`pytest -s tests/test_signup.py`).

## 6. Notes

- `SupabaseManager.swift` commits the Supabase **anon** key. That is designed
  to be public, but make sure Row Level Security is on for every table, and
  never commit the `service_role` key.
- `conftest.py` uses `no_reset = False`, so each test starts from a fresh
  app state — the sign-in screen. Keep it that way for sign-up tests.
- If the "Create Account" button is off-screen on smaller simulators, use
  `driver.execute_script("mobile: scroll", {"direction": "down"})` before
  tapping; on iPhone 17 Pro Max it fits.
