# AGENTS.md

Guide for agents (and people) working in this repository. It holds what no
single symbol can: the rules new code must obey where no test would catch
it, the contracts that must not move, how to verify a change, and the
pitfalls that have already cost something. How and why one piece behaves is
in the doc-comment beside it; this file names that symbol rather than
repeat it. Every pitfall below was actually hit once; none is a guess.

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
Tests/Fixtures/      fake `claude`, fake `codex app-server`, fake `ssh`, fake `sbx`,
                     fake `bateri`
Resources/<lang>.lproj/Evlat.strings
docs/media/          README's banner and screenshots; not bundled into the app
scripts/bundle-app.sh   builds build/Evlat.app; the only source of Info.plist and
                        of the signature (ad-hoc, or EVLAT_SIGN_IDENTITY) and
                        the version (EVLAT_VERSION, EVLAT_BUILD)
scripts/make-appcast.sh writes Sparkle's one-item appcast for a release
scripts/release-notes.sh prints one version's section of CHANGELOG.md
scripts/make-icon.swift draws the app icon; no image is checked in
scripts/demo.sh         a full bar to look at: an isolated Evlat filled with
                        every kind of row (`demo-seed.py`); `stop` ends it
Makefile
```

Swift 5 language mode, macOS 14 minimum (`PhaseAnimator` and
`KeyframeAnimator` come from there). One third-party dependency: Sparkle, the
shell's updater (`Updater.swift`, the only file that imports it); the core
never sees it.

Sparkle's schedule is the release plist's (`bundle-app.sh`) and when its
window is shown is Evlat's (`UpdateReminder`, `Updater.swift`). Evlat never
relaunches itself to install: that would end a chat's turn and lose the
hooks' news.

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

Three targets, one direction: `EvlatCore` ← `EvlatAgents` ← `EvlatApp`
(`Package.swift`, `Agents.swift`). The core sees an agent only as an `Agent`
and an opaque `AgentID`; the shell reaches one only through the catalog.

### Core rules

- **`EvlatCore` imports only `Foundation` and `Dispatch`.** No `AppKit`,
  `SwiftUI` or `Network`. A test fails if one does (`ImportPurityTests`).
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
  exact count and a reason per file. A rule that branches on one agent is
  that agent's value.
- **`EvlatAgents` imports only `Foundation` and `EvlatCore`** (`BoundaryTests`).

### The seam: `Signal` and `Action`

Every provider reduces to one type, `Signal`.

- **`Phase` has five values** — `idle`, `working`, `waiting`, `review`,
  `failed` — and stays at five. A new value must update three places at once:
  `Phase.priority`, the bar's indicator language and the mascot's expression
  table; miss one and the new state is silently invisible.
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
  `TurnLaunch` (`turn(spec, ctx:)`) once the shell knows the socket the
  listener bound, the turn's token and the memory folder (`TurnContext`). `TurnRunner` starts
  one process per turn; `AgentLocator` finds its program (`EVLAT_<NAME>`, then
  the login shell's `PATH`).
- The backend's `parser(for: spec)` reads stdout into `ChatEvent`s; an
  unknown word is counted, not swallowed. Transport is **one way** (stdout
  streams, a permission is posted to `/permission` and answered on the held
  connection; Claude Code, whose turn's inline `PermissionRequest` hook is a
  `type: "command"` `curl -sf --unix-socket` to Evlat's socket — the answer
  is its stdout, every failure an empty output, `|| true`) or **duplex** (asked and answered on the
  process's own stdio, the parser writing the protocol's next lines as the
  process answers; Codex's `app-server`). Only a one-way turn needs the
  listener bound.
- A request a duplex backend does not know is refused with a JSON-RPC
  error and said in the chat (`ChatEvent.unsupported`), never left hanging.
  Stop denies every open card at its own target, then applies the backend's
  `stopPlan`. Each turn is a new server, so Codex's "this command again" is
  measured to hold within one server only; across a turn's `thread/resume`
  it was not measured.
- The chat can be switched off (Settings → Chat's first switch,
  `chat.enabled`, on when nothing is stored). Off, nothing opens the
  balloon (`openChat` refuses). Turning it off stops every running turn as Stop does
  (`ChatStore.stopRunning`, not quitting's SIGTERM) and closes the balloon;
  the rows stay, and a chat's finish while it is off enters silently (no
  peek, no sound) and stays news until seen.
- A chat runs on the backend selected when it was made (Settings → Chat,
  `chat.backend`) and keeps it; its session id is the agent's own when the
  first turn names one (Codex's thread). None stored, it is derived each
  time, never written (`ChatStore.firstFoundLane`); a pick in Settings
  stores even the backend now derived. No program at all names no agent
  and links each backend's `installPage`, opened in the browser behind the
  app in front.
  The conversation itself is the agent's: Claude Code and Codex write it
  under their own homes (`~/.claude`, `~/.codex`), Evlat keeps only the
  index.
- Modes are the backend's (`ChatMode`). The new chats' default is stored per
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
| `signal` | external jobs | `POST /signal` on a socket, no key; sent by `Evlat watch` / `Evlat signal` | manual |

An agent can be switched off (Settings → This Mac, its card's switch; the
setup's first step, whose Connect switches off the tiles left unchecked).
The set is `agents.enabled` (`EnabledAgents`): nothing stored is the agents
found, asked live each time, and it is written only by
the user's change — a second Evlat (`EVLAT_SOCKET`) keeps it in memory.
An agent off has no session row (`Registry.signals()` drops it after the
merge) and no usage windows. An approval request from an agent switched off where it runs
(this Mac's set, or the machine's own) is answered `{}` at once, and that
scope's held ones are let go. Its
attention lines go quiet. Turning off an agent with Evlat's parts in its
files asks whether they go too (the default) or stay.

Remote machines add no provider type: each machine gets its own `hooks`
and `signal` *instances*, and a `StatusLineUsageProvider` per agent switched
on there whose usage a status line posts (`<id>@<machine>`), fed through the
machine's channel (below); a usage report goes to the machine's provider for
its `source`, or is dropped. Identity comes from the listener, never from the
request body; remote entities are namespaced (`remote:<machine>:<session>`,
`signal:<machine>:<id>`) so they can never merge with local rows.

Docker sandboxes (local `sbx` only; a cloud sandbox cannot reach this Mac)
are a third kind of `hooks` instance, with no tunnel: the sandbox
listener (`SandboxListener`, port 48152) is `.sandbox` and the one
listener that believes `X-Evlat-Sandbox`; every other listener deletes it
(`SandboxListener.swift`). It has no usage, no `/signal` and no approval
card.

It is one switch, Settings → Docker sandboxes → "Watch sandboxes"
(`sandboxes.enabled`, off when nothing is stored; the Claude Code card
points there, only where `sbx` is found). Only while it is on does the
listener bind, and only the process that bound it runs the watcher (`SandboxWatcher`): it hears the
`sbx` daemon's lifecycle events (`GET /events` on `sandboxd.sock`, chunked
NDJSON, undocumented and internal — read as derived, a word it does not
know counted, the stream opened again on the core's growing delay,
`SandboxDaemon`; transport `SandboxDaemonLink`; what it does on each
event is `SandboxWatcher`'s doc). A stopped sandbox is never `exec`'d —
that starts it.
Turned off, Evlat's file and rule come out of every running sandbox; a
stopped one keeps the file, which speaks to a closed port, and no record
of it is kept. Settings lists what the last list said, one tag each, and
one status line (the port taken, a socket path past the 103 bytes Evlat
dials, `sbx` not running, a version other than the measured 0.46.0).

A machine shows this Mac's agent cards (Settings → Servers, the same
`SetupRowView` with another `SetupCardDriver`), written over `ssh`: one
press is one agent's unit (`RemoteSettings.Change.agent`), its one file in
one write. Claude's unit there carries its approval hook, as on this Mac,
and Codex's carries its own, there only (the channel's `installs`; Codex's
dialog waits for the hook, so here every permission would wait on the
bar): its requests are held under the machine's id,
only that machine's events resolve them, its rows' cards show them, and
the answer goes back to its listener. Only `RemoteSettings.relays`
— Claude — gets the usage line there; Antigravity's remote relay is not
measured and not installed. Its switches are the machine's own set,
`remote.machines[].agents` (`decodeIfPresent`; none stored is every agent
the server has, and it is written only on the user's change), independent
of `agents.enabled`; an `EVLAT_MACHINES` machine keeps it for the run.
A connected machine whose hooks of an agent switched on there, or whose
`evlat` command, an older copy wrote is an attention line
(`SetupAttention.machineNeedsUpdate`, `RemoteMachinesModel.needsUpdate`),
read from the machines' one model's reading (`AppController.remoteMachines`,
Settings' and the update window's) once it has one — the re-read after a
press — else from the channel's; a missing part or a usage line
alone is none, as on this Mac.

Each machine's tunnel is Evlat's **own `ssh` master**, and over it runs
the machine's **channel**: the server's socket,
`~/.config/evlat/run/evlat.sock` — the one its installed commands speak
to, as this Mac's do here — forwarded to a socket of the machine's own
beside the master's, where the machine's listener (`.machine`) is. No TCP
port is opened on the server. How a try connects, asks for a password,
probes and forwards, and why each step is there, is `RemoteTunnel`'s doc.
A prompt held open keeps the tunnel from `connected`. The probe's reading
fills the machine's rows in Settings (`RemoteTunnels.reading(of:)`).

A home on NFS and a home whose socket path passes a unix address (103
bytes) were not measured.

### The merge rule

The same Claude session arrives from two sources (hooks and the session file)
and must be one row. Rows with the same `entity` merge in
`Registry.signals()`. Conflicts are settled by a **compatibility rule on
fidelity, not by provider name**: an official phase is accepted only if it can
be true at the same time as the derived one (`waiting`/`failed` beside
`working`; `review`/`failed` beside `idle`); otherwise the derived phase
stands. "Hook wins" would freeze a session that ended while Evlat was closed.
Timestamps break ties only within the same fidelity. What the accepted
report supplies, and what passes as it is, is `Registry`'s doc.

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

Each agent's adapter maps its own events onto these (`HookChannel.canonical`).

When the mascot speaks and what "Remind again" reminds of are
`AppController`'s doc (`WaitingNudge`, `WaitingNotifier`); a finish is
reminded of only while it is the registry's `news`, never a guess.
Characters are installed from the
OpenPeon registry by the user's press in the characters sheet
(`SoundPackBrowser`) — Evlat's only download besides Sparkle's feed.

### News and passive

A finish (`review`, `failed`) is **news** until the user has seen it, then
**passive**. No phase moves on a clock: a hook `review` stays until the user
sees it or the next event moves the row. When a finish is seen and when it
is told is `AppController`'s doc (`seen`, `toldFinishes`); nothing on the
open bar moves because it was seen.

**At the tab, the news is quiet.** A lone new finish, a lone wait that
begins and a reminder come due first ask whether the user is at that
session's tab (`AppController.isAtTab`, `TabFocus`); several at once are
told without asking. At it, nothing sounds or peeks. Focus is never
"seen": the face, the ring and the news stay.

### Rendering and CPU

- **Idle draws nothing.** When nothing moves, no frames are produced. This
  decision carries the product's entire CPU budget and breaks silently.
- Continuous SwiftUI animation costs ~7% CPU on this hardware regardless of
  technique (`PhaseAnimator`, `repeatForever`, `.drawingGroup()`), so the
  mascot lives in **beats**: a short blink or a sparse breath, still in between.
- **The one continuous motion is outside SwiftUI**: `working`'s arc is a
  `CAShapeLayer` turned by Core Animation (`SpinningArc`). Measured on a release build,
  one working row, the mascot forced idle, 90 s: Evlat 1.33–1.41% against
  1.29–1.51% with no row, where a turn per beat cost 3.97–4.16%. The render
  server pays instead — WindowServer rose by some points, not pinned down: a
  video playing behind moved its own baseline between 34% and 44%.
- The mascot reduces to a handful of animatable numbers (`MascotPose`); SwiftUI
  springs are interruptible and keep velocity, so a state change never snaps.
  Expression lives in the pose; what it moves is a **character's** rig
  (`MascotRig`, `MascotCharacter`). Characters live one folder each under
  `Sources/EvlatApp/Mascot/Characters/` and enter by being listed in
  `MascotCharacters.all`, which `MascotCharacterContractTests` checks: the
  five phases read apart, looping clips stay under the duty-cycle ceiling,
  and a rig names only controls it declared. A character may replace any
  phase's clip with its own; Evlat's clips (`MascotClip`) are the default.
  When it plays gestures of its own is its `MascotBehavior`: rules over a
  typed context the shell hands it (`MascotContext`), asked **on events,
  never on a tick** — phase entered, sessions changed, gesture ended, or a
  wake a rule named. A character without rules is never asked.
- **Smart hide's edge costs no new timer**: it is read on the existing
  1.5 s poll, one window list a tick. Measured on a release build, no row,
  the left edge under another app's window, the mouse still (screen locked,
  HID idle 5–15 min), 90 s: Smart (covered, reading) 0.09% and 0.18%,
  Tucked (not reading) 0.12% and 0.07%, Always visible 0.09% and 0.08% — the
  reading lies inside the runs' spread. A clear edge is not measured (the
  user's window covered both edges): it is Always visible's bar plus the
  reading, and with the mascot out the gaze follows the mouse as Always
  visible's does.

### Window

- The bar is an `NSPanel` with `.nonactivatingPanel`: **clicking the bar must
  never take focus from the front app.**
- **The window reaches above the bar's head** by `AppController.headroom`,
  transparent, so a tall card can rise to stay on screen. Every measure that
  names the top (`slotTop`, `listTop`, `isOverMascot`, `BodyPresence.Area`)
  is from the head, and every point read from the window takes the headroom
  off first.
- `[Go to session]` brings the session's app forward and, where the
  terminal gives its shells a tab link, opens the tab itself — which
  terminals, how a session is found locally, on a server and in a Docker
  sandbox, and why, is the doc of `SessionHost`, `TabLink`, `Ssh`,
  `RemoteHost` and `Sandbox`. Nothing on the way asks for a permission. The
  processes Evlat runs for it, and no others: the tmux server's own `tmux`
  to find a local pane (fixed arguments, checked values, no shell, a
  command that only reads); the running Bateri's `bateri focus` for the
  news (`TabFocus`; it only reads); a read-only `sh` script over a
  machine's live tunnel master only (`RemoteHost`; its one change is
  herdr's `agent focus` at the click). Setting sandboxes up is the one place
  Evlat runs `sbx` (`SandboxRunner`), only while "Watch sandboxes" is on.
  herdr's saved machines (`herdr machine add`) start their bridge from
  another path (`--idle-timeout-v1`, not under `--remote`) and were not
  measured: the lookup leaves them to the detached master's riders.
- **A panel beside the mascot — the chat balloon or the setup — is the one
  thing talking** (`BesidePanel`): while one is out the bar stays out, the
  list closed and the news quiet. Ask it through `AppController.isPanelOut`;
  `isChatOpen` is the balloon's alone, and a site that reads it leaves the
  setup under a hovering list or a finish's sound. A setup that opens by
  itself takes the keyboard only when Evlat is the app in front
  (`isFrontmost`), or its first Return would write to the user's agents'
  files while they type elsewhere.
- **The body can hide** (Settings → General → Body: Always visible, Smart
  hide, Tucked, Hidden). One pure rule, `BodyPresence`, turns the mode, its
  switches, the edge and the bar's state into a level — `none · sliver ·
  peek · full` — and its hover and drop area; `AppController.applyPresence()`
  is the only writer of what follows from it. How Smart hide reads the edge
  is the doc of `EdgeCover` and `AppController.pollEdge`; it has no alpha
  threshold, so a near-clear layer-0 window keeps the edge covered — the
  quiet side. A stored `smart` is the new Smart hide, `tucked` is Tucked.
  Always visible is today's bar, unchanged, and is what nothing stored means;
  `HoverIntent` opens the bar from a hiding mode's hover area unchanged.

### Permissions

**No macOS permission is requested**, with one exception: notifications, asked
only when the user turns on "Remind again"'s notification. Any other path
that needs Accessibility, Screen Recording, Apple Events or a new permission is
an architecture decision, not an implementation detail.

The news reads whether the screen is locked (`ScreenLock`) and Smart hide
reads other apps' window bounds (`EdgeCover`), both with no permission
(measured on macOS 26.4.1). Only bounds, layer, alpha, owner pid and number
are read; a window's name — what Screen Recording guards — never is.

**Evlat keeps one secret**: a remote machine's `ssh` password, when the
prompt window's "Remember in Keychain" is on (`KeychainPasswordStore`): one
internet password per machine in the classic login keychain (not the data
protection one — no entitlement). It answers the prompt it was typed at
only (`SSHPasswordStore`). It is written only once the try is connected, and
deleted when the server refuses it with no other question after it (a
second factor leaves it), when the machine is removed, or when a connect is
made with "Remember" off. It is not a permission, but an
ad-hoc signed build (`make run`, a default `make install`) is asked for
keychain access after every build; a Developer ID build is not after an
update. An app thrown away without removing its machines leaves the entries
behind. Tests (XCTest present, `make test-desktop` included) and a
second Evlat (`EVLAT_SOCKET`) keep passwords in memory
(`MemoryPasswordStore`) and never touch the keychain.

## Contracts

### Hook contract

The fixed point is the command already **installed** in the user's
`~/.claude/settings.json` / `~/.codex/hooks.json` — on this Mac and on a
server, the same bytes. It speaks to the socket under the home where it
runs (`LocalAPI.installedHookCommand`; its `http://127.0.0.1:48151` is only
text, which is what makes a command Evlat's, `HookSettings.marker`). A
changed command must reach the agent: Claude Code took a changed
`UserPromptSubmit` command from `settings.json` at an open session's next
prompt (2.1.292, measured under a temporary `CLAUDE_CONFIG_DIR`, written in
place and by rename); Codex runs a
changed hook only once it is trusted again in `/hooks` (below, Pitfalls).

