# AGENTS.md

Guide for agents (and people) working in this repository. It holds the
architecture's reasons, the contracts that must not move, how to verify a
change, and the pitfalls that have already cost something. Every pitfall below
was actually hit once; none is a guess.

When this file and the code disagree, the code wins — then fix this file. A
rule written here with no counterpart in the code means one of the two is lying.

## What this is

Evlat is a macOS status strip that sits on the edge of the screen and tells you,
peripherally, what your AI coding sessions are doing. A mascot at the head of
the bar shows the aggregate state; below it, one indicator per session.

The app does not know about "AI sessions". It knows about **`Signal`s**.
Session tracking is the first provider of that abstraction; usage windows,
chat jobs and external commands enter the same way.

## Layout

```
Package.swift
CHANGELOG.md         release notes, `## x.y.z` per version; shown on the release
                     page and in the update window
Sources/EvlatCore/   pure core: Foundation + Dispatch only
Sources/EvlatApp/    AppKit + SwiftUI shell; the NWListener transport lives here
Sources/Evlat/       main.swift — classifies argv (app, `watch`, `signal`, help)
Tests/EvlatCoreTests/
Tests/EvlatAppTests/
Tests/Fixtures/      fake `claude`, fake `ssh`
Resources/{en,tr}.lproj/Evlat.strings
docs/media/          README's banner and screenshots; not bundled into the app
scripts/bundle-app.sh   builds build/Evlat.app; the only source of Info.plist and
                        of the signature (ad-hoc, or EVLAT_SIGN_IDENTITY) and
                        the version (EVLAT_VERSION, EVLAT_BUILD)
scripts/make-appcast.sh writes Sparkle's one-item appcast for a release
scripts/release-notes.sh prints one version's section of CHANGELOG.md
scripts/make-icon.swift draws the app icon; no image is checked in
Makefile
```

Swift 5 language mode, macOS 14 minimum (`PhaseAnimator` and
`KeyframeAnimator` come from there). One third-party dependency: Sparkle, the
shell's updater (`Updater.swift`, the only file that imports it); the core
never sees it.

## Architecture

Two layers, one hard seam. In one sentence: **the core does not import UI.**

```
┌──────────────────────────────────────────────────────┐
│  EvlatApp  (AppKit + SwiftUI)                        │
│  NSPanel · bar geometry · rings · detail card        │
│  mascot · chat bubble · settings · setup             │
└──────────────────────┬───────────────────────────────┘
                       │  seam: Signal ↓  /  Action ↑
