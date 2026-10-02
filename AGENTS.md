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
Sources/EvlatAgents/ what is particular to each agent; Foundation + the core only
Sources/EvlatApp/    AppKit + SwiftUI shell; the NWListener transport lives here
Sources/Evlat/       main.swift — classifies argv (app, `watch`, `signal`, help)
Tests/EvlatCoreTests/
Tests/EvlatAgentsTests/ the agents' tests, the installed contracts' golden strings among them
Tests/EvlatAppTests/
Tests/Fixtures/      fake `claude`, fake `codex app-server`, fake `ssh`
Resources/<lang>.lproj/Evlat.strings
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

Two layers, one hard seam, and the agents beside the core. In one sentence:
**the core does not import UI, and the shared code names no agent.**

```
┌──────────────────────────────────────────────────────┐
│  EvlatApp  (AppKit + SwiftUI)                        │
│  NSPanel · bar geometry · rings · detail card        │
│  mascot · chat bubble · settings · setup             │
└──────────┬───────────────────────────┬───────────────┘
           │  seam: Signal ↓ Action ↑  │  Agents.all
           │                ┌──────────┴───────────────┐
           │                │  EvlatAgents             │
           │                │  (Foundation + core)     │
           │                │  Claude/ Codex/          │
           │                │  Antigravity/ · catalog  │
           │                └──────────┬───────────────┘
┌──────────┴───────────────────────────┴───────────────┐
│  EvlatCore  (Foundation + Dispatch only)             │
│  Provider · Signal · Registry · Snapshot · Agent     │
│  local HTTP API (routing, parsing, defenses)         │
└──────────────────────────────────────────────────────┘
```

Three targets, one direction: `EvlatCore` ← `EvlatAgents` ← `EvlatApp`.
`EvlatAgents` holds what is particular to each agent — its routes, hooks,
usage, approvals, files and mark — as the values of one `Agent` each
(`Claude/`, `Codex/`, `Antigravity/`); the types are `internal` and only the
catalog, `Agents` (`all`, `routes`, `chatBackends`), is open. The core sees an agent only as an `Agent`
and an opaque `AgentID`; the shell reaches one only through the catalog.

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
- **The shared code names no agent.** The core is closed by the compiler: it
  depends on nothing, so it cannot import `EvlatAgents`. The shell, which
  can, is closed by `BoundaryTests` (`Tests/EvlatCoreTests/`), and so is a
  name the compiler cannot see (a `"claude"` literal, a `.codex` path): every
  agent's name and every `EvlatAgents` type, comments aside, in
  `Sources/EvlatCore` and `Sources/EvlatApp`, against an allowlist with an
  exact count and a reason per file. Only the session host's tab links
  are on it. A rule that branches on one agent is that agent's value.
- **`EvlatAgents` imports only `Foundation` and `EvlatCore`** (`BoundaryTests`).

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
  or `hasLive`. A window not observed for an hour (`UsageBlockModel.staleAfter`)
  is drawn dimmed; Settings → Usage → "Hide usage not seen for an
  hour" (`usage.hideStale`, off by default) leaves it out instead, before the
  block's cap, so a tool not in use frees its lines until it reports again.
- `Fidelity` (`official | derived | manual`) reaches the UI: derived and manual
  numbers are drawn with a `~` prefix, so an estimate never looks published.
- "Is anything live?" is `Registry.hasLive` — any live, active row — not a
  phase. An idle session or a seen finish lets the mascot sleep.

The reverse direction, `Action`, carries three things from UI to core: send a
prompt, answer a permission, stop. The shell (`ChatStore`) executes them
through the chat's backend (`ChatBackend`, an agent's `chat`), and never asks
which agent it is:

