# JumpCloud Device Enrollment — macOS

A polished, self-service enrollment workflow for **any JumpCloud tenant**:
a native AppKit window asks the employee for their JumpCloud email and
password together, verifies the credentials against JumpCloud Cloud LDAP
(LDAPS, never plaintext), and only then runs the device-binding pipeline
(username alignment → association → primary user).

**Dependencies: bash 3.2 and macOS built-ins only** — no swiftDialog, no
Python, no jq, no Homebrew. The UI is drawn by `lib/jc-ui.js` through
`osascript -l JavaScript`, which ships with every macOS.

This is the macOS counterpart to the Windows enrollment tool. It keeps
the original `jc_bind.sh` API behaviour intact and wraps it in the same
architecture: UI / auth / binding / logging / config layers with an
explicit state machine.

---

## What the user sees

1. **Welcome** — why linking matters. *Link My JumpCloud Account* /
   *Remind Me Later*.
2. **Verify your JumpCloud account** — one screen collecting work email
   **and** password together (Windows parity), with show/hide on the
   password and a *← Back* link. Format errors appear inline on the same
   screen.
3. **Progress** — "Verifying your account…" then "Linking your account
   to this Mac…".
4. **Success** — a checkmark plus Mac-accurate next steps (log out, sign
   in with the JumpCloud password, enter the old password once if macOS
   asks to update the keychain), then *Sign Out Now* / *I'll Sign Out
   Later*. Sign-out only ever happens on an explicit click.
5. Failure paths: **We couldn't verify your account** (bad credentials /
   service unreachable — deliberately identical wording, no account
   enumeration), **We couldn't link your account** (verified but binding
   failed, with a support reference and *Try Again*), and
   **Enrollment is unavailable**.

Email and password share one screen, and that screen is owned by
`user/ui-host.sh` running as the console user, so neither the
password nor the LDAP bind ever enters the root process — see Security
below.

Preview any screen on its own, without running the flow:

```bash
osascript -l JavaScript lib/jc-ui.js '{"company":"Acme","accent":"#0E8A5F","icon":"link","title":"Welcome to JumpCloud","message":"Test.","button1":"Link My JumpCloud Account","button2":"Remind Me Later"}'
```

## Architecture

```
JumpCloud command (Run As root; {{Apikey}} / {{OrgID}} / {{device.id}} /
│                  {{device.primary_user_id}} substituted at dispatch)
│
├─ MDM-Command.sh          TENANT SETTINGS + verify zip hash + extract + exec
│
└─ jc-enroll.sh            orchestrator (root) — state machine
     ├─ lib/config.sh      generic defaults; tenant values come from the command
     ├─ lib/logging.sh     /var/log/jc_enroll.log (0600), emails masked
     ├─ lib/preflight.sh   already-bound check, console-user wait,
     │                     Secure Token gate, defer/completion state
     ├─ lib/jcapi.sh       JumpCloud REST (the original proven calls)
     ├─ lib/ui.sh          screen wrappers; run the renderer as the console user
     ├─ lib/jc-ui.js       native AppKit renderer (osascript JXA) — the UI
     └─ user/ui-host.sh    RUNS AS THE CONSOLE USER: owns the single
                           window and one long-lived jc-ui.js renderer;
                           collects email + password and does the LDAPS
                           bind, returning only a status token
```

State model: `WELCOME → CREDENTIALS → LINKING → SUCCESS`, with
`WELCOME → DEFERRED`, `CREDENTIALS → AUTH_FAILED → CREDENTIALS`,
`LINKING → BIND_FAILED → LINKING (retry)`, plus `BLOCKED`,
`UNAVAILABLE` and `CLOSED`.

## Preflight gates (preserved from the original script)

| Gate | Behaviour |
|---|---|
| `{{device.primary_user_id}}` already set | Device is already bound → exit immediately, no prompt |
| Console user | Polls `/dev/console`, skipping `root` / `_mbsetupuser` / `loginwindow` until a real user is logged in |
| **Secure Token** | `_jumpcloudserviceaccount` must exist **and** hold a Secure Token, otherwise exit quietly without prompting (JumpCloud cannot manage the local password/FileVault without it). Set `SHOW_BLOCKED_SCREEN=1` to tell the user instead of exiting silently. |
| Completed / deferred | Local state under `/Library/Application Support/JumpCloudEnrollment` |

## Setup

Edit only the marked block at the top of `dist/MDM-Command.sh`:

