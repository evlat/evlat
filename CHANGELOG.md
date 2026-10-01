# Changelog

What changed in each release, newest first. `make ship VERSION=x.y.z` takes
the section headed `## x.y.z` as that release's notes: it is shown on the
GitHub release and in the update window of every installed copy. A version
with no section ships with no notes.

Write for the person who runs Evlat, not for the code: what they will notice.
Markdown; keep it to a few bullets.

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
  Sessions on remote machines show no branch.
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
