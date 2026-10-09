# Changelog

What changed in each release, newest first. `make ship VERSION=x.y.z` takes
the section headed `## x.y.z` as that release's notes: it is shown on the
GitHub release and in the update window of every installed copy. A version
with no section ships with no notes.

Write for the person who runs Evlat, not for the code: what they will notice.
Markdown; keep it to a few bullets.

Work that lands on `main` adds its bullet under `## Unreleased`; the release
renames that heading to its version.

## 0.2.3

- **Update your hooks once after this update.** Evlat now listens only on
  a socket in `~/.config/evlat/run`, a folder only you can enter, and no
  longer on port 48151, so hooks set up by earlier versions go silent until
  you update them. A window opens at launch listing them, this Mac's agents
  and your servers, with **Update all**; the menu's **Review updates…**
  opens it again. Leave **Keep these up to date automatically** checked and
  from then on Evlat updates what it wrote by itself, opening the window
  only when you need to act, such as Codex's `/hooks`. Open Claude Code
  sessions take the change with their next message. Your own scripts post
  to the socket now, with no key:
  `curl --unix-socket ~/.config/evlat/run/evlat.sock http://127.0.0.1:48151/signal …`.
  With several Macs on one server, update Evlat on every Mac first, then
  the server.
- **Approve a server's sessions from the bar.** Claude Code and Codex on a
  server you added in Settings → Servers now ask the bar for permission —
  **Allow once** or **Deny** on the session's card — and Claude's questions
  are answered there too. While its card waits, Codex shows “Running
  hook”, two minutes at most.