- `ChatSession.begin` gives a `TurnSpec`; the backend makes it a
  `TurnLaunch` (`turn(spec, ctx:)`) once the shell knows the listener's port,
  the turn's token and the memory folder (`TurnContext`). `TurnRunner` starts
  one process per turn; `AgentLocator` finds its program (`EVLAT_<NAME>`, then
  the login shell's `PATH`).
- The backend's `parser(for: spec)` reads stdout into `ChatEvent`s; an
  unknown word is counted, not swallowed. Transport is **one way** (stdout
  streams, a permission is posted to `/permission` and answered on the held
  connection; Claude Code) or **duplex** (asked and answered on the
  process's own stdio, the parser writing the protocol's next lines as the
  process answers; Codex's `app-server`). Only a one-way turn needs the
  listener bound.
- A `ChatRequest` carries its reply target; the answer is the backend's
  `encode(ChatDecision, for:)`. "Always" is the backend's `alwaysOption`:
  Claude's rules and folders, kept for the chat, or Codex's same command
  again for the session (`allowForSession`), kept by Codex. A request a
  duplex backend does not know is refused with a JSON-RPC error and said
  in the chat (`ChatEvent.unsupported`), never left hanging. Stop denies
  every open card at its own target, then applies the backend's `stopPlan`
  (`.signal`, or `.inBand`: the parser's `stopLine`). A duplex turn still
  running `TurnRunner.stopGrace` after its result is ended: whether Codex's
  server exits when stdin closes was not measured. Each turn is a new
  server, so Codex's "this command again" is measured to hold within one
  server only; across a turn's `thread/resume` it was not measured.
- A chat runs on the backend selected when it was made (Settings → Chat,
  `chat.backend`, none stored is the catalogue's first) and keeps it; its
  session id is the agent's own when the first turn names one (Codex's
  thread). The conversation itself is the agent's: Claude Code and Codex
  write it under their own homes (`~/.claude`, `~/.codex`), Evlat keeps
  only the index.
- Modes are the backend's (`ChatMode`): a mode's own denial is retried in
  the mode it names (`retryDenialAs`). The new chats' default is stored per
  backend (`modeKey`), and so is the index (`indexFile`); Claude Code keeps
  the names it had before (`chat.permissionMode`, `chats.json`), and an older
  build that rewrites `chats.json` never sees another backend's file.

### Providers

| provider | role | source | fidelity |
|---|---|---|---|
| `hooks` | backbone | the HTTP hook server; Claude Code, Codex and Antigravity (app, IDE, `agy`) flow into the **same** provider (each agent's `HookChannel`: `Codex/CodexHookAdapter`, `Antigravity/AntigravityHooks`). Antigravity has no permission or notification event, so its rows never go `waiting` | official |
| `claude-sessions` | supplement | `~/.claude/sessions/*.json` + pid liveness: discovery, name, pid (`Claude/SessionsProvider`, the agent's `providers`) | derived |
| `claude-usage` | usage | `POST /usage/claude`, relayed from Claude Code's status line; only `rate_limits` is kept (`StatusLineUsageProvider`; id, group, fidelity and the windows read are the agent's `StatusLineUsage`) | official |
| `antigravity-usage` | usage | `POST /usage/antigravity`, relayed from the Antigravity CLI's status line (`~/.gemini/antigravity-cli/settings.json`); only `quota`'s `gemini-5h`/`gemini-weekly` are drawn, as the "Gemini" group. Same provider type as Claude's (`StatusLineUsageProvider(source:)`); the format is undocumented | derived |
| `codex-usage` | usage | tail (256 KB) of the newest Codex `rollout-*.jsonl`, read only when the bar opens (`Codex/CodexUsageProvider`, the agent's `providers`) | derived |
| `evlat` | chat jobs | the chat bubble's turns, on any chat backend (`ChatsProvider`); a backend that answered with another version than the one measured is in its `diagnostics` and in Settings → Chat | official |
| `signal` | external jobs | `POST /signal`, keyed; sent by `Evlat watch` / `Evlat signal` | manual |

An agent can be switched off (Settings → Agents, its card's switch; the
setup's agent step). The set is `agents.enabled` (`EnabledAgents`): nothing
stored is the agents found, asked live each time, and it is written only by
the user's change — an isolated process (`EVLAT_PORT`) keeps it in memory.
An agent off has no session row: `Registry.signals()` drops it **after**
the merge, `kind == .session` only, by asking whether the row's `source` is
in the set (a file row and a hook row go together; a remote machine's rows
answer to that machine's set, `Registry.machineSources`, by
`Signal.Machine.id`). Its usage provider is unregistered, so its windows
go with it. An `/approval` request with no switched-on agent that takes
approvals is answered `{}` at once and the held ones are let go. Its
attention lines go quiet. Turning off an agent with Evlat's parts in its
files asks whether they go too (the default) or stay.

Remote machines add no provider type: each machine gets its own `hooks`
and `signal` *instances*, and a `StatusLineUsageProvider` per agent switched
on there whose usage a status line posts (`<id>@<machine>`), fed through an
`ssh -R` reverse tunnel; a usage report goes to the machine's provider for
its `source`, or is dropped. Identity comes from the listener, never from the
request body; remote entities are namespaced (`remote:<machine>:<session>`,
`signal:<machine>:<id>`) so they can never merge with local rows.

A machine shows this Mac's agent cards (Settings → Remote Machines, the same
`SetupRowView` with another `SetupCardDriver`), written over `ssh`: one
press is one agent's unit (`RemoteSettings.Change.agent`), its one file in
one write. A server has no approval hook, and only `RemoteSettings.relays`
— Claude — gets the usage line there; Antigravity's remote relay is not
measured and not installed. Its switches are the machine's own set,
`remote.machines[].agents` (`decodeIfPresent`; none stored is every agent
the server has, and it is written only on the user's change), independent
of `agents.enabled`; an `EVLAT_MACHINES` machine keeps it for the run.

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

The mascot can speak (Settings → Mascot). **Who speaks** is one choice
(`SoundVoice`): Evlat's own tones, drawn in code (`EvlatSound`, `Chime`: no
sound file), or a character — an OpenPeon / CESP pack (`SoundPack`, from PR
#8) with several lines per moment, one picked at random and never the same
twice in a row (`SoundPicker`). **When** is a switch per moment
(`SoundMoment`: done, error, waiting for approval, waiting for an answer;
all off by default): a finish speaks as it is told — the peek's moment and
rule below, whatever the body mode, an error's line if one failed; a wait as
it begins, under the same rules (not at the first scan, not on the open bar
or beside the balloon). One sound at a time: anything within
`AppController.soundGap` (1.5 s) of the last is let go. A character with no
line for a moment cannot switch it on.

"Remind again" (off by default) speaks once more after N minutes — waits
until answered, or with "Everything" also finishes until seen (the
registry's `news`, never a guess) — only where that moment's row is on,
and posts a notification if asked (`WaitingNotifier`), taken back on the
answer or the look; a click opens that session's card on the bar. Waits are
timed from when this process first saw them (`WaitingNudge`), finishes from
when they were told; a finish that entered silently is never reminded of.
An upgrade from the old reminder keeps its sound: with minutes and "Play a
sound" stored, the two wait rows start on (`storedSoundOn`), so those users
now also hear a wait begin.

Characters are installed from the OpenPeon registry by the user's press in
the characters sheet (`SoundPackBrowser`) — Evlat's only download besides
Sparkle's feed: the manifest checked against the index's sha256, every
sound against the manifest's, 1 MB a file and 50 MB a pack, assembled in a
temporary folder and moved into `~/.openpeon/packs/<name>` whole. That
folder is shared with every OpenPeon player: a pack another player
installed shows up here, and "Remove" moves it to the Trash, never deletes.
An isolated process without its own `EVLAT_HOME` has no sheet.

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
  colour, and speaks if its moment is on (above). News that came while
  either was open, or with the first scan, enters silently. A forced phase
  ("Force state") still peeks on its own, without a sound.

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
  focus to the previous app when they close. While Settings or Setup is open
  Evlat is a regular app, Dock icon included (`WindowStage.comeForward`);
  the last one to close makes it an accessory again.
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
  environment (`KERN_PROCARGS2`) — no permission — or, in a herdr or tmux
  pane, from the client's: herdr's newest client connected to its server's
  client socket and with a terminal, tmux's client of the pane's session
  that did something last (asked of the server's own `tmux`, 0.25 s at
  most). A pane whose client is not found opens no tab: the app comes
  forward only if the walk still reaches one. Each multiplexer is one
  type conforming to `Multiplexer` (`Herdr`, `Tmux`), listed in
  `SessionHost.multiplexers`. A herdr pane is then selected inside the tab with
  `herdr agent focus <HERDR_PANE_ID>` (`HerdrPane`). That and the tmux
  query above are the only processes Evlat runs to find and open a
  local session: each the server's own executable, fixed arguments, checked
  values, no shell, and a command that only reads or selects. The value is checked
  (`TabLink`): `metalterm://tab/restart` is an action, not a tab.
  A remote session whose agent keeps session records
  (`Agent.sessionRecords`; Claude Code's) is asked of its server once per
  card, off the main queue (`RemoteHostLookup`): a read-only `sh` script
  (`RemoteHost`), never installed, over the machine's live tunnel master
  only (`ProxyCommand=/usr/bin/false`: a gone master is no call, never a
  login; a call past 10 s is ended), with the session id checked as a
  UUID. The record's pid counts only if its process started within 120 s
  of the record's `startedAt` (pids are recycled). It walks the agent's
  parents to its connection's `sshd` (the one under the listener) and says
  `SSH_CONNECTION`'s ports, that `sshd`'s start and its own clock. In a
  tmux or herdr pane it walks from the client instead, by this Mac's rules:
  tmux's client of the pane's session that did something last, asked of
  the server's own executable (`<proc>/<pid>/exe`, `timeout 2` where there
  is one) once `TMUX` names an ancestor that is tmux; herdr's newest client
  with a terminal connected to its server's `herdr-client.sock` (the
  server's ends from `/proc/net/unix` and its `fd` links, their peers from
  `ss -x`). No client attached is said as `none`, which is no button; a
  pane it cannot ask says nothing, and never falls back to the pane's own,
  stale `SSH_CONNECTION`. On this Mac the candidates are the
  user's `ssh` processes connected to the same end as Evlat's own tunnel
  `ssh` (`Ssh`, `PROC_PIDFDSOCKETINFO`): the exact client port, else the
  only one (unless its start is > 10 s off), else the start nearest the
  connection's (≤ 2 s, every other > 10 s), else the app alone if all are
  in one, else no button. A pick that is the user's own `ControlMaster`
  with other `ssh` riding it is the app alone too. From that
  `ssh` the walk is the local one. The card shows the button only once
  found, says nothing while searching, and keeps the answer for its life:
  the click walks this Mac again, never asks again. A card that could not
  ask (no live master) asks on the next snapshot. Approvals and the
  branch stay with local rows.
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
only when the user turns on "Remind again"'s notification; refused, the
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
- Golden-string tests hold it byte for byte, beside the agents in
  `Tests/EvlatAgentsTests/`:
  `LocalAPITests.testTheInstalledHookCommandIsUnchanged`,
  `testTheInstalledCommandFailsSilently`,
  `testTheCommandSendsTheHeadersTheServerReads`,
  `testEverySourceHasItsOwnRoute`. A failing golden string means the contract
  broke.
- The canonical vocabulary is Claude Code's. Everything source-specific lives
  in the adapter (the agent's `HookChannel.canonical`); a store or mascot rule that
  branches on `source` is a bug.

The status-line relay (`StatusLineRelay`) is the second installed contract: a
`sh -c` wrapper that preserves the user's original command's output and exit
code byte for byte (`EvlatAgentsTests.StatusLineRelayTests`).

On this Mac an agent is one card in Settings → Agents and one unit to
install (`AgentIntegration`): its hooks, its approval hook where it has one,
and its usage relay where it has a status line here (Claude; Antigravity
only with its CLI). The parts' states make one: all current → installed,
none → not installed, anything between → needs update. Parts in the same
file are one write (Claude's three in `settings.json`); a refused write names
its part. A relay edited by hand is not a part — never written over, never
taken out — and a missing relay wants no attention: only an old hook does.
The card's details remove the relay alone. Every agent in the catalogue has
a card; one not on this Mac is dim with nothing to press.

The approval hook (`ApprovalHook`) is another installed contract: one
`type: "http"` `PermissionRequest` group pointing at `/approval`
(`EvlatAgentsTests.ApprovalHookTests.testTheInstalledHookIsUnchanged`).
Its type is split: the route and the canonical rules that read an answer
(`ApprovalHook.path`, `resolves`, `supersedes`) are the core's; the
installed bytes are Claude's (`Claude/ApprovalHook.swift`, an extension of
it). On this Mac it is
part of the Claude Code card, installed and removed with the command as one
(`LocalHooks`); the command alone reads outdated, which is how a copy from
before it is offered the update. A server's hooks never include it
(`RemoteSettings` calls `LocalHooks` with `approvals: false`). It is the one hook
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
`~/.codex/config.toml`, `~/.gemini/config/hooks.json`,
`~/.gemini/antigravity-cli/settings.json`, `~/.local/bin/evlat`, `~/.openpeon/packs`
and login items belong to the user. **Agents do not write them.** Writers are tested against a temporary root
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
code. Source language `en`; the translations are `tr` (full diacritics),
`de`, `es`, `fr`, `pt-BR`, `ru`, `uk`, `ja`, `ko`, `zh-Hans` and `zh-Hant`,
the website's languages, with its words for the phases. A new string enters
**every** table (`L10nTests` keeps the keys and their `{placeholders}` paired
and names the languages, so a table that stops parsing fails a test). A
`{count}` form is read for every count but one: in `ru` and `uk` it is
phrased so no plural agreement hangs on the number ("Сессий: {count}").
A new language is a new `lproj` folder named as Apple names it, its own
name in its `language.name`, plus its code in `L10nTests.languages`.

The language is the system's unless Settings → General → Language picks
one. The choice is `AppleLanguages` in the app's own domain
(`LanguageChoice`), the key macOS's per-app language uses, so what Evlat
does not draw (Sparkle's window, a text field's menu) follows it from the
next launch. Measured: written there it is `Locale.preferredLanguages` at
the next launch, and the global domain keeps the system's list. Not
measured: that System Settings → Language & Region → Applications lists
Evlat and writes the same value. Evlat's own text
changes at once (`AppController.applyLanguage`): `L10n.language` is a
variable now, so anything read as it is drawn — the menu, a notification —
needs nothing; the views that keep their words are built again by `.id` on
the language (the bar's column, card and usage block, the balloon, the
settings and setup windows), and the models that make lines when they read
are told (`languageChanged(to:)`). **Never the mascot**: it is outside the
rebuilt part, or its rhythm and keyframes would start over. A test that
changes the language puts `L10n.language` back.

## Isolation

Running a second Evlat next to the user's must not touch the user's state.

| variable | effect |
|---|---|
| `EVLAT_PORT=48999` | own port; with it set, no tunnel opens unless `EVLAT_MACHINES` is given, no signal key is written or read unless `EVLAT_HOME` is given, no persistent chat store exists unless `EVLAT_CHATS` is given, `ssh` passwords stay in memory, never in the keychain, and so do the agents' switches (`agents.enabled`) and the language chosen in Settings |
| `EVLAT_SESSIONS` | session directory (empty dir = no sessions) |
| `EVLAT_HOME` | temporary home root for every writer |
| `EVLAT_MACHINES` | machines to tunnel to; their keys stay in memory |
| `EVLAT_SSH` | fake `ssh`; it must run install scripts with a temporary `HOME` |
| `EVLAT_CHATS` | temporary chat root |
| `EVLAT_PHASE` | force the mascot's phase at launch (the "Force state" menu item, scriptable) |
| `EVLAT_BODY` | force the body's mode (`always`, `smart`, `hidden`) at launch; the stored mode is never written |
| `EVLAT_CLAUDE` | `claude` to run (tests use `Tests/Fixtures/fake-claude`) |
| `EVLAT_CODEX` | `codex` to run for the chat (tests use `Tests/Fixtures/fake-codex-app-server`) |
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
  messages (imperative, one-line summary). The only exception is the
  translated string tables.
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
  not the one that says Antigravity is installed, and the install makes it
  (`AgentIntegration.Parts.opensHooksDirectory`) — on a server only where one of its
  own folders is, so a missing folder still means "not there".
- **The Codex app runs no hooks.** In the app's own sessions (ChatGPT.app,
  `com.openai.codex`, bundled codex 0.154.0-alpha), four turns and an `exec`
  sent nothing to a `--capture` on 48151. Its settings listed the hooks as
  on, and a restart did not change it. The same `~/.codex/hooks.json` fired
  every event from the CLI and from the bundled binary's `exec`. Only Codex
  CLI sessions are tracked.
- **`codex app-server` is experimental** (its help says so; measured on
  0.156.1, schema from `codex app-server generate-json-schema`). The chat
  reads it by those shapes: a version that answers differently is said in
  Settings → Chat (`ChatBackend.measuredVersion`), an unknown server
  request is refused rather than left to hang the turn.
- **Codex's `acceptForSession` is for the same command only.** After it, a
  different command (`echo four > c2.txt`) asked again: it is not a rule
  like Claude's. The card's third button says "this command", and Evlat
  keeps nothing.
- **SIGINT ends Codex's app-server, not its turn**: no `turn/completed`
  comes. Stop is `turn/interrupt` on stdin (`turn/completed` with
  `interrupted` 40 ms later, measured); before the turn has an id there is
  nothing to interrupt and the process is ended.
- **Codex's `rollout-*.jsonl` is undocumented and grows** (62 MB seen). Read
  the last 256 KB. `codex-usage` is derived: if the format breaks it goes
  quiet and keeps the last good reading; it never falls back to an older file.
- **`proc_pidpath` returns empty for an old process of a self-updated app**
  (`ENOENT`). The launch path is in the argument area (`KERN_PROCARGS2`). Being
  inside a `.app` does not make a path a terminal — `claude` itself runs from
  one.
- **The Antigravity CLI's status line carries its quota** (`agy` 1.2.14,
  undocumented, measured): `quota.{gemini,3p}-{5h,weekly}` with
  `remaining_fraction` (0–1, remaining, not used) and `reset_time`
  (RFC 3339). `3p` is the other vendors' models it offers, a separate pool.
  Its `statusLine` is Claude's shape (`type`, `command`, JSON on stdin) but
  lives in the CLI's own `settings.json`, not the hooks file; the app and
  IDE have none. A relay that prints nothing would **replace** the CLI's
  built-in line with an empty one: `stack_with_default: true` keeps both
  (`StatusLineRelay.installing`).
- **iTerm's sessions hang off a server outside its bundle**
  (`~/Library/Application Support/iTerm2/iTermServer-<version>`, parented to
  launchd): no path in the chain names `iTerm.app`, and the walk found no
  host until `SessionHost.helperBundle` named it. Its `reveal` link wants the
  whole `ITERM_SESSION_ID` (`w0t0p0:<UUID>`); the UUID alone only brought
  the app forward.
- **`/proc/net/unix` names no peer, and `ss -x` prints big inodes
  negative.** A server's accepted ends carry the socket's path there, a
  client's end carries nothing, and no column pairs them; `ss -x`'s
  `Peer Address:Port` does (sock_diag, no privilege). iproute2 6.1 prints
  an inode above 2^31 as a signed 32-bit number (`-10595714` for
  `4284371582` in `/proc/net/unix` and `fd` links, seen on Ubuntu, kernel 6.8):
  add 2^32 before comparing.
- **herdr's panes hang off a server parented to launchd, with no app at
  all** (`herdr server`, herdr 0.9.1): the walk reached launchd and found
  "no terminal" for every session in it. The terminal is wherever a `herdr`
  client of the same session runs (`HERDR_SESSION` in the server's
  environment, `--session` in the client's arguments), so
  `SessionHost.viaClient(of:)` walks that client instead. The pane's environment
  is the server's, from the terminal the server was **first** started in —
  a cmux tab long closed, or Ghostty while the client is in cmux — so the
  tab link is read from the client.
- **A closed tab's herdr client lives on, attached** (herdr 0.9.3, Bateri).
  The tab closed, its `login` sat exiting, and the `herdr` client stayed with
  no terminal (`tty ??`), still connected to the server, ignoring `TERM`
  and `HUP` — only `KILL` ended it. Its pid was the highest and its chain
  still reached Bateri, so "the higher pid" opened the closed tab; pids are
  no order of attaching either (17:08 got 22670, 17:18 got 37020). A
  client counts only with a terminal and a connection to the client socket
  (`unsi_conn_pcb` = the server's accepted `soi_pcb`, what `lsof -U` shows
  as `->0x…`), newest start first. Every client shows the same view: a
  switch in one window was seen in the other at once.
- **A home NAT rewrites the ssh client port.** The tunnel's
  `192.168.1.217:60070` reached the server as `31.223.75.17:19656`, a
  Bateri tab's `:63114` as `:19554` (OpenSSH 9.6p1, 2026-10-02): matching
  `SSH_CONNECTION`'s port alone never held from that network. Candidates
  are found by the tunnel's own end instead, and told apart by start: the
  connection's `sshd` started +0.11 s and −0.19 s from its Mac `ssh`, the
  clocks were within 0.5 s.
- **`ssh -S` with a gone master logs in by itself.** `ControlMaster=no`
  only stops it becoming a master; with no socket it connects directly.
  `-o ProxyCommand=/usr/bin/false` makes that fail at once (exit 255,
  ~40 ms, nothing sent) and a live master never runs it; over the master
  the script took 0.19–0.25 s.

- **macOS cannot play Ogg Vorbis.** An OpenPeon line in Ogg (`Evet_M.ogg`,
  22 kHz mono, from the Turkish villager packs) is opened by `NSSound` and
  `AVAudioPlayer` alike, and both answer `false` to `play()`; mp3 and wav
  play. 21 of the registry's packs are Ogg: the sheet marks them "Doesn't
  play on Mac" and offers no install, and a line is judged by its name
  (`AudioSupport`). A decoder would be a new dependency.

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
- **An accessory app's `NSApp.activate()` is only a request** (cooperative
  activation, macOS 14+). Opened from the menu, the settings window was
  ordered behind the front app, which kept the keyboard: the window list
  read `bateri` first, Evlat's 740×480 window second, `bateri` frontmost.
  A window the user asked for makes Evlat `.regular` while it is open.
- **`NSLog` is unreadable in the unified log for this app** (`<private>`;
  `%{public}@` is an `os_log` specifier, not a fix). Read stderr by running the
  binary in the foreground.

### Processes and shells

- **An Evlat launched from a Claude Code terminal inherits that session's
  markers** (`CLAUDECODE`, `CLAUDE_CODE_CHILD_SESSION`,
  `CLAUDE_CODE_SESSION_ID`, …) and `claude -p` then thinks it is a child
  session. The environment is filtered through
  `ClaudeInvocation.parentSessionVariables` (`TurnLaunch.removedEnvironment`).
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
