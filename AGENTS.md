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

A release bundle's plist (`bundle-app.sh`) has Sparkle check hourly
(`SUScheduledCheckInterval`), download and install on quit by default
(`SUAutomaticallyUpdate`, Settings → General → Updates, Sparkle's own key),
and ask about a download Evlat was not quit for after a day
(`SUScheduledImpatientCheckInterval`). Sparkle's window opens again at every
check, so a scheduled one is Evlat's to show (`UpdateReminder`): a version
at once, then not again until a day after it was last shown; the menu's
update line names it meanwhile. While Sparkle holds a window it checks
nothing more, so the day's end is Evlat's timer, and a newer release is
seen only after the held one is answered; with a download waiting, only
after it is installed. The last showing is in Evlat's defaults
(`update.shown.*`), in memory when isolated. Evlat never relaunches itself
to install: that would end a chat's turn and lose the hooks' news.

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
- The chat can be switched off (Settings → Chat's first switch,
  `chat.enabled`, on when nothing is stored). Off, nothing opens the
  balloon (`openChat` refuses): the mascot's click is taken and does
  nothing, a dragged file is not caught, the shortcut is not registered
  (its own switch is kept) and leaves the menu, and a chat's card has no
  `[Back to chat]`. Turning it off stops every running turn as Stop does
  (`ChatStore.stopRunning`, not quitting's SIGTERM) and closes the balloon;
  the rows stay, and a chat's finish while it is off enters silently (no
  peek, no sound) and stays news until seen.
- A chat runs on the backend selected when it was made (Settings → Chat,
  `chat.backend`) and keeps it; its session id is the agent's own when the
  first turn names one (Codex's thread). None stored, it is the first
  backend in the catalogue whose program was found and kept
  (`ChatStore.firstFoundLane`, `AgentLocator.isFound`), else the
  catalogue's first — derived each time, never written; a pick in
  Settings stores even the backend now derived. The balloon looks
  a program up only where the answer depends on it (`ChatStore.locateBackend`):
  nothing stored and a backend ahead of the first found one not found
  yet (in order, stopping at the first hit; with none found yet it is
  `looking` meanwhile and sends nothing, and a hit not kept — the inherited
  `PATH` alone — is the derived backend until the next search), or the
  chat's or stored backend missing. An open chat's
  missing program, or a stored one's while another's is there, is
  `chat.missing`; no program at all names no agent and links each
  backend's `installPage`, opened in the browser behind the app in front.
  The conversation itself is the agent's: Claude Code and Codex write it
  under their own homes (`~/.claude`, `~/.codex`), Evlat keeps only the
  index.
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
| `signal` | external jobs | `POST /signal` on a socket, no key; sent by `Evlat watch` / `Evlat signal` | manual |

An agent can be switched off (Settings → This Mac, its card's switch; the
setup's agent step). The set is `agents.enabled` (`EnabledAgents`): nothing
stored is the agents found, asked live each time, and it is written only by
the user's change — a second Evlat (`EVLAT_SOCKET`) keeps it in memory.
An agent off has no session row: `Registry.signals()` drops it **after**
the merge, `kind == .session` only, by asking whether the row's `source` is
in the set (a file row and a hook row go together; a remote machine's rows
answer to that machine's set, `Registry.machineSources`, by
`Signal.Machine.id`). Its usage provider is unregistered, so its windows
go with it. An approval request from an agent switched off where it runs
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
listener that believes `X-Evlat-Sandbox` (the sandbox's name,
`[A-Za-z0-9._-]{1,64}`); every other listener deletes it. Its rows are one machine's, `-sandbox` (a leading
`-` is refused as a target, so no remote machine can have it), each drawn
under its sandbox's name (`sbx` when none was sent). Its agents run on this
Mac, so its rows answer to this Mac's switches (`AppController.machineSources`),
not a machine's set. While it listens a row is not dimmed
(`HooksProvider.setLink`). It has no usage, no `/signal` and no approval
card.

It is one switch, Settings → Docker sandboxes → "Watch sandboxes"
(`sandboxes.enabled`, off when nothing is stored; the setup's optional
step offers it, and the Claude Code card points there, only where `sbx`
is found). Only while it is on does the listener bind, and only the
process that bound it runs the watcher (`SandboxWatcher`): it hears the
`sbx` daemon's lifecycle events (`GET /events` on `sandboxd.sock`, chunked
NDJSON, undocumented and internal — read as derived, a word it does not
know counted, the stream opened again on the core's growing delay,
`SandboxDaemon`; transport `SandboxDaemonLink`). On connect it lists the
sandboxes (`sbx ls --json`) and sets up every running one of
`Agents.sandboxAgent`'s; then each `started` one. `stopped`/`deleted`
drops that sandbox's rows (`HooksProvider.forget(sandbox:)`); a lost
stream drops none. A stopped sandbox is never `exec`'d — that starts it.
Turned off, Evlat's file and rule come out of every running sandbox; a
stopped one keeps the file, which speaks to a closed port, and no record
of it is kept. Settings lists what the last list said, one tag each, and
one status line (the port taken, the socket path too long for a unix
address, `sbx` not running, a version other than the measured 0.46.0).

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
read from the settings window's own reading once it has one — the re-read
after a press — else from the channel's; a missing part or a usage line
alone is none, as on this Mac.

Each machine's tunnel is Evlat's **own `ssh` master** (`-M -S <socket>
-o ControlPersist=no`, socket under `$TMPDIR/evlat`, its path a parameter
that must fit `RemoteTunnel.socketPathLimit`); the installs and reads ride
it (`-S <socket> -o ControlMaster=no -o BatchMode=yes`) and connect on their
own when there is none. Its stdin is the dead man's switch. `ssh` gets
Evlat's environment, `SSH_AUTH_SOCK` kept, plus — only while this Mac's
listener is bound — the askpass variables (`SSH_ASKPASS` = this binary,
`SSH_ASKPASS_REQUIRE=force`, `EVLAT_ASKPASS=<token>:<socket>` — the token
in front, its length fixed, so the socket's path is everything after the
first `:`), with
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

Over the master runs the machine's **channel**: the server's socket,
`~/.config/evlat/run/evlat.sock` — the one its installed commands speak
to, as this Mac's do here — forwarded to a socket of the machine's own
beside the master's (`RemoteTunnel.channelPath`, `<socket>.sock`), where the
machine's listener (`.machine`) is. No TCP port is opened on the server.
In order, each step on the last: the master's remote command prints a mark
on a line of its own (`echo; echo <mark>; exec cat`: a login script's last
words may end with no newline), read from its stdout (drained to the end,
so a login script that talks never stalls it); one `sh -s` over the master
probes and reads the machine (`RemoteTunnel.channelProbe` in
`RemoteSettings.readingScript`): it makes the folder `0700`, asks a socket
there for `/health` — an answer within 5 s is another Evlat's, another
Mac's, and nothing is touched (`channelBusy`); a refusal or silence is a
dead connection's and the file goes; then `ssh -O forward -R
<absolute server socket>:<this Mac's>` over the master. Only a forward made
is `connected` (or a request heard on the listener first); a forward that
fails after a free probe is `forwardingRefused` (after a file the probe
could not ask, with no `curl` that reaches a socket, it is `other`: the
file may be the cause). Either failure closes the
master and waits on the schedule. No master (no path fits, another
process's live one) is no channel: the try ends as `other`. A try with no
channel `RemoteTunnel.defaultChannelDeadline` (30 s) after its launch or
its last prompt's answer ends as `other` too. The probe's reading fills the
machine's rows in Settings (`RemoteTunnels.reading(of:)`). The probe and the
forward run on a queue of their own (`RemoteInstaller`), without the jobs'
lock. A channel's end swept from `$TMPDIR` is bound again before the next
try (`RemoteTunnels.endpointIsThere`): `-O forward` does not look, and would
carry events to a path nobody listens on.

A server tells one Mac at a time: a second Mac connected as the same user
reads `channelBusy` until the first one's connection ends. A server whose
`sshd` allows no socket forwarding (`AllowStreamLocalForwarding no`,
`DisableForwarding yes`, and `AllowTcpForwarding no`, which turns it off
too) cannot be used. A home on NFS and a home whose socket path passes a
unix address (103 bytes) were not measured.

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
A reminder due while the user is at the session's tab (below) is not
given: the wait or the finish is timed again from then. Reminders due
together still make one sound, once each tab has answered (`SoundBatch`).
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

**At the tab, the news is quiet.** A lone new finish whose peek, dot or
sound would tell it, a lone wait that begins with its sound on, and a
reminder come due first ask whether the user is at that session's tab
(`AppController.isAtTab`): a session on this Mac, or a remote one whose
server can be asked (below; a Docker sandbox's is not: no pid here, no
server), whose walk reaches a terminal that says so
(`TabLink.focusSince`; today Bateri, `TabFocus`) — its pane focused,
input within 120 s (not measured), the screen unlocked. At it, nothing
sounds or peeks; the finish is still told (`toldFinishes`), so it is
reminded of like any told one, and a reminder is timed again. Focus is
never "seen": the face, the ring and the news stay. Every other answer,
none in time, or no terminal to ask, tells it as before; an answer that
comes late tells only what still holds (the bar and the balloon closed,
the row still news or still the same wait; a reminder keeps its own
rule). Several finishes at once, or several waits that begin at once, are
told without asking: being at one's tab says nothing of the others. With
no terminal that can say running, nothing is walked and no server asked.
The walk is the shallow one (`SessionHost.resolveShallow`): a session in
a tmux or herdr pane is not asked about, since its client's tab may show
another pane. A remote session is walked only when its server walked
from the agent itself (`RemoteHost.Connection.direct`), and here only
from one `ssh` that carries no other (`Ssh`'s `shallow`: no riders, not
herdr's master, no candidates too close to tell apart, no local
multiplexer on the way).

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
- **The one continuous motion is outside SwiftUI**: `working`'s arc is a
  `CAShapeLayer` turned by Core Animation (`SpinningArc`, 30 fps at most), so
  only `waiting`'s wave keeps the beat clock. Measured on a release build,
  one working row, the mascot forced idle, 90 s: Evlat 1.33–1.41% against
  1.29–1.51% with no row, where a turn per beat cost 3.97–4.16%. The render
  server pays instead — WindowServer rose by some points, not pinned down: a
  video playing behind moved its own baseline between 34% and 44%.
- The mascot reduces to a handful of animatable numbers (`MascotPose`); SwiftUI
  springs are interruptible and keep velocity, so a state change never snaps.
  Expression lives in the pose; the body shape is swappable.
- **A mascot nobody can see does not move.** In the hidden body modes the
  mascot is out of sight below the peek (`MascotModel.isShown` false): its
  clips leave the tree and the gaze monitor stops, so a hidden idle bar
  produces no frames and reads no mouse. The sliver and its dot are static.
  The mascot's view stays in the tree at every level, so `failed`'s shake
  (a `keyframeAnimator`) still fires on the way into the peek.
- **Smart hide's edge costs no new timer**: it is read on the existing
  1.5 s poll, one window list a tick. Measured on a release build, no row,
  the left edge under another app's window, the mouse still (screen locked,
  HID idle 5–15 min), 90 s: Smart (covered, reading) 0.09% and 0.18%,
  Tucked (not reading) 0.12% and 0.07%, Always out 0.09% and 0.08% — the
  reading lies inside the runs' spread. A clear edge is not measured (the
  user's window covered both edges): it is Always out's bar plus the
  reading, and with the mascot out the gaze follows the mouse as Always
  out's does.

### Window

- The bar is an `NSPanel` with `.nonactivatingPanel`: **clicking the bar must
  never take focus from the front app.**
- **The window reaches above the bar's head** by `AppController.headroom`
  (190 pt), transparent: a card opens level with its row and, only when its
  measured height would leave the screen's visible part, rises as far as it
  must — a held question is up to 618 pt, more than the room under the head
  on a 900 pt screen with the Dock below. Every measure that names the top
  (`slotTop`, `listTop`, `isOverMascot`, `BodyPresence.Area`) is from the
  head, and every point read from the window takes the headroom off first.
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
  forward only if the walk still reaches one. A chain that reaches no app
  and passes no multiplexer's server is taken up again at its terminal's
  pty master: the processes holding it (their descriptors, `/dev/ptmx` by
  `PROC_PIDFDVNODEPATHINFO` — no permission) are walked, never past that,
  and only when all reach the one same app is it the host; the tab is
  still the walked process's own. Each multiplexer is one
  type conforming to `Multiplexer` (`Herdr`, `Tmux`), listed in
  `SessionHost.multiplexers`. A herdr pane is found from the process, not
  the agent's environment: over the server's own API socket (`herdr.sock`,
  among its unix sockets; `HerdrSocket`), `pane.list` and each pane's
  `pane.process_info`, the pane whose shell (else a foreground process) is
  the walk's last process before the server; the click selects it with
  `pane.focus` before the app comes forward, which comes whether or not it
  could (`HerdrPane`). One user action's herdr calls — the card coming up,
  or a click's lookup and selection — share one 0.25 s deadline (monotonic,
  from the first call), past which nothing more is sent; `--list` says what herdr answered (`HerdrLookup`).
  The tmux query above is the only process Evlat runs to find and open a
  local session: the server's own executable, fixed arguments, checked
  values, no shell, and a command that only reads. The value is checked
  (`TabLink`): `metalterm://tab/restart` is an action, not a tab.
  The news asks one more (`TabFocus`, above): `bateri focus --pid <pid>
  <tab>`, the running copy's own executable, those arguments alone, no
  shell, `HOME` its whole environment, killed at 1.2 s, on a queue of its
  own, and only for a copy whose `Info.plist`, read from disk at each
  question, says 0.4.0 or newer. It only reads. Bateri 0.3.0 opened a
  window for a word it did not know, and from 0.4.0 a first argument that
  starts with `-` still does (`--help`, measured on 0.5.0): the arguments
  never change.
  Setting sandboxes up is the one place Evlat runs `sbx` (`SandboxRunner`,
  found as `EVLAT_SBX` or on the login `PATH`), only while "Watch
  sandboxes" is on: `sbx version` and `sbx ls --json`, which only read;
  per running sandbox `sbx policy allow network --sandbox <name>
  localhost:48152` and `sbx exec -i -u root <name> sh -c '…'` with the
  file on stdin; and, turned off, `sbx exec -u root <name> rm -f <file>`
  and `sbx policy rm network --sandbox <name> --resource … --force`.
  Argument vectors, no shell on this Mac, one job per sandbox at a time on
  a serial queue, 30 s each at most; a name from the daemon goes into an
  argv only once checked (`SandboxInstall.isSandboxName`). A job reads
  `sbx ls --json` again when its turn comes and runs nothing for a sandbox
  not running then: `sbx exec` starts a stopped one. The daemon's stream
  counts as connected only once its head is the `200` NDJSON measured; a
  refused one sets nothing up and is said in Settings.
  A remote session whose agent keeps session records
  (`Agent.sessionRecords`; Claude Code's) is asked of its server once per
  card, off the main queue (`RemoteHostLookup`), and once more as a finish, a wait's sound or a
  reminder of it is about to be told (`AppController.findRemoteForNews`), by a lookup
  of its own on a queue of its own whose call is ended at 1 s, so a card's
  stuck question never holds a finish: a read-only `sh` script
  (`RemoteHost`), never installed, over the machine's live tunnel master
  only (`ProxyCommand=/usr/bin/false`: a gone master is no call, never a
  login; a call past 10 s is ended), with the session id checked as a
  UUID. The record's pid counts only if its process started within 120 s
  of the record's `startedAt` (pids are recycled). It walks the agent's
  parents to its connection's `sshd` (the one under the listener) and says
  `SSH_CONNECTION`'s ports and server address, that `sshd`'s start and its
  own clock, after a line of its own, `direct`: the one answer the news
  walks. In a
  tmux or herdr pane it walks from the client instead, by this Mac's rules:
  tmux's client of the pane's session that did something last, asked of
  the server's own executable (`<proc>/<pid>/exe`, `timeout 2` where there
  is one) once `TMUX` names an ancestor that is tmux; herdr's newest client
  with a terminal connected to its server's `herdr-client.sock` (the
  server's ends from `/proc/net/unix` and its `fd` links, their peers from
  `ss -x`) — or herdr's own ssh bridge, which has none: exactly `herdr
  [--session <name>] remote-client-bridge [--idle-timeout-v1]`, how
  `herdr --remote` reaches the server. In a herdr pane it also finds the agent's pane by this Mac's
  rule — the agent's `HERDR_PANE_ID` first, else `pane list`, each pane's
  `pane process-info`, keeping the id herdr answers with — and says
  whether herdr takes it as an agent's (`agent get`), with the server's
  own executable and `HERDR_SOCKET_PATH`, each call under `timeout 2` and
  none without it. Unlike this Mac's `pane.focus`, only an agent's pane
  can be selected there: herdr's CLI focuses a pane by id only through
  `agent focus`, and a raw socket client is not sure to be on a server.
  The card's words follow it as they do here. No client attached is said as `none`, which is no
  button; a pane it cannot ask says nothing, and never falls back to the
  pane's own, stale `SSH_CONNECTION`. A terminal that also hands its tab link in an
  `LC_*` variable, which `ssh`'s default `SendEnv`/`AcceptEnv LANG LC_*`
  carries, lists the name in its `TabLink` entry (`forwarded`; Bateri's
  `LC_BATERI_TAB_URL`): the script gets the table's names as checked
  arguments (`LC_[A-Z0-9_]{1,64}`, 16 at most) and knows no terminal, and
  prints the ones the same process has (a value past 512 bytes is cut and
  refused, never taken for whole). On this Mac such a value only fills the
  tab the walk below could not read, by the rule of the app the walk
  reached and not past a multiplexer's server; it never picks the app,
  since whatever a tab starts inherits it. The candidates are the
  user's `ssh` processes connected to the same end as Evlat's own tunnel
  `ssh`, or to the server address the script said, never its loopback
  (`Ssh`, `PROC_PIDFDSOCKETINFO`): one host can be two ends, and a
  `.local` name gave the tunnel its IPv6 and Bateri's `ssh` its IPv4.
  Then the exact client port, else the only one (unless its start is >
  10 s off), else the start nearest the connection's (≤ 2 s, every
  other > 10 s), else the app alone if all are in one, else no button. A
  pick that is the user's own `ControlMaster` with other `ssh` riding it
  is the app alone too, with the tab only where the session's forwarded
  value fills the same one for every rider. A master detached by
  `ControlPersist` (parented to launchd) is in no app and stands for its
  riders alone: Bateri's own `ssh` is one, and the session's forwarded
  value names its tab. herdr's own master is one too, but its riders are
  children of the `herdr --remote` in the tab, and that `herdr` is walked
  instead (its environment can be read; several on one master give the
  app alone).
  Saved machines (`herdr machine add`) start their bridge from another
  path (`--idle-timeout-v1`, not under `--remote`) and were not measured:
  this rule leaves them to the detached master's riders. From that
  `ssh` the walk is the local one. The card shows the button only once
  found, says nothing while searching, and keeps the answer for its life:
  the click walks this Mac again and does not ask where again. The one
  exception to "only reads": a session in a herdr pane on its server has
  that pane selected at the click — another fixed script on stdin, never
  installed, over the same live master only, on the same serial queue,
  argument only the checked session id (`RemoteHost.selectScript`,
  `RemoteHostLookup.select`). It finds the record, the process and the
  pane again by the same rules, and its one command that changes anything
  is `agent focus <pane>`; only a pane the lookup said herdr selects is
  asked for. The window waits for its answer at most 1 s
  (`DetailModel.selectWait`), off the main queue, and comes whether or not
  herdr took the pane; a selection still queued then is not made, and one
  running is ended at 3 s. Measured over the master, 37–112 ms. A herdr
  pane on this Mac on the way to the tunnel is walked to again when the
  window comes, under a deadline of its own: the click's was spent waiting. A card that
  could not ask (no live master) asks on the next snapshot. A Docker sandbox's
  session has no pid here and no server to ask: its terminal is a live
  `sbx run` client on this Mac with a terminal that names the sandbox
  (`--name <name>`, or, unnamed, `<agent>-<last part of its folder>`), read
  like any process (`Sandbox`), and one that started after the session did
  is another session's. The session's start is when its
  `SessionStart(startup)` reached this Mac. With that start heard, one
  candidate is its tab if it started within 30 s of the session
  (`Sandbox.aloneWithin`; creating a sandbox measured 14 s), and several
  are told apart by start through the rule shared with the `ssh` lookup
  (`StartMatch`: nearest ≤ 5 s, every other > 10 s). One client is one
  session's, so a sandbox's sessions with a start heard are matched
  together, in order of start: a client an earlier session took is not a
  later one's candidate (two tabs 3 s apart left the second session two
  clients 4.5 s and 1.5 s away, none told apart; `Sandbox.claimed`). A
  session with no start heard claims nothing. No start, a lone one
  farther, none told apart, or every client an earlier session's, brings
  the app alone if they are all in one, never a tab, else no button. No
  candidate: no button,
  and the card says "No terminal open" — unless an `sbx run` client names
  no sandbox that can be read (an option not read whole, a folder no hook
  name could match), which says nothing.
  The branch stays with local rows; a server's card answers its own
  approvals (`ApprovalStore.request(forSession:machine:)`, by the row's
  machine and the session's own id, never the namespaced entity).
- **The body can hide** (Settings → General → Body: Always out, Smart hide,
  Tucked, Hidden). Tucked is in at rest: the sliver, a peek while waiting
  or at a finish (its three switches). Smart hide is Tucked while another
  app's window is under the edge, and the whole body while none is
  (`edgeClear`); the switches are shown under both. A stored `smart` is
  the new Smart hide, `tucked` is Tucked. Covered (`EdgeCover`): a window
  on screen, in layer 0, alpha above 0, not Evlat's pid, overlapping the
  closed body — 54 pt × its closed length from the head, never shorter
  than the trigger strip (`BodyPresence.area`'s rule) — on the bar's own
  window, found in the same list by its number (no translation between
  the window server's and Cocoa's coordinates; no alpha threshold, so a
  near-clear layer-0 window keeps the edge covered — the quiet side). Only
  under Smart, on the poll's tick (`pollEdge`; not in `refresh`, which a
  hook burst runs twice in milliseconds), the open bar and the balloon
  included. A new state takes two readings in a row that agree (every jump
  seen in use was one reading); a reading that cannot tell (`nil`: the
  bar's window not in the list) is not counted; the first reading since
  Smart began — at launch, at the switch, after a move to another edge or
  screen — is applied as it is. A body that is in does not come out under
  a still cursor on its place (it would open the bar at the next move);
  that reading waits for the cursor to leave. The
  live reader is set in `applicationDidFinishLaunching` only, so no test
  reads the user's windows (`edgeReader`, a fake in tests). Each state
  applied, and the first reading since Smart began, is a line on stderr
  (`Evlat: edge …`). One pure rule, `BodyPresence`, turns the mode, its
  three switches, the edge, the effective phase, the finish latch, the peek,
  the open bar, the balloon and a drag into a level — `none · sliver · peek
  · full` — and its hover and drop area; `AppController.applyPresence()` is the only writer of what
  follows from it (panel area, drawn level, `isShown`, gaze, tray icon). The
  level is not a `Phase`. At rest in the hiding modes (`none`, `sliver`) the
  hover area is a 5 pt band from the head to 60 pt below where the
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

The news reads whether the screen is locked from the window server's
session dictionary (`ScreenLock`), with no permission. Measured on macOS
26.4.1: unlocked, `CGSSessionScreenIsLocked` is not in it at all; locked
(⌃⌘Q), it is `true`; after a wake from sleep, not measured. A missing key
is unlocked; no dictionary is locked.

Smart hide reads other apps' window **bounds** with no permission
(`CGWindowListCopyWindowInfo`; measured on macOS 26.4.1: without Screen
Recording every normal window came with its bounds and owner and none
with its name, and no prompt opened). Only bounds, layer, alpha, owner pid
and number are read (`EdgeCover`); a window's name — what Screen
Recording guards — never is.

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
behind. Tests (XCTest present, `make test-desktop` included) and a
second Evlat (`EVLAT_SOCKET`) keep passwords in memory
(`MemoryPasswordStore`) and never touch the keychain.

## Contracts

### Hook contract

The fixed point is the command already **installed** in the user's
`~/.claude/settings.json` / `~/.codex/hooks.json` — on this Mac and on a
server, the same bytes. It speaks to the socket under the home where it
runs: `curl -q -s -m 2 --noproxy '*' --unix-socket
"$HOME/.config/evlat/run/evlat.sock" … http://127.0.0.1:48151/<route>`.
The URL is text: it names no port that is dialled, and it is what makes a
command Evlat's (`HookSettings.marker`), so the bytes before the socket —
`curl -s -m 2 … http://127.0.0.1:48151/…`, every earlier version's — read
as Evlat's older command, "needs update", and one press moves them. No
port listens for them any more: an older command, relay or `http`
approval hook stays silent until it is moved. A
changed command must reach the agent: Claude Code took a changed
`UserPromptSubmit` command from `settings.json` at an open session's next
prompt (2.1.292, measured under a temporary `CLAUDE_CONFIG_DIR`, written in
place and by rename); Codex runs a
changed hook only once it is trusted again in `/hooks` (below, Pitfalls).