The move from the loopback port to the socket was a **one-time cut**, not
the rule: hooks installed by an earlier version do not keep talking to this one, and from here on the
socket's bytes are the fixed point that must keep talking unchanged. How
bytes from before the socket are recognised, and the update window and
automatic updates that move them, are the doc of `EvlatSocket.predates`,
`SetupTrigger`, `AgentIntegration.automaticScope` and `UpdatesModel`; a
server connecting does not open the window.

- The only author of the command is `LocalAPI.installedHookCommand(for:event:)`;
  the writers (`HookSettings`, `AntigravityHooks`, both behind `LocalHooks`)
  install nothing else and never touch other tools' hook groups.
- The command **fails silently** (`curl -m 2 … || true`) and **writes nothing
  to stdout**. The server's reply never reaches Claude Code — if it did, a
  stray JSON on `PermissionRequest` could grant or deny. `POST /hook` always
  returns `{}`.
- Golden-string tests hold it byte for byte, beside the agents in
  `Tests/EvlatAgentsTests/` (`LocalAPITests`). A failing golden string means
  the contract broke.
- The canonical vocabulary is Claude Code's. Everything source-specific lives
  in the adapter (the agent's `HookChannel.canonical`); a store or mascot rule that
  branches on `source` is a bug.

The status-line relay (`StatusLineRelay`) is the second installed contract: a
`sh -c` wrapper that preserves the user's original command's output and exit
code byte for byte (`EvlatAgentsTests.StatusLineRelayTests`); which
wrapper is Evlat's older one and which is the user's is its doc.

On this Mac an agent is one card in Settings → This Mac and one unit to
install (`AgentIntegration`). A relay edited by hand is not a part — never
written over, never taken out. The card's details remove the relay alone.
Every agent in the catalogue has a card; one not on this Mac is dim with
nothing to press.

The approval hook (`ApprovalHook`) is another installed contract, the same
bytes on this Mac and on a server
(`EvlatAgentsTests.ApprovalHookTests.testTheInstalledHookIsUnchanged`).
Unlike the hook command its stdout is the answer, and only the answer:
`-f` writes no error body, and `|| true` makes every failure — no socket,
a refusal, a channel gone, the time out — exit 0 with empty stdout, which
is no decision. The timeout, the agent's path under `/approval` and where
it is installed are the agent's `ApprovalChannel`. On a server Codex's is
part of the Codex card, and Codex's trust asks for it once (`/hooks`), as
for any hook new to it. It is the one hook
whose answer reaches the agent, so Evlat answers it only with the user's
press on the card — Allow once or Deny, never a rule, a folder or a mode —
or `{}`, which is no decision. An `AskUserQuestion` comes through it too;
its card offers the question's options, "Other…" (a line of its own,
`AnswerPanel`, since the bar never takes keys) and Deny, never a bare
Allow (`AskQuestion`; Codex's two answers are `CodexApprovals`'). It
authenticates no server: whatever answers on the socket decides. The
socket's folder is the user's alone (`0700`), here and on a server, so
that is a process of the same user, which could write the settings file
anyway.