```bash
# ================= TENANT SETTINGS - EDIT THESE =================
ORG_ID=""                              # JumpCloud Org ID (required)
JC_REGION="US"                         # US or EU tenant
COMPANY_NAME="Your Organization"
SUPPORT_CONTACT="your IT administrator"
LOGO_PATH=""                           # optional logo PNG on the device
DEFER_MINUTES=120                      # "Remind Me Later" snooze
DEFER_MAX_COUNT=0                      # 0 = unlimited defers
LDAP_HOST="ldap.jumpcloud.com"
LDAP_PORT=636                          # 636 = LDAPS, 389 = StartTLS
REQUIRE_SECURE_TOKEN=1
SHOW_BLOCKED_SCREEN=0
# ================================================================
```

`ORG_ID` also comes from the `{{OrgID}}` automation variable when the
block is left blank. If neither is set the command refuses to run and
says so. The packaged zip stays tenant-neutral — one package, any tenant.

## Deploy

One command, one zip. Build with the URL the zip will be published at:

```bash
bash build/build-package.sh --url https://raw.githubusercontent.com/OWNER/REPO/main/dist/JumpCloudEnrollment-macOS.zip
```

That produces:

- `dist/JumpCloudEnrollment-macOS.zip` — the package, tenant-neutral
- `dist/MDM-Command.sh` — the whole command, with that URL **and** the
  zip's SHA-256 baked in
- `dist/SHA256.txt`

Commit both, then in the JumpCloud console: **Commands → + New Command** →
Mac, **Run As: root**, **timeout ≥ 3900 s** (a person interacts with a
window), and paste `MDM-Command.sh`. Nothing needs to be attached: the
command downloads the zip itself, checks it against the pinned hash and
runs it. Target a device group and schedule it to repeat — bound,
completed and deferred Macs exit in well under a second.

Attaching the zip to the command still works and takes precedence over
downloading, so an air-gapped or attachment-only tenant needs no change:
leave `PACKAGE_URL` empty and attach the file (JumpCloud puts attachments
in `/tmp` on macOS).

**The hash is the trust anchor.** It lives in the command text you paste
into the console, not in the package, so a tampered or stale download is
refused and never executed. The download is HTTPS-only — a `http://` or
`ftp://` URL is rejected outright. The practical consequence: **every time
the zip changes you must re-run the build and re-paste the command**, or
the hash check will correctly fail.

Only the marked block at the top of `dist/MDM-Command.sh` is edited per
organization; the zip itself stays tenant-neutral, so one package serves
every tenant.

### The UI

There is no third-party UI dependency and no fallback path. `lib/jc-ui.js`
is a native AppKit renderer driven through `osascript -l JavaScript`
(JXA), present on every macOS.

**One window for the whole flow.** Root cannot draw in the user's GUI
session, so `user/ui-host.sh` runs as the console user and keeps a single
renderer alive in `--server` mode: it reads one JSON screen spec per line
and writes one JSON result per line, swapping the card and resizing the
window with its top edge pinned. The card changes in place rather than a
window closing and another opening at each step. A `"screen":"progress"`
spec also takes `"until":<path>` and stays up, spinner running, until that
file appears - that is how root shows progress while it works, without a
second window. Passing a single spec as `argv[0]` instead still renders
one screen and exits, which is what the preview command above does.
The JXA bridge is narrower than plain AppKit, and the file's header
documents the traps that cost real debugging time: `NSApp` is nil until
`NSApplication.sharedApplication` is sent; assigning a `CGColorRef` to
`layer.backgroundColor` kills the process, so every fill, border and
corner radius goes through `NSBox`; `NSAttributedString`'s initialisers
are not exposed, so buttons are a box plus a label under a transparent
hit target; `tag` arrives as a *string* inside an `ObjC.registerSubclass`
callback; and BridgeSupport still reports the legacy `NSTextAlignment`
ordering, so the constant named "center" right-aligns.

## Security

- **The password never enters the root process.** The prompt and the
  LDAP bind both run in `user/ui-host.sh` as the console
  user, which returns only `VERIFIED` / `AUTH_FAILED` / `UNAVAILABLE` /
  `TIMEOUT` / `CONFIG_ERROR` / `BACK` / `CANCELLED`.
- **Never on a command line or on disk.** The password reaches
  `ldapwhoami`/`ldapsearch` through a **FIFO**, so it is never visible in
  `ps` (which `-w <password>` would be) and never written to a file
  (which `-y <file>` would be).
