# Mac Auto Binder — project context for Claude Code

macOS JumpCloud device-enrollment workflow, built to mirror the Windows
client (`Windows Auto Binder`) in both **look and flow**.

**Never yet run on real Mac hardware.** It was authored on a Windows box.
The macOS-only paths (AppKit rendering via JXA, `sysadminctl`,
`launchctl asuser`, real `ldapsearch`) are UNVERIFIED. You are likely the
first session on an actual Mac.

## Dependencies: bash + macOS built-ins ONLY

No Python (macOS ships none), no swiftDialog, no jq, no Homebrew.
Runtime uses only: `osascript`, `curl`, `sed`, `grep`, `tr`, `head`,
`mktemp`, `stat`, `launchctl`, `sysadminctl`, `defaults`,
`ldapwhoami`/`ldapsearch`. The build additionally uses `zip`/`shasum`.
**Do not introduce an interpreter dependency.**

## The UI (`lib/jc-ui.js` + `user/ui-host.sh`)

A native **AppKit** renderer driven through `osascript -l JavaScript`
(JXA), present on every macOS. It draws the same card design as Windows:
rounded white card + shadow, brand accent, typography scale, numbered
"What happens next" step card, native spinner, show/hide password.

**ONE window for the whole flow.** Root cannot draw in the user's GUI
session, so `user/ui-host.sh` runs as the console user and keeps a single
renderer alive in `--server` mode. The card is swapped and the window
resized with its **top edge pinned**, so it reads as one panel changing
rather than a new window per step.

- one-shot: `argv[0]` = a JSON spec. stdout = one JSON result. Exit
  0 = button1, 1 = button2, 2 = dismissed. Used for previews.
- server: `argv[0]` = `--server`. One JSON spec per line on stdin, one
  JSON result per line on stdout. `{"quit":true}` ends it.
- Spec keys: `screen, company, accent, title, message, error, note,
  reference, support, footer, steps[], back, until,
  fields[{key,label,secure,value,placeholder}], button1, button2,
  icon(link|lock|warn|error|info|check)`.
- `"screen":"progress"` also takes `"until":<path>` and stays up, spinner
  running, until that file appears; its result is `{"button":-3}`. That is
  how root shows progress while it works, with no second window.

**Reference screenshots of the Windows UI** — the design target — are in
`docs/windows-reference/*.png` (welcome, account entry, progress,
success, auth failed, bind failed, blocked). Match these.

Preview any screen instantly:

```
osascript -l JavaScript lib/jc-ui.js '{"company":"Acme","accent":"#0E8A5F","icon":"link","title":"Welcome to JumpCloud","message":"Test message.","button1":"Link My JumpCloud Account","button2":"Remind Me Later"}'
```

Click through the whole flow without root:

```
./tests/preview-flow.sh
```

## Flow (matches Windows)

`WELCOME → CREDENTIALS → LINKING → SUCCESS`, plus `DEFERRED`,
`AUTH_FAILED → CREDENTIALS`, `BIND_FAILED → LINKING`, `BLOCKED`,
`UNAVAILABLE`, `CLOSED`.

`CREDENTIALS` is **one screen collecting work email AND password**
together (Windows parity), owned by `user/ui-host.sh` running as the
console user. Because root holds the API key, the two exchange
non-secret messages over FIFOs while the host keeps the password:

```
root -> host : SCREEN/PROGRESS/PROGRESS_WAIT/CREDENTIALS/QUIT  ($JC_IPC_DIR/cmd)
host -> root : BUTTON n / PROGRESS_DONE / TOKEN <status> / BYE ($JC_IPC_DIR/resp)
host -> root : $JC_IPC_DIR/email.req   (entered email)
root -> host : $JC_IPC_DIR/user.resp   (JumpCloud username, or NONE)
```

Root serves that lookup inside `ui_credentials_step` in `lib/ui.sh`
(deliberately NOT called via `$( )` — it must set globals).

## Layout