### Local API

No TCP port on this Mac but the Docker sandboxes' (48152, below). Every
route is on **Evlat's socket**, `$HOME/.config/evlat/run/evlat.sock`
(`EvlatSocket`; `EVLAT_HOME` moves it, an absolute `EVLAT_SOCKET` names
it, a relative one is none). `48151` is left only as text: the host the
requests name (`http://127.0.0.1:48151/<route>`, which fills `Host:`
alone) and the root of the sandbox port (`LocalAPI.defaultPort`). Its directory is made `0700` and refused when it
is a link or another user's: the file takes the umask's mode, so the
directory is the guard (`UnixSocket.prepareDirectory`). A live socket is
another Evlat's and is left alone; a file nobody answers on is cleared and
bound.
Evlat's own clients speak there: a chat turn's hook, the askpass helper,
`evlat signal`/`watch` (`UnixHTTP`, one blocking HTTP/1.1 request), and
the installed hook commands and relay. A machine's listener is a socket
too, its channel's end, and takes `/signal` without a key.

Each listener has a role (`LocalAPI.Origin`): `.local` (this Mac's
socket) has every route and believes `X-Evlat-Pid`/`X-Evlat-Task`;
`.machine` (a channel's end) has `/hook`, `/usage`, `/approval`, `/signal`
and `/health`;
`.sandbox` (the one port, whatever its listener is told) has `/hook`
alone and is the one that believes `X-Evlat-Sandbox`. A route the role lacks is `404`, whatever the listener
holds (`Origin.role`, one `switch`).

| route | notes |
|---|---|
| `POST /hook`, `/hook/claude`, `/hook/codex` | installed hooks; always `{}` |
| `GET /health` | |
| `POST /usage/claude` | status-line relay; only `rate_limits` is read |
| `POST /permission` | inline hook of a chat turn; token-guarded, reply held until the user answers; `404` on a machine's channel and on the sandbox listener |
| `POST /approval`, `/approval/codex` | approval hook of terminal sessions (`ApprovalHook`), one path per agent (`RouteTable.approvals`); held until Allow/Deny on the card, or let go with `{}` once answered elsewhere; from a machine's channel too, held under that machine; `404` on the sandbox listener |
| `POST /signal` | external jobs; no key — an `X-Evlat-Key` an older sender adds is not read; `404` on the sandbox listener |
| `POST /hook/claude` on **48152** | the sandbox listener (`SandboxListener`), bound only while "Watch sandboxes" is on, for the command Evlat writes into a Docker sandbox; `.sandbox`, so the VM's `X-Evlat-Pid` and `X-Evlat-Task` are dropped and every other route is `404`. The only listener that trusts `X-Evlat-Sandbox`, checked |
| `POST /askpass` | the tunnels' `ssh` prompts, from the askpass helper; token-guarded (a running try's), held until answered or refused; `404` on a machine's channel and on the sandbox listener. The token is in `ssh`'s environment, which a process of the same user can read (`KERN_PROCARGS2`), so such a process could take a stored password during a try — accepted, as for `/approval` |