- **Encryption is mandatory.** Port 636 uses LDAPS, port 389 requires
  StartTLS (`-ZZ`); anything else is refused. `LDAPTLS_REQCERT=demand`
  means an untrusted certificate fails closed. There is no plaintext
  fallback.
- **No account enumeration.** An unknown email still shows the password
  prompt and returns the same generic failure as a wrong password. The
  real cause goes only to the root-owned log.
- **Logs**: `/var/log/jc_enroll.log`, mode 0600, emails masked
  (`ra***@example.com`). Passwords, API keys and tokens are never logged.
  Binding failures also append a breadcrumb to the device description in
  the JumpCloud console (appended, never clobbering the existing text).
- Users must be **enabled for LDAP** in JumpCloud — they authenticate as
  themselves, so no service account or shared secret is deployed.

## Testing

Run on any machine with bash (no Mac required):

```bash
bash tests/test-units.sh
```

```bash
bash tests/test-flow.sh
```

- `test-units.sh` — 71 assertions: JSON escaping, email masking, user
  lookup parsing, 5xx retry, username alignment (case-insensitive
  compare, original case sent), 409-as-success, every failure category,
  defer/completion state, the renderer-result parser, and the credential helper's status tokens.
- `test-flow.sh` — 31 assertions: drives the real orchestrator with
  stubbed macOS commands through the happy path, defer, invalid email,
  wrong password, LDAP unavailable, binding failure, retry, already
  bound, missing Secure Token and missing `ORG_ID`.

**Review the real screens without root:**

```bash
./tests/preview-flow.sh
```

Runs the real orchestrator and the real `lib/jc-ui.js` renderer as the
console user, stubbing only `launchctl asuser` / `sudo -u` (no-ops when
you are already that user). LDAP and binding are simulated, state and log
go to a temp directory. Use it to click through the flow; use the root
dry-run below before deploying.

**On a real Mac, before deploying:**

```bash
sudo ./tests/dry-run.sh
```

Runs the real machinery — console-user detection, Secure Token gate,
the AppKit screens, the credential helper — while **simulating** LDAP
and binding. Nothing changes in JumpCloud and no sign-out happens.
Useful variants:

```bash
sudo ./tests/dry-run.sh --ldap invalid
```

```bash
sudo ./tests/dry-run.sh --real-ldap --org <YOUR_ORG_ID>
```

`--real-ldap` performs a genuine read-only LDAPS bind so you can prove
the DN template and LDAP enablement work before going live.

## Troubleshooting

| Symptom / reference | Meaning |
|---|---|
| `Status: Skipped … Secure Token` | `_jumpcloudserviceaccount` missing or without a Secure Token |
| `Status: Skipped … Primary user already set` | Device already bound |
| `ORG_ID not set` | TENANT SETTINGS not filled in |
| `AUTH_FAILED` after a correct password | User not LDAP-enabled in JumpCloud, or wrong Org ID in the DN |
| `CONFIG_ERROR` | Bad DN template, unsupported LDAP port, or no LDAP client tools |
| `ASSOCIATION_FAILED` / `PRIMARY_USER_FAILED` / `USERNAME_ALIGNMENT_FAILED` | JumpCloud API rejected that step — see the log and the device description |
| `package hash mismatch` | The attached zip doesn't match the command; rebuild and republish both |
| No window appears | No console user yet, device already bound/deferred, or Secure Token gate |

Logs: `sudo tail -40 /var/log/jc_enroll.log`.
Reset local state: `sudo rm -rf "/Library/Application Support/JumpCloudEnrollment"`.

## Notes and limits

- macOS ships **bash 3.2**, so the code avoids `mapfile`, associative
  arrays and other bash 4 features, and guards empty-array expansion
  under `set -u`. Shell files must stay **LF** — CRLF breaks
  `/bin/bash`; the build fails if any CR is found.
- Because dialogs must run in the user's GUI session, everything
  user-facing goes through `launchctl asuser … sudo -u …`.
- *Sign Out Now* uses the standard `System Events` logout, which macOS
  may confirm and which apps with unsaved work can block.
- Authored on Windows and first brought up on real Mac hardware later.
  The macOS-only paths (AppKit rendering through JXA, `sysadminctl`,
  `launchctl asuser`, real `ldapsearch`) are exercised by
  `tests/dry-run.sh` **on a Mac**, not by the automated suites.