- **Choose your mascot, or bring your own.** Settings → Mascot → Look
  offers Pati the cat, Bit the robot — now with a lit screen, its eyes in
  the bar's colours — and Puf the ghost beside the cube, each showing
  waiting, working and done its own way. Your Codex pets appear there too,
  and so does any mascot you put in the mascots folder, a pet sheet or a
  `character.json`: **How to Make One** opens the
  [guide](https://evlat.kalaomer.com/docs/mascots), with a prompt for your
  coding agent, and `evlat mascot check` lists every rule a mascot breaks
  and draws its states. A finish no longer leaves the mascot's head tilted.
- **A roomier first-run setup, and a tidier Settings.** The setup opens in
  a panel beside the mascot, four steps with the main button in one place:
  connect your agents, see each one heard, choose where the bar sits and
  when it hides, and a few last touches, where **Open Evlat when the Mac
  starts** and the `evlat` command turn off as well as on. In Settings,
  This Mac, Servers and Docker sandboxes sit together under
  **Connections**.
- **Bateri: quiet at your tab, and the right tab over its ssh.** With
  Bateri 0.4 or newer, a session's finish sound, peek and reminders stay
  quiet while you're at its tab, on this Mac or over ssh; the finish stays
  new until you look. **Go to session** now opens the tab of a session on
  a server you reach through Bateri's own ssh.
- **Fixes.** A spent usage window says 100%, not “101%”. Docker sandboxes
  are set up again where your user name is 15 characters or longer, and an
  `sbx` update notice no longer hides the sandbox list.

## 0.2.2

- **Smart hide now gets out of your way.** With Settings → General →
  Body set to **Smart hide**, the bar stays out while no window is under
  it and tucks into the edge when one is — drag a window to the edge and
  it steps aside, move the window away and it's back. It still peeks out
  when a session waits for you or finishes. No permission is asked: Evlat
  only looks at where windows are, never at what's in them.
- **The old Smart hide is now Tucked.** If you liked the body always
  tucked in, with only the sliver on the edge, pick **Tucked**. If you
  were on Smart hide, you get the new behaviour after this update.
- **Go to session finds the tab after your terminal restarts.** When a
  terminal app such as Bateri restarts and keeps its tabs open, Go to
  session still brings you to the session's tab instead of losing it.

## 0.2.1

- **A question's answers go when you press Send.** When Claude asks you
  something on the bar, picking an option on the last question no longer
  sends your answers straight away: it marks your pick, and **Send** sends
  them. Questions before the last still move on with one press, and Back
  keeps everything you picked.
- **Chat starts with what you have, and can be turned off.** If you
  haven't picked one in Settings → Chat, a new chat runs on whichever of
  Claude Code and Codex is installed — with only Codex, it's Codex. With
  neither, the chat says so and links to where each one is installed. If
  you don't want the chat at all, turn off **Enable chat** at the top of
  Settings → Chat: the mascot then ignores clicks, the shortcut and dropped
  files, and a chat that was running stops.
- **Claude Code in Docker sandboxes.** Sessions of Claude Code running in a
  local Docker sandbox (`sbx`) now show on the bar under the sandbox's
  name: working, waiting for you, finished, with the same sounds and
  reminders. Turn on Settings → **Sandboxes** → **Watch sandboxes** (it's
  off until you do) and keep using `sbx` as usual: Evlat sets up each
  sandbox as it starts, and the ones already running at once. A session
  already running shows from its next message. Inside a sandbox Evlat
  writes one file of its own and allows one port; turning the switch off
  takes both out of the running sandboxes. **Go to session** opens the tab
  of the `sbx run` that started the session, when it can tell which.
  Sandboxes in Docker's cloud can't reach your Mac.
- **Go to session lands on the right herdr pane.** For a session in
  [herdr](https://herdr.dev), Go to session now selects its pane in more
  places: behind an `ssh` or `sbx run` started in a herdr pane, in herdr
  on a server you work on over `ssh`, and in a `herdr --remote` window.
  When Evlat can't select the pane, the button says so: "Open herdr in
  Bateri" instead of "Open in Bateri".
- **A roomier list.** Names on the open bar get more room, and a waiting
  session says what it waits for in one word, **approval** or
  **question**, so the word is never cut; the card still says it in full.
  A remote machine is named by its own short name (`gpu-01` for
  `gpu-01.eu-central.internal`, longer only when two machines would read
  alike). The line under the list counts the waiting sessions too, in
  amber, and a highlighted row no longer overlaps the one next to it.
- **Updates on their own.** Evlat now looks for a new version every hour,
  downloads it in the background and installs it when Evlat quits. If
  Evlat stays open, it asks once a day to restart and install. Turn it
  off in Settings → General → **Install updates automatically**. If you
  choose **Remind Me Later**, Evlat won't ask again for a day; the menu
  shows **Update Available** until then.
- **A new card.** Session names get more room on the open bar, and a
  remote machine or a job's sender sits under the name, so neither cuts the
  other short. The card beside it is wider and laid out anew: who and where
  on top, then the status with its time, then what the session is doing or
  asking, and **Open in Bateri** (or your terminal) as its one button.
  Questions show every option's description, let you write your own answer
  right in the **Other…** row, and have **Next** to keep an answer you came
  back to. A tall card moves up so it always fits on the screen.

## 0.2.0

- **One card per agent.** Settings → Agents shows Claude Code, Codex and
  Antigravity as cards. Each card installs everything that agent needs
  (its hooks and its usage line) with a single **Install**. A switch turns
  an agent off: its sessions and usage leave the bar, and Evlat offers to
  remove its parts from the agent's files. Setup asks which agents you
  use.
- **If you installed only the hooks before,** the Claude Code card reads
  **Needs update**. One press adds the usage line, which wraps your own
  status line command; what it prints stays the same. A status line you
  edited by hand is left as it is.
- **Remote machines get the same cards.** Each server shows one card per
  agent, installed and switched on or off for that server alone.
  Antigravity's hooks now really install on a server.
- **Chat with Codex.** Settings → Chat picks the agent the chat bubble
  talks to, with that agent's own modes. Codex asks on a card before it
  runs a command, and the card can **Always allow this command**. Codex
  marks its chat protocol as experimental, so Settings warns when your
  Codex version differs from the one Evlat was tested with.
- **Usage has its own page:** Settings → Usage.
- **Settings opens in front** of the app you were using and takes the
  keyboard. While it is open, Evlat shows an icon in the Dock.
- **The mascot can speak.** A new **Mascot** tab in Settings chooses who
  speaks — Evlat's own tones, or a character voice from the OpenPeon
  community, installed with one click — and at which moments: done,
  error, waiting for approval, waiting for an answer. Every moment is off
  until you switch it on. Character voices build on @gabeperez's OpenPeon
  pack player — thank you (#8).
- **Remind again** (the old waiting reminder) now lives in the Mascot tab
  and can also remind you of finished work you haven't looked at. If you
  used the reminder with its sound, you'll now also hear a wait begin.
- **Go to session for Claude Code on a server.** A session you started
  over `ssh` on a remote machine now has the **Go to session** button: it
  opens the terminal tab that `ssh` runs in on your Mac. When Evlat can't
  tell two tabs to the same server apart, it brings their app forward
  instead. Inside tmux or herdr on the server it opens the tab that is
  attached to the session now, not the one it was started from; with
  nothing attached there is no button.
- **Ten new languages:** German, Spanish, French, Brazilian Portuguese,
  Ukrainian, Russian, Japanese, Korean, and Simplified and Traditional
  Chinese. Evlat follows your Mac's language, or the one you pick in
  Settings → General → Language, which changes at once.

## 0.1.9

- **Choose the screen the bar sits on** (Settings → General → Screen, or
  **Screen** in the mascot's menu), shown when more than one screen is
  connected. Unplug the chosen screen and the bar waits on the main one;
  plug it back in and the bar returns. If the bar's edge borders another
  screen, Settings says the bar may be hard to open there.
- **Tell worktrees apart.** When sessions of the same repository share a
  name but sit on different branches, each row on the bar now shows its
  branch instead of a number. A session's card always shows its branch.
  Settings → Sessions → Git branch turns this off, or on for every session.
  Sessions on remote machines show no branch. Thanks to Shinyoo Kim, who
  asked for it on Product Hunt.
- **Connect to servers that ask for a password.** A remote machine no
  longer needs an ssh key: when the server asks for a password, Evlat shows
  the question in a small window, and **Remember in Keychain** (on by
  default) lets it reconnect on its own after sleep or a dropped network.
  A one-time code or a key's passphrase is asked every time and never kept.
  A password the server refuses is tried once, not again: the machine waits
  for you, and the menu says so — **Enter Password…** in Settings → Remote
  Machines. Removing a machine removes its saved password.
- Pasting with ⌘V now works in the line that **Other…** opens on a
  question's card.
- **Go to session finds sessions inside herdr and tmux.** It opens the
  terminal tab you last used, never one that has since closed, and
  in herdr it also switches to the session's pane, in any workspace. Thanks
  to @gabeperez (#5).
- **See your Gemini usage from the Antigravity CLI.** A **Gemini** group
  joins Claude and Codex in the usage block, with its 5-hour and weekly
  windows. Turn it on in Settings → Sessions → Usage (**Antigravity usage
  line**), shown when the `agy` CLI is installed; the CLI keeps drawing its
  own status line. The numbers carry a `~`: they come from a format
  Antigravity does not document. Thanks to @gabeperez (#6).
- **Hide usage you have not used lately.** Settings → Sessions → Usage →
  **Hide usage not seen for an hour** (off by default) takes a tool's group
  off the bar until it reports again, instead of keeping it dimmed until its
  window resets. Thanks to @gabeperez (#7).

## 0.1.8

- **Answer Claude's questions from the bar.** When Claude Code asks you a
  question, the session's card now shows the question and its options,
  instead of an Allow button that answered nothing. Click an option to
  answer; tick several when the question allows it; **Other…** opens a line
  to type your own answer. Several questions asked at once are answered one
  after another, with a way back to change an earlier answer, and sent
  together.
- A session waiting on a question now reads "waiting for an answer" rather
  than "waiting for approval".

## 0.1.7

- **Waiting reminder** (Settings → General, off by default): when a session
  has waited for your answer longer than the minutes you choose, Evlat plays
  a soft chime, sends a notification, or both. Answering takes the
  notification back; clicking it opens that session on the bar. Evlat asks
  for notification permission only when you turn notifications on.
- **Go to session** now opens the session's own tab in cmux, instead of only
  bringing cmux forward.

## 0.1.6

- **Antigravity** sessions now show in the bar, from the app, the IDE and
  the `agy` CLI alike. Install its hooks in Settings → Sessions. Antigravity
  tells Evlat nothing when it waits for your approval, so such a session
  shows as working rather than waiting.
- An Antigravity session's card shows its last reply, as Claude's does.
- **Go to session** opens the session's own tab in current Bateri builds
  again; it only brought the app forward.
- A card's last reply no longer stops at its first paragraph: it previews
  the whole reply, up to about four lines.
- Remote machines get Antigravity's hooks too, with Claude's and Codex's.
  There the card has no reply: the conversation stays on the server.

## 0.1.5

- Approving from the bar is no longer a separate setting: it comes with
  Evlat's Claude Code hooks. If Evlat says your hooks are out of date, one
  update turns it on.

## 0.1.4

- **Approve from the bar** (Settings → Sessions, off by default): when a
  Claude Code session asks for permission, its card shows the command whole
  with **Allow** and **Deny**. It allows once, never always. The terminal
  still asks too; whichever you answer first counts.
- The card's buttons now light up under the pointer and press in when
  clicked.

## 0.1.3

- **Go to session** now opens the session's own tab in Bateri, Metalterm,
  Warp and iTerm, and the session itself in the Claude desktop app, instead
  of only bringing the app forward.
- iTerm sessions are now found: their card shows **Go to session** instead
  of saying no terminal was found.
- Terminal and Ghostty still come forward as before; picking their tab would
  need a macOS permission Evlat does not ask for.