┌──────────────────────┴───────────────────────────────┐
│  EvlatCore  (Foundation + Dispatch only)             │
│  Provider · Signal · Registry · Snapshot             │
│  local HTTP API (routing, parsing, defenses)         │
└──────────────────────────────────────────────────────┘
```

### Core rules

- **`EvlatCore` imports only `Foundation` and `Dispatch`.** No `AppKit`,
  `SwiftUI` or `Network`. A test fails if one does. The HTTP route table,
  parsing, dispatch and browser defenses are in the core and tested without
  sockets; only the `NWListener` *transport* is in the shell
  (`HookListener.swift`).
- **Platform capabilities are injected** through `Platform` (liveness, process
  start time, clock). A direct Darwin call from the core is a bug even when it
  compiles.
- **Paths are parameters**, never constants (`~/.claude/sessions` is the
  provider's argument).

This is free discipline, not infrastructure: macOS is the only target today,
but a core that obeys these rules should compile elsewhere; only the UI would
be rewritten.

### The seam: `Signal` and `Action`

Every provider reduces to one type, `Signal`: `provider`, `entity`, `kind`
(`session | usage | job | custom`), `phase`, optional `progress`, `label`,
`detail`, `source`, `fidelity`, `rawStatus`, `updatedAt`, `activity`,
`usage`, `machine`.

- **`Phase` has five values** — `idle`, `working`, `waiting`, `review`,
  `failed` — and stays at five. A new value must update three places at once:
  `Phase.priority`, the bar's indicator language and the mascot's expression
  table; miss one and the new state is silently invisible.
- Every row has a **layer** (`Registry.Layer`, derived in
  `Registry.Snapshot`; not a `Phase`, not a `Signal` field): `waiting`,
  `working`, **news** (a `review`/`failed` whose `Finish` — entity, phase,
  stamp — the user has not seen) and `passive` (a seen finish, or `idle`). The
  first three are active. The list sorts by layer, news newest finish first;
  dimmed rows stay at the bottom and paint nothing.
- `Registry.Snapshot.aggregate` reduces the live, active rows to the
  mascot's one face, by `Phase.priority`: `waiting > news (newest) > working > idle`. With no active
  row the face is `idle`. The seen set is the snapshot's pure input; the core
  keeps no clock and no seen state.
- An unrecognised source word stays **visible** in `rawStatus` and lands in the
  provider's `unrecognizedStatuses`; it is drawn as `idle` but never swallowed.
- `activity`, `usage` and `machine` are not phases and never change priority.
  Usage signals are split out by `kind` and never reach the mascot, the rings
  or `hasLive`.
- `Fidelity` (`official | derived | manual`) reaches the UI: derived and manual
  numbers are drawn with a `~` prefix, so an estimate never looks published.
- "Is anything live?" is `Registry.hasLive` — any live, active row — not a
  phase. An idle session or a seen finish lets the mascot sleep.

The reverse direction, `Action`, carries three things from UI to core: send a
prompt, answer a permission, stop. The shell (`ChatStore`) executes them with a
`claude -p` subprocess and a held permission connection.

### Providers

| provider | role | source | fidelity |
|---|---|---|---|
| `hooks` | backbone | the HTTP hook server; Claude Code, Codex and Antigravity (app, IDE, `agy`) flow into the **same** provider (`AgentSource`, `CodexHookAdapter`, `AntigravityHookAdapter`). Antigravity has no permission or notification event, so its rows never go `waiting` | official |
| `claude-sessions` | supplement | `~/.claude/sessions/*.json` + pid liveness: discovery, name, pid | derived |
| `claude-usage` | usage | `POST /usage/claude`, relayed from Claude Code's status line; only `rate_limits` is kept | official |
| `codex-usage` | usage | tail (256 KB) of the newest Codex `rollout-*.jsonl`, read only when the bar opens | derived |
| `evlat` | chat jobs | the chat bubble's turns (`ChatsProvider`) | official |
| `signal` | external jobs | `POST /signal`, keyed; sent by `Evlat watch` / `Evlat signal` | manual |

Remote machines add no provider type: each machine gets its own `hooks`,
`claude-usage` and `signal` *instances*, fed through an `ssh -R` reverse
tunnel. Identity comes from the listener, never from the request body; remote
entities are namespaced (`remote:<machine>:<session>`,
`signal:<machine>:<id>`) so they can never merge with local rows.

Each machine's tunnel is Evlat's **own `ssh` master** (`-M -S <socket>
-o ControlPersist=no`, socket under `$TMPDIR/evlat`, its path a parameter
that must fit `RemoteTunnel.socketPathLimit`); the installs and reads ride
it (`-S <socket> -o ControlMaster=no -o BatchMode=yes`) and connect on their
own when there is none. Its stdin is the dead man's switch. `ssh` gets
Evlat's environment, `SSH_AUTH_SOCK` kept, plus — only while this Mac's
listener is bound — the askpass variables (`SSH_ASKPASS` = this binary,
`SSH_ASKPASS_REQUIRE=force`, `EVLAT_ASKPASS=<port>:<token>`), with
`BatchMode=no` and `NumberOfPasswordPrompts=1`; without them `BatchMode=yes`.
At launch the first try waits for that listener to settle, so it does not
run without askpass by accident. A try is **quiet** (on the schedule, after
a wake, at launch: only a stored password answers, and only a password
prompt) or **interactive** (a machine just added, "Enter Password…": the
prompt window, `AnswerPanel`'s `PromptView`). A prompt held open keeps the
tunnel from `connected`. One password is one login: a refused one, or a quiet try's
password prompt for a machine that has a stored password or last connected
with one, stops at `needsUser` — sticky across wakes, left only by the
user's press (`RemoteTunnel`).

### The merge rule

The same Claude session arrives from two sources (hooks and the session file)
and must be one row. Rows with the same `entity` merge in
`Registry.signals()`. Conflicts are settled by a **compatibility rule on
fidelity, not by provider name**: an official phase is accepted only if it can
be true at the same time as the derived one (`waiting`/`failed` beside
`working`; `review`/`failed` beside `idle`); otherwise the derived phase
stands. "Hook wins" would freeze a session that ended while Evlat was closed.
Timestamps break ties only within the same fidelity.

- The accepted report supplies phase, timestamp, `detail` and provider; the
  **name stays the baseline's** (the hook body has no name, and the folder name
  differs from it in most real sessions).
- `activity` does not depend on acceptance — which tool is running is a fact
  even a rejected report knows.
- A row with no derived partner (Codex, external jobs) passes as it is. Dead
  sessions are dropped by liveness checks in both providers, not by this rule.

### Waiting vs idle

The product's whole value is one distinction: **waiting** means the work has
stopped *because of the user* (a permission or a question); **idle** means
nothing is stopped. `waiting` comes from hook events:

```
PermissionRequest                                → waiting
Notification(permission_prompt)                  → waiting
Notification(elicitation_dialog / *_url_dialog)  → waiting
Notification(agent_needs_input)                  → waiting
Notification(idle_prompt)                        → NOT waiting
Stop                                             → review
```

The session file's `status` does not carry this distinction; that file is for
discovery, liveness, name and pid.

A wait can also be heard and told: Settings → General → Waiting reminder
(off by default) chooses N minutes, a sound (on) and a notification (off).
A wait that outlasts N rings a chime synthesized in code (`Chime`, `NSSound`,
no sound file) and posts one notification per session (`WaitingNotifier`),
once per wait, timed from when this process first saw it waiting
(`WaitingNudge`). An answer re-arms it and takes the notification back; a
click on it opens that session's card on the bar.

### News and passive

A finish (`review`, `failed`) is **news** until the user has seen it, then
**passive**. No phase moves on a clock: a hook `review` stays until the user
sees it or the next event moves the row. The shell keeps two in-memory sets of
`Finish` keys, pruned when the row leaves (not when the key goes missing, so a
merge that holds a finish back for a while neither retells nor revives it):

- **seen** — handed to every snapshot. A finish is seen when the bar closes
  after being open ≥ 1 s (a shorter opening is a pass of the cursor; the news
  on the open bar, dimmed rows included), by `[Go to session]` on its row, or
  when the balloon draws a chat's end. The same row's next phase is a new key.
  Nothing on the open bar moves because it was seen: seeing is applied at the
  close.
- **announced** — a finish is told once, from one place: news not yet told,
  while the bar and the balloon are closed, peeks in the newest finish's
  colour. News that came while either was open, or with the first scan, enters
  silently. A forced phase ("Force state") still peeks on its own.

A seen chat (`job`) stays through the close it was seen at and goes to the
balloon's history at the next one (`ChatStore.markSeen`, which writes it
down). A seen outside row (`custom`) is the recent past and stays, passive:
the newest `AppController.keptPassive` (5) that ended within the last
`keptPassiveAge` (1 h); older ones leave through `Registry.release`, on a
closed bar only. A passive session stays listed.

A restart is asymmetric: a chat's finish not yet let go — unseen, or seen but
awaiting the next close — is persisted and comes back as news (old, so not
told), while hook and `/signal` news lives in memory and
is lost with the process.

### Rendering and CPU

- **Idle draws nothing.** When nothing moves, no frames are produced. This
  decision carries the product's entire CPU budget and breaks silently.
- Continuous SwiftUI animation costs ~7% CPU on this hardware regardless of
  technique (`PhaseAnimator`, `repeatForever`, `.drawingGroup()`), so the
  mascot lives in **beats**: a short blink or a sparse breath, still in between.
- The mascot reduces to a handful of animatable numbers (`MascotPose`); SwiftUI
  springs are interruptible and keep velocity, so a state change never snaps.
  Expression lives in the pose; the body shape is swappable.
- **A mascot nobody can see does not move.** In the hidden body modes the
  mascot is out of sight below the peek (`MascotModel.isShown` false): its
  clips leave the tree and the gaze monitor stops, so a hidden idle bar
  produces no frames and reads no mouse. The sliver and its dot are static.
  The mascot's view stays in the tree at every level, so `failed`'s shake
  (a `keyframeAnimator`) still fires on the way into the peek.

### Window

- The bar is an `NSPanel` with `.nonactivatingPanel`: **clicking the bar must
  never take focus from the front app.**
- **The bar sits on the main screen** (the menu bar's, `NSScreen.screens`'
  first — never `NSScreen.main`, which follows focus) unless the user pins
  another (Settings → General → Screen, the menu's *Screen ▸*; both shown
  only with a choice). A pin is the display's UUID (`BarDisplay`,
  `bar.display`), not its `CGDirectDisplayID`, which can change on a
  replug. An unplugged pin is kept: the bar waits on the main screen and
  the screen observer puts it back. An edge with another screen past it
  is a seam the cursor runs through; Settings says so, nothing prevents it.
- Windows that do take keyboard focus (Settings, Setup, the chat bubble) return
  focus to the previous app when they close.
- `[Go to session]` brings the session's app forward (`SessionHost`). In
  Bateri, Metalterm and Warp it opens the tab itself, through the link each
  gives its shells (`BATERI_TAB_URL`, `METALTERM_TAB_URL`, `WARP_FOCUS_URL`);
  in iTerm as `iterm2:reveal?sessionid=` the whole `ITERM_SESSION_ID`; in
  Claude's desktop app as `claude://code/continue?session=` its
  `CLAUDE_CODE_HOST_SESSION_ID`; in cmux as
  `cmux://workspace/<CMUX_WORKSPACE_ID>/surface/<CMUX_SURFACE_ID>` (its
  socket refuses processes started outside cmux; the link is undocumented
  but in its source, and was seen working on 0.64.25). Terminal and Ghostty
  publish no link: their
  tab would take Apple Events. All are read from the agent's exec-time
  environment (`KERN_PROCARGS2`) — no permission. The value is checked
  (`TabLink`): `metalterm://tab/restart` is an action, not a tab.
- **The body can hide** (Settings → General → Body: Always out, Smart hide,
  Hidden). One pure rule, `BodyPresence`, turns the mode, its three switches,
  the effective phase, the finish latch, the peek, the open bar, the balloon
  and a drag into a level — `none · sliver · peek · full` — and its hover and
  drop area; `AppController.applyPresence()` is the only writer of what
  follows from it (panel area, drawn level, `isShown`, gaze, tray icon). The
  level is not a `Phase`. At rest in the hiding modes (`none`, `sliver`) the
  hover area is a 5 pt band from the window's top to 60 pt below where the
  sliver sits, painted almost clear (black, alpha
  0.01) because fully transparent pixels receive no drags; `HoverIntent`
  opens the bar from it unchanged. Hidden × waiting turns the menu-bar icon
  amber, the only place waiting is left. Always out is today's bar, unchanged,
  and is what nothing stored means.

### Permissions

**No macOS permission is requested**, with one exception: notifications, asked
only when the user turns on the waiting reminder's notification; refused, the
sound still works. `UNUserNotificationCenter` needs a bundle, so under
`swift run` and in tests `WaitingNotifier.make()` returns `nil`. Any other path
that needs Accessibility, Screen Recording, Apple Events or a new permission is
an architecture decision, not an implementation detail.

**Evlat keeps one secret**: a remote machine's `ssh` password, when the
prompt window's "Remember in Keychain" is on (`KeychainPasswordStore`). One
internet password per machine in the classic login keychain (not the data
protection one — no entitlement): account the machine's id, protocol `ssh`,
server its host, label `Evlat — <target>`, comment the prompt it was typed
at. It answers that prompt only — a `ProxyJump`'s nested `ssh` inherits the
askpass variables, and the jump host's prompt must never get it; the prompt
is compared, not its host, because an `ssh_config` alias prompts with its
`HostName`. It is written only once the try is connected, and deleted when
the server refuses it with no other question after it (a second factor
leaves it), when the machine is removed, or when a connect is made with
"Remember" off. Security calls run on
their own serial queue, never the main one (an access question blocks the
caller); the `security` command is not used. It is not a permission, but an
ad-hoc signed build (`make run`, a default `make install`) is asked for
keychain access after every build; a Developer ID build is not after an
update. An app thrown away without removing its machines leaves the entries
behind. Tests (XCTest present, `make test-desktop` included) and an
isolated process (`EVLAT_PORT`) keep passwords in memory
(`MemoryPasswordStore`) and never touch the keychain.

## Contracts

### Hook contract

The fixed point is the command already **installed** in the user's
`~/.claude/settings.json` / `~/.codex/hooks.json`. Hooks installed by earlier
versions must keep talking to this one unchanged.

- The only author of the command is `LocalAPI.installedHookCommand(for:event:)`;
  the writers (`HookSettings`, and `AntigravityHooks` for Antigravity's
  name-keyed file, both behind `LocalHooks`) install nothing else and never
  touch other tools' hook groups. Antigravity's body names no event, so its
  command is one per event and sends it as `X-Evlat-Event`; the server uses
  the header only when the body has no `hook_event_name`. Claude's and
  Codex's bytes do not carry it.
- The command **fails silently** (`curl -m 2 … || true`) and **writes nothing
  to stdout**. The server's reply never reaches Claude Code — if it did, a
  stray JSON on `PermissionRequest` could grant or deny. `POST /hook` always
  returns `{}`.
- Golden-string tests hold it byte for byte:
  `LocalAPITests.testTheInstalledHookCommandIsUnchanged`,
  `testTheInstalledCommandFailsSilently`,
  `testTheCommandSendsTheHeadersTheServerReads`,
  `testEverySourceHasItsOwnRoute`. A failing golden string means the contract
  broke.
- The canonical vocabulary is Claude Code's. Everything source-specific lives
  in the adapter (`AgentSource.canonical`); a store or mascot rule that
  branches on `source` is a bug.

The status-line relay (`StatusLineRelay`) is the second installed contract: a
`sh -c` wrapper that preserves the user's original command's output and exit
code byte for byte (`StatusLineRelayTests`).

The approval hook (`ApprovalHook`) is another installed contract: one
`type: "http"` `PermissionRequest` group pointing at `/approval`
(`ApprovalHookTests.testTheInstalledHookIsUnchanged`). On this Mac it is
part of the Claude Code row, installed and removed with the command as one
(`LocalHooks`); the command alone reads outdated, which is how a copy from
before it is offered the update. A server's hooks never include it
(`RemoteSettings` writes `HookSettings`' bytes). It is the one hook
whose answer reaches Claude Code, so Evlat answers it only with the user's
press on the card — Allow once or Deny, never a rule, a folder or a mode —
or `{}`, which is no decision. An `AskUserQuestion` comes through it too;
its card offers the question's options, "Other…" (a line of its own,
`AnswerPanel`, since the bar never takes keys) and Deny, never a bare
Allow, and answers with `updatedInput` + `answers` (`AskQuestion`). It authenticates no server: while Evlat is
closed, whoever holds the port could answer it. Accepted for now; the
realistic case is another user's process on a shared Mac.

### Local API

Loopback only (`requiredInterfaceType = .loopback`; `lsof` shows `*:48151`,
but a POST to the LAN address is refused). Default port **48151**.

| route | notes |
|---|---|
| `POST /hook`, `/hook/claude`, `/hook/codex` | installed hooks; always `{}` |
| `GET /health` | |
| `POST /usage/claude` | status-line relay; only `rate_limits` is read |
| `POST /permission` | inline hook of a chat turn; token-guarded, reply held until the user answers; `404` through a tunnel |
| `POST /approval` | opt-in hook of terminal sessions (`ApprovalHook`); held until Allow/Deny on the card, or let go with `{}` once answered elsewhere; `404` through a tunnel |
| `POST /signal` | external jobs; requires `X-Evlat-Key` |
| `POST /askpass` | the tunnels' `ssh` prompts, from the askpass helper; token-guarded (a running try's), held until answered or refused; `404` through a tunnel. The token is in `ssh`'s environment, which a process of the same user can read (`KERN_PROCARGS2`), so such a process could take a stored password during a try — accepted, as for `/approval` |

`/signal` body: `id`, required `ttl` (`0` drops the row; ≤ 24 h, finished rows
≤ 1 h), `phase` (`working·waiting·done·failed`), `label`, `progress` 0…1,
`detail`, `sender`; errors are `400` with a stable `code` (`SignalReport`).
The server writes the identity (`signal:<id>`, `.manual`), at most 32 rows.
`working`/`waiting` live by their `ttl`. On a finish (`done`/`failed`) the
`ttl` is only validated: the row stays until the user has seen it, at most
12 h after it finished, and counts against the 32 while it waits; `ttl: 0`
still drops it at once. The "600 s" in `evlat signal`'s help is the value it
sends, not the row's life.
The key is written on every launch to
`~/Library/Application Support/Evlat/signal-<port>.token` (`0600`) by the
process that holds the port and removed on quit; wrong or missing key → `403`.
Through a tunnel the route takes the **machine's own** key.

### Command line

The binary inside the bundle is also the CLI (`~/.local/bin/evlat` is a
symlink the app can install):

```sh
evlat watch npm run build        # wraps the command transparently
evlat signal render --progress 0.4 --label Render
evlat signal render --done
```

`watch` returns the child's exit code and killing signal unchanged, leaves
stdout/stderr bytes untouched and prints nothing when Evlat is closed or
refuses (`WatchTests`, against the compiled binary). `argv` is classified by
`LaunchMode.of`: the app opens only with no arguments or with what the system
adds (`-psn_…`, `-NS…`/`-Apple…` pairs); an unknown word prints usage and exits
`2` — a new subcommand not added there does **not** fall through to the app.
With `EVLAT_ASKPASS=<port>:<token>` in the environment the binary is `ssh`'s
askpass helper instead: `argv[1]` is the prompt itself (no subcommand word),
the answer goes to stdout, and no answer exits non-zero with nothing
written. A prompt-shaped `argv` without the mark is still a usage error.

The server-side script (`RemoteCommand.script`, POSIX `sh` + `curl`, installed
to a remote machine's `~/.local/bin/evlat`) is the third installed contract:
marked and versioned, generated from the Swift constants, run under
`sh`/`dash`/`bash` in tests, and the key never appears in any argv. A change to
the script bumps its version.

### User files

`~/.claude/settings.json`, `~/.claude/statusline-*.sh`, `~/.codex/hooks.json`,
`~/.codex/config.toml`, `~/.gemini/config/hooks.json`, `~/.local/bin/evlat`
and login items belong to the
user. **Agents do not write them.** Writers are tested against a temporary root
(`EVLAT_HOME`, or a `home:` parameter in tests); no writer has a default path.
So does the login keychain: no test or trial writes an Evlat entry to it.
The masters' sockets (`$TMPDIR/evlat`, `0700`) are Evlat's own; a stale one
is cleared, a live one — another process's master — is left alone.

Renaming a `UserDefaults` key silently loses the stored value; migrate it.

## Verification

| when | command |
|---|---|
| every change | `make all` (`swift build` + `swift test`) |
| inner loop | `make build` |
| one test | `swift test --filter EvlatCoreTests.RegistryTests` |
| the window server's side (real key, real screen) | `make test-desktop` — shows windows and takes the keyboard; not while the user types |
| window, bar, mascot or menu touched | `make test-desktop` (offstage, `make all`'s focus assertions hold trivially: nothing activates and the balloon's key is a flag), then `make bundle && make run` and look at it |
| install to `/Applications` | `make install` (the user's call — it replaces the installed app) |
| ship a version | `make ship VERSION=x.y.z` — the user's call: `release`, `git push origin main`, `publish` in one go |
| release build | `make release VERSION=x.y.z` — clean tree; Developer ID, hardened runtime, notarized and stapled zip (Sparkle's), its appcast and `Evlat.dmg` (a first install's) in `build/release/x.y.z/`; needs the keychain identity, the `evlat` notarytool profile and Sparkle's EdDSA key (`SPARKLE_KEY` is its public half) |
| publish | `make publish VERSION=x.y.z` — the user's call: tags the built commit, pushes the tag, creates the GitHub release with the disk image, the zip and `appcast.xml` — every installed copy updates from it |

`make run` and `make install` stop **both** copies (`build/` and
`/Applications/`) first: two Evlats race for port 48151 and the loser's hooks go
nowhere. Processes are targeted **by path**, never by name.

Visual checks are not optional for UI changes: transparency, the right-edge
dock, the hover opening, focus staying with the front app. Use a real session
(`working → waiting → review`) at least once. What can be tested in code
(`canBecomeKey`, `activationPolicy`) goes to XCTest, not to the eye.

Every user-visible string lives in the catalog (`L10n.t("key")`), never in
code. Source language `en`, translation `tr` with full diacritics; a new string
enters **both** tables (`L10nTests` keeps the keys paired).

## Isolation

Running a second Evlat next to the user's must not touch the user's state.

| variable | effect |
|---|---|
| `EVLAT_PORT=48999` | own port; with it set, no tunnel opens unless `EVLAT_MACHINES` is given, no signal key is written or read unless `EVLAT_HOME` is given, no persistent chat store exists unless `EVLAT_CHATS` is given, and `ssh` passwords stay in memory, never in the keychain |
| `EVLAT_SESSIONS` | session directory (empty dir = no sessions) |
| `EVLAT_HOME` | temporary home root for every writer |
| `EVLAT_MACHINES` | machines to tunnel to; their keys stay in memory |
| `EVLAT_SSH` | fake `ssh`; it must run install scripts with a temporary `HOME` |
| `EVLAT_CHATS` | temporary chat root |
| `EVLAT_PHASE` | force the mascot's phase at launch (the "Force state" menu item, scriptable) |
| `EVLAT_BODY` | force the body's mode (`always`, `smart`, `hidden`) at launch; the stored mode is never written |
| `EVLAT_CLAUDE` | `claude` to run (tests use `Tests/Fixtures/fake-claude`) |
| `EVLAT_FEED` | the appcast to check; the only way an isolated launch gets an updater (a release bundle otherwise checks its `SUFeedURL`, a development bundle nothing) |
| `EVLAT_TEST_DESKTOP=1` | tests only: windows go on the real desktop instead of offstage (`WindowStage`); `make test-desktop` |

Run the binary directly for these — `open` does not carry the environment.

## Measuring

**No unmeasured number is written.** "Smoother", "less CPU" is either measured
or dropped from the sentence.

```sh
PID=$(pgrep -f "$PWD/build/Evlat[.]app/Contents/MacOS/Evlat")
ps -o pid=,rss=,etime= -p "$PID"
cpu() { ps -o cputime= -p "$1" | awk -F: '{s=0; for(i=1;i<=NF;i++) s=s*60+$i; print s}'; }
T0=$(cpu "$PID"); sleep 90; T1=$(cpu "$PID")
awk -v a="$T0" -v b="$T1" 'BEGIN{ printf "%.2f%% CPU / 90 s\n", (b-a)/90*100 }'
```

To measure one mascot state, fix the phase and empty the sessions:
`EVLAT_PHASE=working EVLAT_SESSIONS=$(mktemp -d) EVLAT_PORT=48999`, binary
started by absolute path.

CPU is read from the `cputime` **delta**, not `%cpu`; the window starts after
the launch settles. Record mouse/keyboard idleness at both ends of the window:

```sh
ioreg -c IOHIDSystem | awk '/HIDIdleTime/ {print int($NF/1000000000); exit}'
```

## Conventions

- Everything in the repository is English: identifiers, comments, test names,
  assertion messages, fixture strings, CLI flags, `make` targets, commit
  messages (imperative, one-line summary). The only exception is the `tr`
  string table.
- Comments explain **why**; new code matches the surrounding comment density.
- The store and UI live on the main thread. File watchers and the server run on
  their own queues and reach the store only through `DispatchQueue.main.async`.
  Timer closures capture `[weak self]`.
- New dependency, new macOS permission, or a change to `EvlatCore`'s import
  surface: architecture decisions — stop and ask.
- New resource file: does `scripts/bundle-app.sh` copy it, and is it found
  under `swift run` too?
- A newly caught pitfall goes into **Pitfalls** below — only things actually
  hit, never guesses.

## Pitfalls

### Core and data sources

- **`~/.claude/sessions/*.json` is an undocumented internal format.** The
  provider is `.derived`; an unknown `status` stays visible. It is not written
  at event rate: in a 135 s window with 53 hook events none of 22 files was
  written. A fresh file has no `status` field for ~500 ms — reading the missing
  field as idle would veto the hook's truth.
- **`<pid>.json` is written in place, not atomically.** No torn JSON was seen
  in 117,175 reads, but that is not a guarantee.
- **`updatedAt` and `statusUpdatedAt` diverge** (up to 188.7 s). A row's
  timestamp is the *status* timestamp.
- **Subagent events are not filtered.** A subagent carries `agent_id` but its
  parent's `session_id` and pid, emits only tool events and no `Stop`. The
  actor that set a blocking phase is kept (`Session.blockedBy`); only that
  actor or a session-level event (`Stop`, `UserPromptSubmit`) clears it —
  otherwise a sibling's tool event erased the parent's `waiting`.
- **PIDs are recycled.** Liveness alone shows ghost sessions; the record's
  `startedAt` is compared with the process's real start
  (`Platform.sameProcess`, tolerance 120 s; measured drift 0.7–6.3 s).
- **`Data` indices are absolute in a slice.** `subdata(in: 0..<n)` on a slice
  that does not start at zero crashes; the listener's buffer is exactly such a
  slice. Use `startIndex`/`endIndex`. A test built from a zero-based `Data`
  literal does not see it.
- **`allowLocalEndpointReuse` is SO_REUSEADDR, not SO_REUSEPORT.** Two
  processes cannot share the port (`testASecondListenerCannotTakeTheSamePort`);
  if they could, hooks would silently split between two Evlats.
- **A `PermissionRequest` hook does not hold the terminal's dialog.** In an
  interactive session the dialog opens the same instant the hook fires
  (2.1.285); whichever answers first wins. "No" or Esc in the terminal
  closes the held connection, but **"Yes" does not**: it stays open until
  the hook's timeout. The request carries no `tool_use_id`, so
  `ApprovalHook.resolves` reads the answer from the tool's outcome or the
  turn's end. A decision sent after the terminal answered is ignored.
  Requests are serialized per session. Measured with a pty-driven
  `claude --settings` and a stand-in server on 48999.
- **A bare `allow` does not answer `AskUserQuestion`.** The terminal's
  dialog stayed up (a user's report, measured on 2.1.285). `allow` with
  `updatedInput` — the input as it came plus `answers`, text → answer —
  closed it at 5 s and at 30 s; a written text and a multi-select's
  `"A, B"` went through as sent. A question missing from `answers` raised
  nothing and reached Claude as unanswered: send every answer at once.
- **Antigravity's hooks carry less than Claude's** (CLI 1.2.14, app 2.18.1).
  Five events, none of them a permission or a notification: a tool waiting
  for approval has had its `PreToolUse` and nothing more, so the row reads
  `working`. The body is camelCase and **names no event**. It has no pid
  either, but the hook's parent is the agent's process, so `$PPID` works as
  it does for Claude. `invocationNum` restarts at 0 each turn, so
  `PreInvocation` with 0 is the turn's start. The docs call `PreToolUse`'s
  `decision` output required; an empty reply let the tool run. In the app
  every conversation's hooks come from one `language_server`, so its rows
  live until the app quits: a passive row stays listed, and nothing ends
  them sooner. Workspace hooks (`.agents/hooks.json`) ran without a trust
  prompt, which is how this was measured without touching the user's file.
- **Antigravity's `Stop` has no reply, only `transcriptPath`.** The one
  transcript Evlat reads: at a local `Stop`, the last 64 KB, for the last
  `MODEL`/`PLANNER_RESPONSE` with text (`AntigravityTranscript`). The path
  comes from a loopback body, so only a file under the app's, the CLI's or
  the IDE's `brain` folder is read, after `..` and links are resolved; a
  tunneled path names a file on the server and is never read, so a remote
  Antigravity row has no reply. Its hooks folder (`~/.gemini/config`) is
  not the one that says Antigravity is installed, and the install makes it.
- **The Codex app runs no hooks.** In the app's own sessions (ChatGPT.app,
  `com.openai.codex`, bundled codex 0.154.0-alpha), four turns and an `exec`
  sent nothing to a `--capture` on 48151. Its settings listed the hooks as
  on, and a restart did not change it. The same `~/.codex/hooks.json` fired
  every event from the CLI and from the bundled binary's `exec`. Only Codex
  CLI sessions are tracked.
- **Codex's `rollout-*.jsonl` is undocumented and grows** (62 MB seen). Read
  the last 256 KB. `codex-usage` is derived: if the format breaks it goes
  quiet and keeps the last good reading; it never falls back to an older file.
- **`proc_pidpath` returns empty for an old process of a self-updated app**
  (`ENOENT`). The launch path is in the argument area (`KERN_PROCARGS2`). Being
  inside a `.app` does not make a path a terminal — `claude` itself runs from
  one.
- **iTerm's sessions hang off a server outside its bundle**
  (`~/Library/Application Support/iTerm2/iTermServer-<version>`, parented to
  launchd): no path in the chain names `iTerm.app`, and the walk found no
  host until `SessionHost.helperBundle` named it. Its `reveal` link wants the
  whole `ITERM_SESSION_ID` (`w0t0p0:<UUID>`); the UUID alone only brought
  the app forward.

### SwiftUI and AppKit

- **A struct `View`'s `let` is not storage.** Views are rebuilt on every parent
  update; a `Timer` publisher kept there is reborn each time and never fires.
  Use `@State` or `static`.
- **`self` in an `asyncAfter` closure is a copy of the struct `View`.**
  `@State` is read live; a `let` freezes when the closure is built. Anything
  read from the closure lives in `@State`.
- **`keyframeAnimator` fires on trigger *change*, never on first appearance.**
  If a branch switch rebuilds its owner from scratch, the transient animation
  never plays. Put its owner **above** the branches.
- **A phase change must not reset the mascot's rhythm.** A timer that restarts
  its wait on every change never blinks while the phase flaps. In a looping
  clip a phase change carries the pose and leaves the schedule alone.
- **Do not write `@Published` on every event.** Mouse movement arrives at
  display rate; without a deadband the whole bar re-evaluates at that rate
  (`GazeTracker.deadband`).
- **A `.nonactivatingPanel` that is key makes `NSApp.isActive` read `true`**
  while the front app, the menu bar owner and
  `NSRunningApplication.current.isActive` do not change. "Evlat did not come
  forward" is tested on those three.
- **`HoverIntent.closeNow` does not drop a pending open.** On a closed bar the
  pending open is dropped by `pointerExited`; otherwise the list opened under
  the chat bubble 80 ms later.
- **Ctrl-click reaches `mouseDown` too.** `BarHostingView.mouseDown` does not
  pass a ctrl-click to `onClick`; otherwise the menu click opened the bubble.
- **A text field takes a dragged file as text, and SwiftUI allows no other
  field editor** (a custom `fieldEditor(_:for:)` crashed —
  `TextField` expects `_SystemTextFieldFieldEditor`). The fix is a file-typed
  layer **above** the content whose `hitTest` returns `nil` (`ChatDropView`).
- **Transparent window pixels receive no drags.** Of the bar's 485 pt envelope
  only the drawn 54 pt saw drag events: "near the bar" means the drawn bar.
- **`NSApp.deactivate()` is not synchronous.** Deactivate-then-`makeKey`
  lost the bubble's keyboard to the resignation that followed. Activate the
  previous app and bring the bubble back after `didResignActive`.
- **AppKit rewrites menu key equivalents for the keyboard layout.** On
  Turkish-Q, `keyEquivalent: ","` became `"ö"` while the menu was open, though
  that layout has its own `,` key. At write time the property still reads
  `","`, so a test cannot see it; keep
  `allowsAutomaticKeyEquivalentLocalization = false`
  (`MenuTests.testSettingsIsCommandCommaOnEveryKeyboard`).
- **A preference sent out of a `ScrollView` arrives once, empty.** Read
  positions inside with `GeometryReader` +
  `onChange(of: frame(in: .named…), initial: true)`.
- **A test run's windows land on the user's screen and keyboard.**
  `EvlatAppTests` build real windows: a left-docked bar flashed opaque at
  `.statusBar` over the user's work, and the key balloon (a
  `.nonactivatingPanel`) took the keys being typed in another app, whose
  frontmost status never changed. Under XCTest every window is offstage
  (`WindowStage`): transparent, click-through, the balloon's key status
  kept in a flag, no activation. A new window or activation goes through
  `WindowStage` too.
- **An `NSWindow` subclass must not override `alphaValue`.**
  `window.animator().alphaValue = 1` called the Swift override with the
  animator proxy as `self`; `super.alphaValue` then crashed
  (`EXC_BAD_ACCESS` in `-[NSWindow setAlphaValue:]`). Clamp the value at
  the call site instead (`WindowStage.alpha`).
- **`NSLog` is unreadable in the unified log for this app** (`<private>`;
  `%{public}@` is an `os_log` specifier, not a fix). Read stderr by running the
  binary in the foreground.

### Processes and shells

- **An Evlat launched from a Claude Code terminal inherits that session's
  markers** (`CLAUDECODE`, `CLAUDE_CODE_CHILD_SESSION`,
  `CLAUDE_CODE_SESSION_ID`, …) and `claude -p` then thinks it is a child
  session. The environment is filtered through
  `ClaudeInvocation.parentSessionVariables`.
- **The first run of a freshly written executable pays for macOS's
  assessment** (`syspolicyd`/`XprotectService`): ~0.2 s, once ~50 s. A fake
  that enters a timed wait is warmed once untimed first
  (`FreshExecutable.warm`, `--evlat-warm`).
- **A terminal's Ctrl-C cannot be told apart by `si_pid`** — it carries the
  writer's pid, same as `kill -INT`. `watch` decides by whether it is in the
  terminal's foreground group (`Watch.shouldForward`). To try it by hand from a
  socket-stdin shell: `(sleep 2; printf '\003') | script -q /dev/null …`.
- **In POSIX `sh` a background child ignores `SIGINT`, irreversibly** (`sh`,
  `dash`, `bash`; `trap - INT` does not help). A command that must hear Ctrl-C
  runs in the foreground; the price is that a `TERM` to the wrapper waits until
  the command ends.
- **An orphaned `sleep` of a background heartbeat holds the caller's pipe.**
  `$(evlat watch true)` took 3.0 s; with the loop and `curl` on
  `</dev/null >/dev/null 2>&1`, 0.35 s. Background work never inherits the
  user's streams.
- **`dash` runs the parent's trap in a subshell until the subshell sets its
  own.** Start background jobs **before** installing traps.

- **A master killed with `-9` leaves its control socket, and the next
  `ssh -M -S` on it runs without multiplexing** ("ControlSocket … already
  exists, disabling multiplexing"; OpenSSH 10.2p1): no error, only no
  master, so the installs log in again. `RemoteTunnels` connects to the
  socket before each launch: `ECONNREFUSED` → the file goes, an answer →
  another process's master, left alone. A master that ends on its stdin's
  EOF removes the file itself. The path must fit 104 − 17 − 1 bytes
  (`RemoteTunnel.socketPathLimit`); a test's `$TMPDIR` + UUID does not.

- **`ssh`'s askpass gets the prompt alone in `argv[1]`** and, with
  `SSH_ASKPASS_REQUIRE=force`, is run with no `DISPLAY` (OpenSSH 10.2p1,
  user-level `sshd`, 2026-10-01). Seen prompts: the host key question
  (several lines, ending `(yes/no/[fingerprint])? `) and
  `<user>@<host>'s password: `. An askpass that exits `1` sends **no**
  password — the server logged `Failed none`, no `Failed password`.
- **A wrong password is three failed logins by default.** With
  `NumberOfPasswordPrompts=1` it is one `Failed password`; without it,
  three (`Permission denied, please try again.` twice). Hence one password
  per try and no retry after a refusal.

- **`ditto -c -k` keeps extended attributes as `._` files in the zip.**
  The framework's symlinks carry `com.apple.provenance`, which cannot be
  removed; a browser's unzip left `._Autoupdate` and friends in
  `Sparkle.framework`'s root and Gatekeeper rejected the notarized 0.1.0
  ("unsealed contents present in the root directory of an embedded
  framework"). `ditto -x -k` puts them back, so a test that extracts with it
  passes. Zip with `--norsrc --noextattr`.

### Measuring and running

- **Measure a binary started by absolute path.** A relative path is invisible
  to `pgrep -f` and to the Makefile's guard.
- **An empty `EVLAT_SESSIONS` does not isolate; `EVLAT_PORT` is needed too.**
  With the real Evlat closed, the measured process takes 48151 and live
  sessions' hooks flow into it.
- **Idle CPU is mouse-sensitive** — the sleeping mascot still follows the
  gaze. The same build read 0.04% one day and 3.43% the next; the difference
  was the mouse. Record HID idleness around the window.
- **`ps -o %cpu` is a decaying lifetime average,** not instantaneous; the same
  process read 13.5% → 0.6% → 8.7%. Use the `cputime` delta.
- **`ps -Axo … -p PID` returns the wrong row** — `-A` overrides the filter.
- **A drop in CPU is not always good news.** Once it fell to 0.0% because the
  mascot had stopped animating at all. Ask *what* was measured.
- **For a bursting clip the 90 s number is in-clip cost × cycle rate.** Measure
  the in-clip cost separately with `EVLAT_MASCOT_PACING=continuous`; the
  product misses the 90 s figure in both directions, so the gate stays 90 s.
