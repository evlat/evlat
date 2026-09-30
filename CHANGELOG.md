# Changelog

What changed in each release, newest first. `make ship VERSION=x.y.z` takes
the section headed `## x.y.z` as that release's notes: it is shown on the
GitHub release and in the update window of every installed copy. A version
with no section ships with no notes.

Write for the person who runs Evlat, not for the code: what they will notice.
Markdown; keep it to a few bullets.

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