- `jc-enroll.sh` — root orchestrator / state machine (entry point).
- `lib/jc-ui.js` — native AppKit renderer (the UI); one-shot and --server.
- `lib/ui.sh` — screen wrappers that call the renderer as the console user.
- `lib/config.sh` — GENERIC defaults; tenant values arrive as env vars.
- `lib/preflight.sh` — already-bound precheck, console-user wait, Secure
  Token gate, defer/completion state.
- `lib/jcapi.sh` — JumpCloud REST (ported from the proven `jc_bind.sh`).
- `lib/logging.sh` — `/var/log/jc_enroll.log` (0600), emails masked.
- `user/ui-host.sh` — console-user process: owns the single window and
  the long-lived renderer; credential screen + LDAPS bind; returns ONLY a
  status token.
- `build/build-package.sh` — emits `dist/` (zip + MDM-Command.sh + hash).
- `tests/` — `test-units.sh`, `test-flow.sh`, `dry-run.sh`.

## CURRENT STATUS

First bring-up on real Mac hardware is done. Both suites are green:

- `tests/test-units.sh` — 71 pass / 0 fail
- `tests/test-flow.sh`  — 31 pass / 0 fail
- `bash build/build-package.sh` passes (runs both suites + the CR gate)

The renderer has been exercised on real modal windows: button routing,
JSON result, exit codes, show/hide password, and the window-close path.
Reference comparison screenshots were checked against
`docs/windows-reference/`.

### Bugs found and fixed during bring-up (do not reintroduce)

`lib/jc-ui.js` — none of this works under JXA, and each one was fatal:

1. `$.NSApp` is nil until `$.NSApplication.sharedApplication` is sent.
   Without it `runModalForWindow` returns nil, so every screen reported
   "dismissed" and exited 2.
2. Assigning a `CGColorRef` (`layer.backgroundColor` / `layer.borderColor`)
   **kills the process with SIGKILL**. All fills, borders and corner radii
   go through `NSBox`, which takes `NSColor`.
3. `NSAttributedString`'s initialisers are not exposed by the bridge.
   Buttons are an `NSBox` + a plain `NSTextField` under a transparent,
   title-less `NSButton` that takes the clicks.
4. Inside an `ObjC.registerSubclass` implementation, `id` arguments come
   back with a lighter wrapper: `sender.tag` is a **string**, so
   `=== 100` never matched and every primary button read as button 2.
   Coerce with `Number()`.
5. `$.NSImageSymbolScaleMedium` is undefined; passing `undefined` where an
   NSInteger is expected aborts. Use the literal `2`.
6. BridgeSupport reports the **legacy** `NSTextAlignment` ordering
   (left/right/center) under the modern names, while AppKit at runtime
   uses the UIKit ordering. Use the literals 0/1/2.

`lib/ui.sh` — every screen wrapper ended with `set -e`, which switched
errexit **on** for the rest of the run even though `jc-enroll.sh` is
deliberately written without it. After the first screen, "Remind Me
Later" and any binding failure aborted the script instead of reaching
`DEFERRED` / `BIND_FAILED`. Never re-enable errexit there.