That move was a **one-time cut**, not the rule: hooks installed by an
earlier version do not keep talking to this one, and from here on the
socket's bytes are the fixed point that must keep talking unchanged. The
cut is told where the user looks, in the bar's words. Bytes from before the
socket are recognised by one pure rule (`EvlatSocket.predates`: a string
naming Evlat's url and not the socket — the TCP command, its relay, the
`http` approval hook — in any file shape; `AgentIntegration.predatesSocket`
per agent). With them, an old hook's menu line says what it costs
(`setup.attention.hooksOutdated`: Evlat can't hear its sessions; an old
hook still on the socket is only "old", `hooksStale`), and the paragraph
of the update window names the cut. That window opens by itself at every
launch while an agent switched on here has old hooks
(`SetupTrigger.updatesAtLaunch`; `setup.socketCutShown`, its once-only
mark before, is no longer read), never in an isolated process
(`Isolation.isIsolated`), never when the setup opens at that launch; a
server connecting does not open it. Its footer's box, "Keep these up to
date automatically" (checked unless turned off; "Update all" writes it, Later does not),
is `updates.automatic`, also Settings → General → Updates (in memory when
isolated, off when nothing is stored). On, Evlat updates its parts
itself — this Mac's at launch and when it is turned on, a server's as it
connects (once per process, once its job started) — through the same model and writers, but only what an older
copy wrote (`AgentIntegration.automaticScope`: old hooks; a usage line
taken out stays out, one changed by hand is left; nothing for an agent
switched off or not installed), and opens the window on its results only
when something is left to the user: a step (Codex's `/hooks`) or a
refused write (`SetupTrigger.opensResults`). A server's old parts are a
machine line (below). The window
(`UpdatesModel`, `UpdatesWindow`) lists this Mac's agents switched on with
old hooks and every server not known to be current — not connected yet
("checked once it connects", read again as it connects), its channel
refused (the short reason, the advice behind "Why?"), or old — each with
its card's one press: `SetupModel.perform` here, `RemoteMachinesModel.update`
there (the old agents' `Change.agent` and an old `evlat` command, in one
job under the machine's lock). "Update all" runs them in that order, a
server's job waited for before the next. The menu offers it as "Review
updates…" beside an old hook's or a server's line. It grows with its
content up to its screen's visible frame less a margin, centred, never off
it; past that only the two lists scroll (`UpdatesWindow.fit`, pure).

Settings' side list groups the three places Evlat writes its parts into
under "Connections": This Mac (`agents`, the agent cards, the git branch
and, last, the `evlat` command — no section of its own any more), Servers
(`remote`) and Docker sandboxes (`sandboxes`); the raw values are
`EVLAT_SETTINGS`', and `command` opens This Mac scrolled to the command
line (`SetupAttention.Anchor`), as the command link's lines do. On top of
This Mac and Servers a strip reads the same model (`UpdatesModel.strip`,
no state of its own): amber with "Update all" while an agent there has old
hooks (a server's old `evlat` command alone is heard, and left to the
window; the press is the window's, on the window it opens afresh, and the
box there writes no choice), else — automatic updates on — amber with
"Review" for a step they left, until Review showed it (Evlat cannot see
Codex's `/hooks` trusted), then calm blue naming what they wrote this run
and when (`UpdatesModel.kept`, which a fresh opening of the window keeps
and a removed server leaves); Review opens the window on those results.
Docker sandboxes has none.

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
code byte for byte (`EvlatAgentsTests.StatusLineRelayTests`), its `curl`
to the same socket (`--noproxy "*"` and `"$HOME/…"` double-quoted inside the
wrapper's single quotes). A wrapper with the relay before the socket is
`outdated`, not `modified`: an install takes its original out and wraps it
again without a new backup (the one it has is the user's line from before
any wrapper), and a removal takes it apart. Only a wrapper no copy of Evlat
wrote is `modified`.

On this Mac an agent is one card in Settings → This Mac and one unit to
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
`PermissionRequest` group, `{"type":"command","command":…,"timeout":T}`,
the same bytes on this Mac and on a server: `curl -q -sf --noproxy '*'
--unix-socket "$HOME/.config/evlat/run/evlat.sock" -m T … --data-binary @-
http://127.0.0.1:48151<path> 2>/dev/null || true`
(`EvlatAgentsTests.ApprovalHookTests.testTheInstalledHookIsUnchanged`).
Unlike the hook command its stdout is the answer, and only the answer:
`-f` writes no error body, and `|| true` makes every failure — no socket,
a refusal, a channel gone, the time out — exit 0 with empty stdout, which
is no decision. The timeout is one constant of the agent's channel in
three places: the hook's `timeout`, `curl -m`, and so how long a card can
wait (Claude: 600; Codex: 120, since its dialog waits for the hook). The
core writes the group and names no agent; an
agent's `ApprovalChannel` gives the wire (`request`, `body`), its path
under `/approval` (Claude's is `/approval` itself, Codex's
`/approval/codex`; `RouteTable.approvals`) and where it is installed
(`installs`: Claude's on this Mac and on a server, Codex's on a server
only). It is Evlat's by the command with `127.0.0.1:48151<path>`, and
the `type: "http"` hook earlier copies installed at that url is Evlat's
older one: outdated, replaced in place, removed with it. It is part of
the Claude Code card, here and on a server, installed and removed with
the command as one (`LocalHooks`, by target); the command alone reads
outdated, which is how a copy from before it is offered the update. On a
server Codex's is part of the Codex card the same way, and Codex's trust
asks for it once (`/hooks`), as for any hook new to it. It is the one hook
whose answer reaches the agent, so Evlat answers it only with the user's
press on the card — Allow once or Deny, never a rule, a folder or a mode —
or `{}`, which is no decision. An `AskUserQuestion` comes through it too;
its card offers the question's options, "Other…" (a line of its own,
`AnswerPanel`, since the bar never takes keys) and Deny, never a bare
Allow, and answers with `updatedInput` + `answers` (`AskQuestion`).
Codex's answer is its own two measured shapes, `allow` and `deny` with a
`message` (`CodexApprovals`), never `updatedInput`, `updatedPermissions` or
`interrupt`, which it fails closed on; it asks no question. It
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
directory is the guard (`UnixSocket.prepareDirectory`; the folders made on
the way keep the default mode). A folder an `EVLAT_SOCKET` names is the
chooser's: only checked to be a directory, links followed, never changed
(`HookListener`'s `ownsDirectory`). A live socket is
another Evlat's and is left alone; a file nobody answers on is cleared and
bound; `stop()` removes the file only while it is still the one it bound.
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

`/signal` body: `id`, required `ttl` (`0` drops the row; ≤ 24 h, finished rows
≤ 1 h), `phase` (`working·waiting·done·failed`), `label`, `progress` 0…1,
`detail`, `sender`; errors are `400` with a stable `code` (`SignalReport`).
The server writes the identity (`signal:<id>`, `.manual`), at most 32 rows.
`working`/`waiting` live by their `ttl`. On a finish (`done`/`failed`) the
`ttl` is only validated: the row stays until the user has seen it, at most
12 h after it finished, and counts against the 32 while it waits; `ttl: 0`
still drops it at once. The "600 s" in `evlat signal`'s help is the value it
sends, not the row's life.
It takes no key: a socket — this Mac's, or a machine's channel end — is
reached only by the user's processes, and through a channel the machine is
the listener's. No key file is written; one an older version left is not
read, and neither are a machine's stored keys (`remote.signalKeys`, from
version 1 of the server's command) — the value is left where it is.

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
`watch` and `signal` post to Evlat's socket by the app's own rule, keyless;
no socket there is silent and immediate. With `EVLAT_ASKPASS=<token>:<socket>`
in the environment the binary is `ssh`'s askpass helper instead: `argv[1]` is the prompt itself (no subcommand word),
the answer goes to stdout, and no answer exits non-zero with nothing
written. A prompt-shaped `argv` without the mark is still a usage error.

The server-side script (`RemoteCommand.script`, POSIX `sh` + `curl`, installed
to a remote machine's `~/.local/bin/evlat`) is the third installed contract:
marked and versioned, generated from the Swift constants, run under
`sh`/`dash`/`bash` in tests. A change to the script bumps its version.
Version 2 speaks to `$EVLAT_SOCKET`, else the socket under the home, with no
key; its install and removal take away the `signal.token` version 1 left. A
version above this build's is not called old (another Mac's newer Evlat
installed it). `evlat --list` says why in one line: no `curl`, a `curl`
older than `--unix-socket` (7.40), no socket, a socket nobody answers on,
`404` (an older Evlat on the Mac).

What Evlat writes into a Docker sandbox (`SandboxInstall`, its file the
catalog's `Agents.sandboxInstall`) is the fourth installed contract: one
file of Evlat's own, `/etc/claude-code/managed-settings.d/evlat.json`
(Claude Code reads that folder beside `managed-settings.json`, which Evlat
never touches), written as root through `sbx exec` from stdin to a
temporary name and moved into place, and a network rule scoped to that one
sandbox, `localhost:48152` (`--sandbox` always: without it the rule would
be every sandbox's). Its hooks run the sandbox twin of the hook command
(`LocalAPI.HookEndpoint.sandbox`: `host.docker.internal`, no `$PPID` or
task header, `X-Evlat-Sandbox` added; silent, nothing on stdout). The
Mac's command bytes are unchanged. A running sandbox keeps the bytes it
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
| a full bar to look at | `scripts/demo.sh [left\|right]` — isolated (its own socket and home under `$TMPDIR/evlat-demo`; a `$TMPDIR` too long for a socket's address is refused): local sessions in every phase, worktrees of one repository on two branches, Codex, three remote machines over the fake `ssh`, Docker sandboxes, outside jobs, usage; approvals and questions, local and on a server, are held so their cards draw buttons, the sandboxed waits only heard; `scripts/demo.sh stop` ends it all |
| window, bar, mascot or menu touched | `make test-desktop` (offstage, `make all`'s focus assertions hold trivially: nothing activates and the balloon's key is a flag), then `make bundle && make run` and look at it |
| install to `/Applications` | `make install` (the user's call — it replaces the installed app) |
| ship a version | `make ship VERSION=x.y.z` — the user's call: `release`, `git push origin main`, `publish` in one go |
| release build | `make release VERSION=x.y.z` — clean tree; Developer ID, hardened runtime, notarized and stapled zip (Sparkle's), its appcast and `Evlat.dmg` (a first install's) in `build/release/x.y.z/`; needs the keychain identity, the `evlat` notarytool profile and Sparkle's EdDSA key (`SPARKLE_KEY` is its public half) |
| publish | `make publish VERSION=x.y.z` — the user's call: tags the built commit, pushes the tag, creates the GitHub release with the disk image, the zip and `appcast.xml` — every installed copy updates from it |

`make run` and `make install` stop **both** copies (`build/` and
`/Applications/`) first: two Evlats race for the socket, and the one that
finds it held hears nothing. Processes are targeted **by path**, never by name.

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
| `EVLAT_SOCKET` | a second Evlat: its own socket, an absolute path (`EvlatSocket`; a relative one is none, never the user's) — the app binds it and `evlat signal`/`watch` post to it. Set, it is the one predicate of a second process (`Isolation.hasOwnSocket`): no tunnel opens unless `EVLAT_MACHINES` is given, no persistent chat store exists unless `EVLAT_CHATS` is given, `ssh` passwords stay in memory, never in the keychain, and so do the agents' switches (`agents.enabled`), the chat's switch, backend and default modes (`chat.enabled`, `chat.backend`; `EVLAT_CHATS` keeps them in memory too), the language chosen in Settings, the update reminder's last showing and automatic updates of Evlat's parts (`updates.automatic`; the row is still offered); with `EVLAT_FEED` the "Install updates automatically" row is not offered, since Sparkle's defaults are the user's. It still asks the user's running Bateri whether they are at a tab (`TabFocus`), a question that only reads |
| `EVLAT_PORT` | gone: a process with it set, blank included, says `EVLAT_PORT is gone; use EVLAT_SOCKET` on stderr and exits `2` — the bar, the diagnostics, help and the askpass helper alike (`LaunchMode.refused`). `watch` and `signal` still run but post nothing, as if Evlat refused (`SignalClient.post`): `watch` runs the command unchanged and prints nothing, `signal` says the one line and exits `1` |
| `EVLAT_SESSIONS` | session directory (empty dir = no sessions) |
| `EVLAT_HOME` | temporary home root for every writer |
| `EVLAT_MACHINES` | machines to tunnel to; their switches stay in memory |
| `EVLAT_SANDBOX_PORT` | the Docker sandbox listener's port; with `EVLAT_SOCKET` set there is no sandbox listener unless this is given |
| `EVLAT_SBX`, `EVLAT_SBX_SOCKET` | the `sbx` to run and the daemon's socket; with `EVLAT_SOCKET` set no sandbox is watched or set up unless both are given (a fake `sbx`: `Tests/Fixtures/fake-sbx`). With `EVLAT_SOCKET` the "Watch sandboxes" switch stays in memory |
| `EVLAT_SANDBOXES` | `on`/`off` forces "Watch sandboxes" at launch; the stored switch is never written |
| `EVLAT_SSH` | fake `ssh`; it must run install scripts with a temporary `HOME` (`Tests/Fixtures/fake-ssh` runs calls in `FAKE_SSH_HOME`, prints the master's mark, makes the forward) |
| `EVLAT_CHATS` | temporary chat root |
| `EVLAT_PHASE` | force the mascot's phase at launch (the "Force state" menu item, scriptable) |
| `EVLAT_BODY` | force the body's mode (`always`, `smart`, `tucked`, `hidden`) at launch; the stored mode is never written |
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
- **A second Evlat must not take a live socket.** Two processes sharing
  one door would split the hooks between them silently. A live socket is
  left alone and said (`testALiveSocketIsNeitherTakenNorDeleted`); only a
  file nobody answers on is cleared. The sandbox port's
  `allowLocalEndpointReuse` is SO_REUSEADDR, not SO_REUSEPORT, for the same
  reason (`testASecondListenerCannotTakeTheSamePort`).
- **A `PermissionRequest` hook does not hold the terminal's dialog.** In an
  interactive session the dialog opens the same instant the hook fires
  (2.1.285); whichever answers first wins. "No" or Esc in the terminal
  closes the held connection, but **"Yes" does not**: it stays open until
  the hook's timeout. The request carries no `tool_use_id`, so
  `ApprovalHook.resolves` reads the answer from the tool's outcome or the
  turn's end. A decision sent after the terminal answered is ignored.
  Requests are serialized per session. Measured with a pty-driven
  `claude --settings` and a stand-in server on 48999.
- **A command `PermissionRequest` hook's `{}` is no decision, and the
  terminal's answers end it differently** (Claude Code 2.1.292). `{}` on
  stdout left the prompt to Claude as an empty output does; under
  `-p --permission-prompts none` that is a denial. Esc in the terminal ended
  the hook's process tree; "Yes" did not, and the `curl` stayed waiting.
- **Codex's `PermissionRequest` hook is not Claude's** (codex-cli 0.160.0,
  a pty-driven TUI under a temporary `CODEX_HOME`, a stand-in on the
  socket answering with the card's bytes). Its dialog **waits for
  the hook** ("Running hook"), and asks only once the hook is done. An
  **exit 2 is a deny** ("Blocked by hook"), where Claude reads it as no
  decision, so the command's `|| true` carries weight; empty stdout, `{}`,
  an exit 1 or a timeout bring the dialog. Esc ends the turn while the
  hook's process lives on: the held request is let go by the `Interrupt`
  that follows, read as `Stop`. A hook is trusted by its hash under
  `<file>:<event>:<group>:<hook>`: an added group asked for review at the
  next start ("1 hook is new or changed"), did not run until trusted
  (the command hooks beside it ran, and the dialog came as before), and
  once trusted in `/hooks` ran in the same session without a restart; an
  `allow` from it ran the command with no dialog. The group beside it kept
  its trust: Evlat appends, and never shifts an index.
- **A unix socket file takes the umask's mode** (`755` measured, a
  `NWListener` bound with `requiredLocalEndpoint = .unix(path:)`), and
  survives the listener's `cancel()`. The directory is the guard, and the
  listener removes its own file.
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
- **A Docker sandbox's hook on the main port carries the VM's pid.**
  Through `host.docker.internal` a sandbox's request reached 48151 as
  `.local`, and Evlat took `pid=446`, a process in the VM (sbx 0.46.0).
  Had this Mac had a 446, the row would have lived by a stranger's
  liveness. Hence the sandbox listener of its own, `.sandbox`.
- **A sandbox's `~/.claude/settings.json` is `sbx`'s.** It carries
  `permissions.defaultMode: bypassPermissions` and
  `skipDangerousModePermissionPrompt`; a kit's `files/home` would replace
  it (sbx's docs). A Claude sandbox has no `/etc/claude-code` of its own;
  hooks only in `managed-settings.d/evlat.json` (no `managed-settings.json`)
  sent `SessionStart` from Claude Code 2.1.280.
- **A running Claude takes managed settings live.** With the file written
  by `sbx exec -u root` and the rule by `sbx policy allow network
  --sandbox`, the same Claude's next message sent `UserPromptSubmit` and
  `Stop`; nothing restarted. Its `SessionStart` was missed, so that
  session has no start and [Go to session] brings the app alone. Set up at
  `started`, four of four new sandboxes were ready before Claude's first
  hook (setup 1.2–2.3 s). `sbx kit add`, by contrast, made a running
  sandbox again in 5.4 s and killed the Claude in it.
- **`sbx exec` starts a stopped sandbox**, and `sbx policy rm` asks for
  confirmation unless `--force` is given (none without a terminal).
  Deleting a sandbox drops its own rule.
- **`sbx` carries the terminal's `TERM`, `COLORTERM` and
  `TERM_PROGRAM(_VERSION)` into the sandbox, not its tab link**
  (`BATERI_TAB_URL`, or any other variable, measured). Inside, nothing
  says which client a session belongs to; the `sbx` client on this Mac,
  not Apple-signed, has its tab in its environment.
- **Every `sbx run` to a sandbox opens a new Claude session, and Claude
  outlives its client.** Three clients, three sessions; with the clients
  killed all three Claudes went on. A row with no tab is ordinary, and no
  way back to the same session was seen. `SessionStart` reached this Mac
  1.4–3.5 s after its client started; the first `sbx run`, which made the
  sandbox, took 14 s.
- **The `sbx` daemon's socket path is long.** 97 bytes under this user's
  home, against a unix address's 103 (`sbx daemon status` says where it
  is): a longer user name can pass the limit, which `SandboxWatcher.start`
  says rather than retrying a connection that cannot open. The daemon
  repeats a sandbox's last `started` on connect.
- **A sandbox's hook to a closed Evlat fails at once.** Through the
  sandbox's proxy: a port in the sandbox's rule with nothing listening is
  `500` in ~10 ms, one outside the rule `403` in ~8 ms; no 2 s wait per
  event, also after Evlat is removed.
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
- **An Apple-signed program's environment cannot be read by another
  process** (macOS 26.4.1): `KERN_PROCARGS2` of `/usr/bin/ssh`, `/bin/zsh`
  or `login` gives only the name (40 bytes); `ps -E` showed no variable for
  Evlat's own tunnel `ssh` and for other tabs' `zsh`, while Evlat's own
  environment read whole. So a Bateri tab's `ssh` names no tab and a
  remote row's button brought Bateri forward with no tab; the server's
  copy of an `LC_*` variable is what can say it (`TabLink.forwarded`).
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
- **A terminal that takes over its tabs on a relaunch orphans their
  `login`** (Bateri 0.4.0, macOS 26.4.1, 2026-10-04). After the relaunch
  the old tab ran `claude → -zsh → login (ttys018) → launchd`, and the walk
  found no terminal. Its master was still held, by the new `bateri` and its
  child `bateri hold`: `/dev/ttys018` is device 16,18, the master on
  `/dev/ptmx` 15,18 — the minor is what they share (`SessionHost.ptyNumber`).
  The tab's own `BATERI_TAB_URL`, opened with the running Bateri, selected
  that tab. Following the master costs a read of every process's
  descriptors: in a release build's `--list`, four orphaned sessions, six
  runs, the scan and the owners' walks took 8.6–11.6 ms per session over
  768–782 pids (521–525 readable), except the very first run's first two, 19.9
  and 14.1 ms. It runs only where the walk found nothing.
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
- **A moved herdr pane keeps its old id for some calls and not others**
  (herdr 0.9.3, measured in a container). After `pane move --new-workspace`
  the pane's `HERDR_PANE_ID` still names the old id; `pane process-info
  --pane <old>` answers by alias, with the new `pane_id` in the reply,
  while `agent get`/`agent focus <old>` say `agent_not_found`. The first
  remote select passed the old id on and focused nothing; the id used is
  the one herdr answers with (`RemoteHost.herdrFunctions`).
- **A closed tab's herdr client lives on, attached** (herdr 0.9.3, Bateri).
  The tab closed, its `login` sat exiting, and the `herdr` client stayed with
  no terminal (`tty ??`), still connected to the server, ignoring `TERM`
  and `HUP` — only `KILL` ended it. Its pid was the highest and its chain
  still reached Bateri, so "the higher pid" opened the closed tab; pids are
  no order of attaching either (17:08 got 22670, 17:18 got 37020). A
  client counts only with a terminal and a connection to the client socket
  (`unsi_conn_pcb` = the server's accepted `soi_pcb`, what `lsof -U` shows
  as `->0x…`), newest start first. Clients navigate on their own since
  herdr 0.9.0 (its changelog), so the newest may show another workspace;
  a focus over the API socket moves every client (0.9.3's source,
  `focus_all_shell_clients_on_default_target`), which is what makes the
  newest right — once the pane is selected.
- **herdr's API socket answers one request per connection.** A second
  line on the same connection met `Broken pipe` (0.9.3), so each request
  is its own connection, with `SO_NOSIGPIPE`: a write to a closed peer
  otherwise ended the process (signal 13, `HerdrSocketTests`). Calls took
  0.5–2.5 ms; finding one pane among six, 3–7 ms. `pane.process_info`'s
  `tty` was `null` on macOS; its `shell_pid` is the pane's root process.
- **`herdr --remote`'s connection is a detached master's, and its bridge
  has no terminal** (herdr 0.9.3, a Bateri tab to a Docker server,
  2026-10-04). herdr runs `ssh -S /tmp/hssh-<uid>/… -o ControlMaster=auto
  -o ControlPersist=600 -T`: its first `ssh` forked a master parented to
  launchd, arguments rewritten to `ssh: <socket> [mux]`, holding the only
  TCP connection; the bridge's `ssh`, a child of `herdr --remote`, held a
  unix socket to it and nothing else. The connection's `sshd` started
  0.85 s after the master. On the server `herdr remote-client-bridge` ran
  under `sshd: dev@notty` with no terminal, with the connection's
  `SSH_CONNECTION` and the tab's `LC_BATERI_TAB_URL`. A client counted only
  with a terminal never saw it, and the master's walk reached no app: no
  button, until both were followed. `herdr --remote`'s own environment
  read whole (`BATERI_TAB_URL`); its `ssh`'s did not.
- **A focus on the server moves the `--remote` view.** `herdr workspace
  focus` there changed the Bateri window's title — herdr's
  `{hostname}: {workspace}` of the client's view — from `~` to `plain`.
  `agent focus` takes the same path in herdr's source (`agent.focus`,
  then `focus_all_shell_clients_on_default_target`); it was not measured
  itself on `--remote`.
- **A home NAT rewrites the ssh client port.** The tunnel's
  `192.168.1.217:60070` reached the server as `31.223.75.17:19656`, a
  Bateri tab's `:63114` as `:19554` (OpenSSH 9.6p1, 2026-10-02): matching
  `SSH_CONNECTION`'s port alone never held from that network. Candidates
  are found by the tunnel's own end instead, and told apart by start: the
  connection's `sshd` started +0.11 s and −0.19 s from its Mac `ssh`, the
  clocks were within 0.5 s.
- **One `.local` name is two ends, and Bateri's own `ssh` is a detached
  master** (Bateri 0.6.0, a Raspberry Pi, 2026-10-06). `raspalfred.local`
  resolved to an IPv6 and an IPv4: Evlat's tunnel, started later, held
  the IPv6 and the Bateri tab's connection the IPv4, so no `ssh` here
  shared the tunnel's end and the card had no button. The server's
  `SSH_CONNECTION` named the IPv4 and the master's port. Bateri's tab ran
  `ssh -t -o ControlMaster=auto -o ControlPath=~/Library/Caches/bateri/s/…
  -o ControlPersist=2`: a master parented to launchd (`ssh: <socket>
  [mux]`) held the one TCP connection, the tab's `ssh` and Bateri's own
  `ssh -T -o BatchMode=yes -o ControlMaster=no` (a child of Bateri, no
  terminal) rode it, and the master's walk reached no app. On the server
  the session had `LC_BATERI_TAB_URL`.
- **`ssh -S` with a gone master logs in by itself.** `ControlMaster=no`
  only stops it becoming a master; with no socket it connects directly.
  `-o ProxyCommand=/usr/bin/false` makes that fail at once (exit 255,
  ~40 ms, nothing sent) and a live master never runs it; over the master
  the script took 0.19–0.25 s.
- **A master remembers a forward that failed.** A socket `-R` on the
  master's own command line that failed (a file in the way) is not tried
  again: the next `-O forward` with the same spec returns 0 and forwards
  nothing (sshd 9.6p1, client 10.2p1). Hence no `-R` on the master, and a
  failed forward ends the master: the next try is a new one.
- **`sshd` leaves the socket file when the connection ends** (`-O exit`, a
  dropped network), and `StreamLocalBindUnlink` is the server's setting,
  off by default; a file in the way fails the next forward. The probe asks
  the file and removes it only when nothing answers (connect refused, or
  5 s of silence).
- **A refused socket forward says the same thing whatever refused it.** A
  file in the way, a missing folder, `AllowStreamLocalForwarding no`,
  `DisableForwarding yes` and `AllowTcpForwarding no` all printed
  `remote port forwarding failed for listen path …` with exit 255, the
  master still up (OpenSSH 9.6p1 in a container, 10.2p1 client, measured
  2026-10-07). The probe before the forward is what tells busy from
  refused. Socket to socket over a master took 36 ms and the server's file
  came out `0600` (`StreamLocalBindMask 0177`).
- **`-R` does not expand `~` on the server's side** (OpenSSH bug 3018), and
  `sshd` makes no missing folder: the forward names the absolute path the
  probe read from `$HOME`, after the probe made the folder.
- **Codex runs a changed hook only once it is trusted again.** Its trust is
  a hash per hook (`config.toml` → `hooks.state."<file>:<event>:<group>:<n>"`
  → `trusted_hash`); with the command's bytes changed, `hooks/list` read
  `modified` and `codex exec` ran no hook and said nothing (codex-cli
  0.160.0, a temporary `CODEX_HOME`, measured). The TUI's `/hooks` trusts
  it again; what the TUI shows on its own was not measured.

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
- **A tracking area rebuilt under a still cursor gets an exit it should not.**
  While a card's frame moved through its transition the hover areas were
  rebuilt every few milliseconds, and AppKit answered many rebuilds with an
  enter and at once an exit of the area just installed, the cursor inside it
  (traced: 62 in eight row-to-row moves). The last one, with no move after
  it, closed the open bar under the cursor 0.25 s later. An exit is
  believed only once the cursor is out of the area's rectangle
  (`PointerRelay.holds`), and looked at again until it is or an enter comes.
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
- **A full-size content view's SwiftUI root sits below the title bar
  unless it ignores the safe area, and `ImageRenderer` cannot show it.** The
  update window, sized to its measured content, drew its content a title
  bar lower and lost the footer's bottom padding off the edge; its
  `ImageRenderer` pictures, which have no safe area, looked right. Setup,
  Settings and Updates end in `.ignoresSafeArea()`; check a window on the
  real screen (`screencapture -l <window id>`), not only in a rendered
  picture.
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