`/signal`'s body, its limits and a finished row's life are `SignalReport`'s
and `SignalsProvider`'s, and the website's `signal` page. It takes no key: a
socket — this Mac's, or a machine's channel end — is reached only by the
user's processes.

### Command line

The binary inside the bundle is also the CLI (`evlat watch`, `evlat
signal`; `~/.local/bin/evlat` is a symlink the app can install). `watch`'s
promise — the child's exit code, signal and bytes unchanged, nothing printed
when Evlat is closed — is `WatchTests`', against the compiled binary.
`argv` is classified by
`LaunchMode.of`: the app opens only with no arguments or with what the system
adds (`-psn_…`, `-NS…`/`-Apple…` pairs); an unknown word prints usage and exits
`2` — a new subcommand not added there does **not** fall through to the app.
With `EVLAT_ASKPASS` in the environment the binary is `ssh`'s askpass helper
instead (`LaunchMode`).

The server-side script (`RemoteCommand.script`, POSIX `sh` + `curl`, installed
to a remote machine's `~/.local/bin/evlat`) is the third installed contract:
marked and versioned, generated from the Swift constants, run under
`sh`/`dash`/`bash` in tests. A change to the script bumps its version. A
version above this build's is not called old (another Mac's newer Evlat
installed it).

What Evlat writes into a Docker sandbox (`SandboxInstall`, its file the
catalog's `Agents.sandboxInstall`) is the fourth installed contract: one
file of Evlat's own, `/etc/claude-code/managed-settings.d/evlat.json`
(`managed-settings.json` beside it is never touched), and a network rule
scoped to that one sandbox, `localhost:48152` (`--sandbox` always: without
it the rule would be every sandbox's). Its hooks run the sandbox twin of the
hook command (`LocalAPI.HookEndpoint.sandbox`); the Mac's command bytes are
unchanged. A running sandbox keeps the bytes it
was given, so they are pinned (`SandboxInstallTests`, the argv in
`SandboxInstallPlanTests`). The port is fixed (`LocalAPI.defaultPort + 1`):
it is written into every sandbox.

The website documents these contracts for users: `../evlat-landing/docs-src`
(the `evlat` command, `/signal`, remote servers) and
`../evlat-landing/src/pages/works-with.astro` (agents, terminals with a tab
link, Docker sandboxes; `sandboxes.astro` and `herdr.astro` beside it).
A change a user would notice there (a flag, a default, an exit code, a body
field, a limit, an agent, an entry in `TabLink.known`) updates that page in
the same piece of work. Each docs page lists the files it describes in
`docs-src/pages.json`; the site's build renders the pages, so there is
nothing to regenerate. Set `verified` to the release it now matches. The
site shows no version number, so a release with nothing user-visible needs
no website change.

### User files

`~/.claude/settings.json`, `~/.claude/statusline-*.sh`, `~/.codex/hooks.json`,
`~/.codex/config.toml`, `~/.gemini/config/hooks.json`,
`~/.gemini/antigravity-cli/settings.json`, `~/.local/bin/evlat`, `~/.openpeon/packs`
and login items belong to the user. **Agents do not write them.** Writers are tested against a temporary root
(`EVLAT_HOME`, or a `home:` parameter in tests); no writer has a default path.
So does the login keychain: no test or trial writes an Evlat entry to it.
Inside a Docker sandbox Evlat writes only its own file and that sandbox's
rule, and only while "Watch sandboxes" is on (above); no file of the user's
on this Mac. The rule is kept on this Mac by the `sbx` daemon, not by Evlat:
`sbx policy rm` takes it out when the switch goes off for a running
sandbox, and it goes with the sandbox when the sandbox is deleted.
The masters' sockets (`$TMPDIR/evlat`, `0700`) are Evlat's own; a stale one
is cleared, a live one — another process's master — is left alone.

Renaming a `UserDefaults` key silently loses the stored value; migrate it.

## Verification

| when | command |
|---|---|
| every change | `make all` (`swift build` + `swift test --parallel`) |
| inner loop | `make build` |
| one test | `swift test --filter EvlatCoreTests.RegistryTests` |
| the window server's side (real key, real screen) | `make test-desktop` — shows windows and takes the keyboard; not while the user types |
| a full bar to look at | `scripts/demo.sh [left\|right]` — an isolated Evlat filled with every kind of row (its header says which); `scripts/demo.sh stop` ends it all |
| window, bar, mascot or menu touched | `make test-desktop` (offstage, `make all`'s focus assertions hold trivially: nothing activates and the balloon's key is a flag), then `make bundle && make run` and look at it |
| install to `/Applications` | `make install` (the user's call — it replaces the installed app) |
| ship a version | `make ship VERSION=x.y.z` — the user's call: `release`, `git push origin main`, `publish` in one go |
| release build | `make release VERSION=x.y.z` — what it builds and needs is the `Makefile`'s |
| publish | `make publish VERSION=x.y.z` — the user's call: every installed copy updates from the release it creates |

`make run` and `make install` stop **both** copies (`build/` and
`/Applications/`) first: two Evlats race for the socket, and the one that
finds it held hears nothing. Processes are targeted **by path**, never by name.

Visual checks are not optional for UI changes: transparency, the right-edge
dock, the hover opening, focus staying with the front app. Use a real session
(`working → waiting → review`) at least once. What can be tested in code
(`canBecomeKey`, `activationPolicy`) goes to XCTest, not to the eye.

Every user-visible string lives in the catalog (`L10n.t("key")`), never in
code. Source language `en`; the translations are the website's languages
(`L10nTests.languages`; `tr` with full diacritics), with its words for the
phases. A new string enters
**every** table (`L10nTests` keeps the keys and their `{placeholders}` paired
and names the languages, so a table that stops parsing fails a test). A
`{count}` form is read for every count but one: in `ru` and `uk` it is
phrased so no plural agreement hangs on the number ("Сессий: {count}").
A new language is a new `lproj` folder named as Apple names it, its own
name in its `language.name`, plus its code in `L10nTests.languages`.

The language is the system's unless Settings → General → Language picks
one (`LanguageChoice`, whose doc says what was measured). Evlat's own text
changes at once (`AppController.applyLanguage`): `L10n.language` is a
variable now, so anything read as it is drawn — the menu, a notification —
needs nothing; the views that keep their words are built again by `.id` on
the language (the bar's column, card and usage block, the balloon, the
settings window and the setup panel), and the models that make lines when
they read are told (`languageChanged(to:)`). **Never the mascot**: it is outside the
rebuilt part, or its rhythm and keyframes would start over. A test that
changes the language puts `L10n.language` back.

## Isolation

Running a second Evlat next to the user's must not touch the user's state.
Any `EVLAT_` key but `EVLAT_TASK` makes a process isolated for the setup's
writers (`Isolation.isIsolated`); these are the ones with an effect of their
own.

| variable | effect |
|---|---|
| `EVLAT_SOCKET` | a second Evlat: its own socket, an absolute path (`EvlatSocket`; a relative one is none, never the user's) — the app binds it and `evlat signal`/`watch` post to it. Set, it is the one predicate of a second process (`Isolation.hasOwnSocket`, whose doc says what it then keeps in memory or leaves out). It still asks the user's running Bateri whether they are at a tab (`TabFocus`), a question that only reads |
| `EVLAT_PORT` | gone: a process with it set, blank included, says `EVLAT_PORT is gone; use EVLAT_SOCKET` on stderr and exits `2` — the bar, the diagnostics, help and the askpass helper alike (`LaunchMode.refused`). `watch` and `signal` still run but post nothing, as if Evlat refused (`SignalClient.post`): `watch` runs the command unchanged and prints nothing, `signal` says the one line and exits `1` |
| `EVLAT_SESSIONS` | session directory (empty dir = no sessions) |
| `EVLAT_HOME` | temporary home root for every writer |
| `EVLAT_MACHINES` | machines to tunnel to; their switches stay in memory |
| `EVLAT_SANDBOX_PORT` | the Docker sandbox listener's port; with `EVLAT_SOCKET` set there is no sandbox listener unless this is given |
| `EVLAT_SBX`, `EVLAT_SBX_SOCKET` | the `sbx` to run and the daemon's socket (given, `sbx` is not asked where it is); with `EVLAT_SOCKET` set no sandbox is watched or set up unless both are given (a fake `sbx`: `Tests/Fixtures/fake-sbx`). With `EVLAT_SOCKET` the "Watch sandboxes" switch stays in memory |
| `EVLAT_SANDBOXES` | `on`/`off` forces "Watch sandboxes" at launch; the stored switch is never written |
| `EVLAT_SSH` | fake `ssh`; it must run install scripts with a temporary `HOME` (`Tests/Fixtures/fake-ssh` runs calls in `FAKE_SSH_HOME`, prints the master's mark, makes the forward) |
| `EVLAT_CHATS` | temporary chat root |
| `EVLAT_PHASE` | force the mascot's phase at launch (the "Force state" menu item, scriptable) |
| `EVLAT_BODY` | force the body's mode (`always`, `smart`, `tucked`, `hidden`) at launch; the stored mode is never written |
| `EVLAT_<NAME>` | a chat backend's program to run, `EVLAT_CLAUDE`, `EVLAT_CODEX` (tests use `Tests/Fixtures/fake-claude`, `fake-codex-app-server`) |
| `EVLAT_EDGE`, `EVLAT_SELECT`, `EVLAT_SCROLL` | dock at `left`/`right`, open the list with a card up (`first` or an entity), open it scrolled — at launch, for looking and measuring; never written (`AppController`) |
| `EVLAT_MASCOT_PACING` | `continuous` takes the clips' waits out, for the in-clip leg of a measurement (`MascotPacing`) |
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
`EVLAT_PHASE=working EVLAT_SESSIONS=$(mktemp -d) EVLAT_SOCKET=/tmp/evlat-m.sock`,
binary started by absolute path.

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
- **`Data` indices are absolute in a slice.** `subdata(in: 0..<n)` on a slice
  that does not start at zero crashes; the listener's buffer is exactly such a
  slice. Use `startIndex`/`endIndex`. A test built from a zero-based `Data`
  literal does not see it.
- **A `PermissionRequest` hook does not hold the terminal's dialog.** In an
  interactive session the dialog opens the same instant the hook fires
  (2.1.285); whichever answers first wins. "No" or Esc in the terminal
  closes the held connection, but **"Yes" does not**: it stays open until
  the hook's timeout. The request carries no `tool_use_id`, so
  `ApprovalHook.resolves` reads the answer from the tool's outcome or the
  turn's end. A decision sent after the terminal answered is ignored.
  Requests are serialized per session.
- **Antigravity's hooks carry less than Claude's** (CLI 1.2.14, app 2.18.1).
  What they carry is `AntigravityHooks`' doc. The docs call `PreToolUse`'s
  `decision` output required; an empty reply let the tool run. In the app
  every conversation's hooks come from one `language_server`, so its rows
  live until the app quits: a passive row stays listed, and nothing ends
  them sooner. Workspace hooks (`.agents/hooks.json`) ran without a trust
  prompt, which is how this was measured without touching the user's file.
- **The Codex app runs no hooks.** In the app's own sessions (ChatGPT.app,
  `com.openai.codex`, bundled codex 0.154.0-alpha), four turns and an `exec`
  sent nothing to a `--capture` on 48151. Its settings listed the hooks as
  on, and a restart did not change it. The same `~/.codex/hooks.json` fired
  every event from the CLI and from the bundled binary's `exec`. Only Codex
  CLI sessions are tracked.
- **A running Claude takes managed settings live.** With the file written
  by `sbx exec -u root` and the rule by `sbx policy allow network
  --sandbox`, the same Claude's next message sent `UserPromptSubmit` and
  `Stop`; nothing restarted. Its `SessionStart` was missed, so that
  session has no start and [Go to session] brings the app alone. Set up at
  `started`, four of four new sandboxes were ready before Claude's first
  hook (setup 1.2–2.3 s). `sbx kit add`, by contrast, made a running
  sandbox again in 5.4 s and killed the Claude in it.
- **`sbx` carries the terminal's `TERM`, `COLORTERM` and
  `TERM_PROGRAM(_VERSION)` into the sandbox, not its tab link**
  (`BATERI_TAB_URL`, or any other variable, measured). Inside, nothing
  says which client a session belongs to; the `sbx` client on this Mac,
  not Apple-signed, has its tab in its environment.
- **A sandbox's hook to a closed Evlat fails at once.** Through the
  sandbox's proxy: a port in the sandbox's rule with nothing listening is
  `500` in ~10 ms, one outside the rule `403` in ~8 ms; no 2 s wait per
  event, also after Evlat is removed.
- **SIGINT ends Codex's app-server, not its turn**: no `turn/completed`
  comes. Stop is `turn/interrupt` on stdin (`turn/completed` with
  `interrupted` 40 ms later, measured); before the turn has an id there is
  nothing to interrupt and the process is ended.
- **A focus on the server moves the `--remote` view.** `herdr workspace
  focus` there changed the Bateri window's title — herdr's
  `{hostname}: {workspace}` of the client's view — from `~` to `plain`.
  `agent focus` takes the same path in herdr's source (`agent.focus`,
  then `focus_all_shell_clients_on_default_target`); it was not measured
  itself on `--remote`.
- **`sshd` leaves the socket file when the connection ends** (`-O exit`, a
  dropped network), and `StreamLocalBindUnlink` is the server's setting,
  off by default; a file in the way fails the next forward. The probe asks
  the file and removes it only when nothing answers (connect refused, or
  5 s of silence).
- **Codex runs a changed hook only once it is trusted again.** Its trust is
  a hash per hook (`config.toml` → `hooks.state."<file>:<event>:<group>:<n>"`
  → `trusted_hash`); with the command's bytes changed, `hooks/list` read
  `modified` and `codex exec` ran no hook and said nothing (codex-cli
  0.160.0, a temporary `CODEX_HOME`, measured). The TUI's `/hooks` trusts
  it again; what the TUI shows on its own was not measured.

### SwiftUI and AppKit

- **A struct `View`'s `let` is not storage.** Views are rebuilt on every parent
  update; a `Timer` publisher kept there is reborn each time and never fires.
  Use `@State` or `static`.
- **The `asyncAfter` trap: `self` in an `asyncAfter` closure is a copy of
  the struct `View`.**
  `@State` is read live; a `let` freezes when the closure is built. Anything
  read from the closure lives in `@State`.
- **`keyframeAnimator` fires on trigger *change*, never on first appearance.**
  If a branch switch rebuilds its owner from scratch, the transient animation
  never plays. Put its owner **above** the branches.
- **The rhythm trap: a phase change must not reset the mascot's rhythm.** A timer that restarts
  its wait on every change never blinks while the phase flaps. In a looping
  clip a phase change carries the pose and leaves the schedule alone.
- **The deadband: do not write `@Published` on every event.** Mouse movement arrives at
  display rate; without a deadband the whole bar re-evaluates at that rate
  (`GazeTracker.deadband`).
- **A `.nonactivatingPanel` that is key makes `NSApp.isActive` read `true`**
  while the front app, the menu bar owner and
  `NSRunningApplication.current.isActive` do not change. "Evlat did not come
  forward" is tested on those three.
- **Transparent window pixels receive no drags.** Of the bar's 485 pt envelope
  only the drawn 54 pt saw drag events: "near the bar" means the drawn bar.
- **`NSApp.deactivate()` is not synchronous.** Deactivate-then-`makeKey`
  lost the bubble's keyboard to the resignation that followed. Activate the
  previous app and bring the bubble back after `didResignActive`.
- **A window just moved or ordered front is not yet in the window list at
  its new bounds.** In one process, 0 of 40 `CGWindowListCopyWindowInfo`
  reads right after `setFrameOrigin` had the new bounds, 60 of 60 after one
  main-queue hop (a window just ordered front: 0 of 40, then 40 of 40). A
  read of the edge right after moving the bar reads the edge it left
  (`SetupFlowModel.readEdgeCoverSoon`).
- **A preference sent out of a `ScrollView` arrives once, empty.** Read
  positions inside with `GeometryReader` +
  `onChange(of: frame(in: .named…), initial: true)`.
- **A test run's windows land on the user's screen and keyboard.** Under
  XCTest every window is offstage (`WindowStage`). A new window or
  activation goes through `WindowStage` too.
- **An `NSWindow` subclass must not override `alphaValue`.**
  `window.animator().alphaValue = 1` called the Swift override with the
  animator proxy as `self`; `super.alphaValue` then crashed
  (`EXC_BAD_ACCESS` in `-[NSWindow setAlphaValue:]`). Clamp the value at
  the call site instead (`WindowStage.alpha`).
- **An accessory app's `NSApp.activate()` is only a request** (cooperative
  activation, macOS 14+). Opened from the menu, the settings window was
  ordered behind the front app, which kept the keyboard. A window the user
  asked for makes Evlat `.regular` while it is open.

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

### Measuring and running

- **The tests run in parallel** (`make test`), in worker processes, one per
  core. A new test takes a free port and a temporary folder, never a
  fixed one, and a bound on time leaves room for a loaded machine: a 2 s
  bound on a read that waited on nothing measured 2.5–2.9 s with the suite
  running beside it.

- **A capture of a window not on screen is its last frame.** With Bateri
  off screen, `screencapture -l` of one of its windows showed a progress
  counter minutes old, while the window titles
  (`CGWindowListCopyWindowInfo`) changed at once; a capture of the herdr
  window could not say whether its view had moved. Read such a change
  from the title, or bring the window on screen first.

- **Measure a binary started by absolute path.** A relative path is invisible
  to `pgrep -f` and to the Makefile's guard.
- **An empty `EVLAT_SESSIONS` does not isolate; `EVLAT_SOCKET` is needed too.**
  With the real Evlat closed, the measured process takes the user's socket
  and live sessions' hooks flow into it.
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