`json_field` (now in `user/ui-host.sh`) used `"([^"]*)"`, which
truncated any password containing `"` or `\` (the renderer escapes both),
so correct passwords failed the LDAP bind. It now walks the value and
undoes the escapes, in pure bash 3.2.

Found by clicking through the real flow (both invisible to the suites as
they were written, because the stubs modelled the *documented* contract
rather than the shipped behaviour):

7. `lib/jc-ui.js` exited **0 for both buttons** (`result.button < 0 ? 2 : 0`),
   but `lib/ui.sh` and the console-user host tell the buttons apart
   by exit status. Every secondary button - "Remind Me Later", "I'll Sign
   Out Later", "Close", "Back" - was therefore read as the primary one, so
   deferring still walked into the credential screen and "Sign Out Later"
   took the sign-out branch. The exit code now carries the button index.
   `tests/test-units.sh` locks the mapping against the real renderer.
8. `ui_progress_start` stored `$!`, which is the `launchctl asuser`
   wrapper. That command FORKS, so `kill` never reached the `osascript`
   drawing the window and "Linking your account..." stayed on screen for
   the rest of the session. The console-user shell now records its own PID
   and `exec`s the renderer in place, so the pidfile holds the process that
   owns the window. The `launchctl` stub in `tests/` forks too, since the
   old `exec` stub collapsed all three processes into one PID and hid this.

### Still unverified

- A real LDAPS bind against JumpCloud (needs a real user's password).
- A real MDM run (genuinely binds the device).
- Clicking the UI by hand — the flow was driven programmatically because
  this environment has no Accessibility permission for synthetic input.

## First runs on this Mac

```
sudo ./tests/dry-run.sh                                   # simulated LDAP + binding
sudo ./tests/dry-run.sh --real-ldap --org <ORG_ID>        # real read-only LDAPS bind
sudo ./tests/dry-run.sh --ldap invalid                    # failure path
```

Logs: `sudo tail -40 /var/log/jc_enroll.log`.
Reset: `sudo rm -rf "/Library/Application Support/JumpCloudEnrollment"`.

## Hard constraints (do not regress)

1. **macOS ships bash 3.2.** No `mapfile`, no associative arrays, and
   `"${arr[@]}"` on an EMPTY array errors under `set -u` — use
   `${arr[@]+"${arr[@]}"}`.
2. **LF line endings only.** CRLF gives `bad interpreter: /bin/bash^M`.
   The build gate rejects any CR.
3. **The password never reaches root.** Screen + bind both live in
   `user/ui-host.sh`; the password reaches LDAP tools via a
   **FIFO** — never `-w` (ps-visible), never `-y <file>` (on disk).
4. **No plaintext LDAP.** 636 = LDAPS, 389 = StartTLS (`-ZZ`),
   `LDAPTLS_REQCERT=demand`. No silent fallback.
5. **No account enumeration.** Unknown email still shows the password
   prompt and returns the same token as a wrong password.
6. Keep the original gates: `{{device.primary_user_id}}` already-bound
   precheck, console-user polling, and the **Secure Token gate** on
   `_jumpcloudserviceaccount` (silent exit is intentional).
7. Call `osascript` unqualified (not `/usr/bin/osascript`) so tests can
   stub it.

## Expected first-run surprises

- **Secure Token gate may stop everything**: if
  `_jumpcloudserviceaccount` lacks a Secure Token the run exits with
  `Status: Skipped … Secure Token` and NO window appears. That is correct.
  Check: `sysadminctl -secureTokenStatus _jumpcloudserviceaccount`.
- **JXA/AppKit is the least-verified code in the project.** Likely
  suspects if a window misbehaves: `ObjC.registerSubclass` handler
  wiring, `$.NSApp.runModalForWindow` / `stopModalWithCode` codes,
  `fittingSize` height measurement, and the show/hide password swap.
- LDAP result codes: 0 ok, 49 bad credentials, 32/34 DN/config, 85 timeout.

## Deployment

One command, one zip:

```
bash build/build-package.sh --url https://raw.githubusercontent.com/OWNER/REPO/main/dist/JumpCloudEnrollment-macOS.zip
```

→ `dist/JumpCloudEnrollment-macOS.zip` + `dist/MDM-Command.sh` (that URL
and the zip's SHA-256 pinned inside) + `dist/SHA256.txt`.

JumpCloud: Mac command, **Run As root**, **timeout ≥ 3900 s**, paste the
command. Nothing is attached — the command downloads the zip, verifies it
against the pin and runs it. Attaching the zip still works and takes
precedence, so leave `PACKAGE_URL` empty for an attachment-only tenant.

The pin lives in the command text, not the package, so a tampered or
stale download is refused. Downloads are HTTPS-only. **Re-run the build
and re-paste the command whenever the zip changes**, or the hash check
will correctly fail. Only the TENANT SETTINGS block at the top is edited
per organization; the zip stays tenant-neutral.

A real MDM run genuinely binds the device and sets the primary user —
only run it against a Mac you intend to enroll.
