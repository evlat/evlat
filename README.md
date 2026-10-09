<div align="center">

<img src="docs/media/banner.png" alt="Evlat: which of your agents is waiting on you?" width="100%">

# Evlat

**A status strip for the edge of your macOS screen that tells you, at a glance,
what your AI coding sessions are doing.**

[![Download for macOS](https://img.shields.io/badge/Download_for_macOS-Evlat.dmg-black?style=for-the-badge&logo=apple)](https://github.com/evlat/evlat/releases/latest/download/Evlat.dmg)

macOS 14 or later · signed and notarized · updates itself · no macOS permissions

<table>
<tr>
<td width="33%"><img src="docs/media/waiting.jpg" alt="The open bar: every session by name and state, with Claude and Codex usage limits"></td>
<td width="33%"><img src="docs/media/jump.jpg" alt="A session's card: what it is waiting on, and Go to session"></td>
<td width="33%"><img src="docs/media/chat.jpg" alt="The chat bubble next to the mascot"></td>
</tr>
<tr>
<td align="center">See who's waiting on you</td>
<td align="center">One click to the right tab</td>
<td align="center">Ask without switching windows</td>
</tr>
</table>

</div>

A small mascot sits at the head of the bar and shows the overall state; below
it, one ring per session. You don't have to look at the bar: when a session
stops and waits for you (a permission prompt, a question), the mascot and that
ring turn amber. Hover over the bar to see every session by name, and rest on
one to see what it is doing and jump to its terminal.

## What it shows

- **Claude Code and Codex sessions**: working, waiting for you, finished,
  failed, idle. Session state comes from hooks; running Claude Code sessions
  are also found without any setup.
- **Usage windows**: Claude's 5-hour and 7-day limits (relayed from the status
  line) and Codex's (read from its local logs).
- **Any long command**: `evlat watch npm run build` puts the command on the
  bar until it ends, and passes its output and exit code through unchanged.
- **Remote machines**: sessions and commands on servers you reach over SSH,
  through a reverse tunnel, labelled with the machine's name.
- **Chat**: click the mascot (or press ⇧⌘Space) to run a task with your own
  `claude` or `codex` CLI (Settings → Chat). Answer permission prompts in the bubble, drop files onto the
  mascot, and come back to it from the bar.

Evlat asks for no macOS permissions. Its local API listens on a unix socket in
`~/.config/evlat/run`, a folder only you can open; no TCP port is open unless
"Watch sandboxes" is on.

## Requirements

- macOS 14 or later
- Swift 5.9+ (Xcode or the Command Line Tools)
- Optional: [Claude Code](https://docs.claude.com/en/docs/claude-code) and/or
  Codex CLI; the chat bubble needs `claude` or `codex` on your `PATH`

## Install

Download [**Evlat.dmg**](https://github.com/evlat/evlat/releases/latest/download/Evlat.dmg),
open it and drag Evlat into Applications. It is signed and notarized, and
updates itself (**Check for Updates…** in its menu; it also checks daily).

## Build from source

```sh
git clone https://github.com/evlat/evlat.git && cd evlat
make install     # builds build/Evlat.app, copies it to /Applications, opens it
```

On first launch a short setup opens beside the mascot, in four steps:
connect your agents, see that they are heard (when you connected one), choose
where the bar sits and when it hides, and a few last touches. Everything it
sets can also be changed later in **Settings** (⌘,), where each agent's card
shows which file it writes and offers a copy-paste alternative.

> **Signing.** A build from source is ad-hoc signed and has no updater: it
> runs on the machine that built it and never replaces itself. Releases are
> made with `make ship VERSION=x.y.z` (Developer ID, notarized, Sparkle).

Other targets:

| command | what it does |
|---|---|
| `make build` | debug build |
| `make test` | run the test suite |
| `make all` | build + test |
| `make bundle` | build `build/Evlat.app` (release) |
| `make run` | bundle and open `build/Evlat.app` |
| `make install` | bundle, copy to `/Applications`, open |
| `make clean` | remove build products |

## Command line

Settings → Command line links `~/.local/bin/evlat` to the app's binary.

```sh
evlat watch <command…>                           # show a command on the bar while it runs
evlat signal render --progress 0.4 --label Render  # drive a row yourself
evlat signal render --done
evlat mascot check ~/.config/evlat/mascots/hap   # check a mascot of your own
evlat --help
```

Any program can also post to the local API directly, with no key:
`curl --unix-socket ~/.config/evlat/run/evlat.sock http://127.0.0.1:48151/signal …`
(the URL only fills `Host:`). See [`AGENTS.md`](AGENTS.md) → Local API for the
body.

On a remote machine, Settings → Remote machines installs a small POSIX `sh`
version of `evlat watch` / `evlat signal` that reports through the tunnel.

## Your own mascot

Settings → Mascot → Look offers the cube, Pati, Bit and Puf, then every
mascot Evlat finds in two places, one folder each:

- `~/.config/evlat/mascots/<name>/`: yours (**Open Folder** there makes it).
- `~/.codex/pets/<name>/`: your Codex pets, read as they are.

A folder holds a **pet**, a `pet.json` beside one picture sheet in the Codex
format (8 columns of 192×208 frames, 1536×1872 or 1536×2288), or a
**character**, a `character.json` of shapes that move the way Evlat's own
mascots do:

```json
{
  "version": 1,
  "name": "Hap",
  "root": { "name": "hap", "children": [
    { "name": "body", "shape": { "roundedRectangle": { "cornerRadius": 0.4 } },
      "fill": "#EBEBEB", "size": [0.9, 0.8] },
    { "eye": { "side": -1, "width": 0.12, "height": 0.26, "gap": 0.18, "gaze": [0.1, 0.07], "fill": "#000000EB" } },
    { "eye": { "side": 1, "width": 0.12, "height": 0.26, "gap": 0.18, "gaze": [0.1, 0.07], "fill": "#000000EB" } }
  ] }
}
```

Evlat's own animations move the eyes for every state; a character may add
parts, its own controls, morphs, its own animation for any state, gestures
and the rules that play them. Every mascot is held to the rules Evlat's keep
(the five states look different, motion comes in bursts, nothing rests
tilted…), and one that breaks a rule is left out with the reason under the
tiles. Check one, and draw its states:

```sh
evlat mascot check ~/.config/evlat/mascots/hap --preview /tmp/hap.png
```

The full format, the rules and the pet rows:
[**evlat.kalaomer.com/docs/mascots**](https://evlat.kalaomer.com/docs/mascots).
Worked examples: [Pati](Tests/Fixtures/mascots/pati/character.json) and
[the lantern](Tests/Fixtures/mascots/lantern/character.json).

**Let your agent make one.** Paste this into Claude Code, Codex or another
coding agent, with your description in place of the brackets:

```text
Make me a mascot for Evlat, the macOS status bar for AI coding sessions.

The mascot I want: [describe it: what it is, its colours, how it should look when it waits on me].

1. Read the mascot guide: https://evlat.kalaomer.com/docs/mascots
   If it doesn't load, read the "Your own mascot" section of
   https://github.com/evlat/evlat/blob/main/README.md and the worked example
   https://github.com/evlat/evlat/blob/main/Tests/Fixtures/mascots/pati/character.json
2. Write it as ~/.config/evlat/mascots/<short-name>/character.json. Pictures, if any, go in the same folder.
3. Check it:
   evlat mascot check ~/.config/evlat/mascots/<short-name> --preview /tmp/<short-name>.png
   (no evlat on PATH: /Applications/Evlat.app/Contents/MacOS/Evlat mascot check …)
   Fix every rule it prints. Look at the preview image: it must read at the bar's 34 pt size,
   and its five states must look different. Repeat until it prints "ok".
4. Tell me to open Evlat → Settings → Mascot → Look and pick it.

Keep to simple shapes that read at 34 pt and say the states mostly with the eyes.
A likeness of someone else's character stays in my own folder; never publish it.
```

## Languages

English, Turkish, German, Spanish, French, Brazilian Portuguese, Ukrainian,
Russian, Japanese, Korean, and Simplified and Traditional Chinese. Evlat
follows the system language unless you pick one in Settings → General →
Language.

## Contributing

Read [`AGENTS.md`](AGENTS.md) before changing code. It holds the architecture's
reasons, the contracts installed on users' machines that must not change, how
to verify a change, and a list of pitfalls that have already been hit.

Contributions are accepted under the
[Contributor License Agreement](CLA.md). You keep the copyright to your work;
the agreement lets the project license it under the terms in
[License](#license), and under other terms (for example, a commercial license).
On your first pull request a bot asks you to accept it by commenting
`I have read the CLA Document and I hereby sign the CLA`.

## License

[Functional Source License 1.1, Apache 2.0 Future License](LICENSE.md)
(FSL-1.1-ALv2).

- **You may** use Evlat for any non-competing purpose, including inside your
  company, and read, modify and share the code.
- **You may not** offer it, or a product built from it, as a commercial product
  or service that competes with Evlat.
- **Each version becomes Apache 2.0** two years after its release.

For a license outside these terms, open an issue.
