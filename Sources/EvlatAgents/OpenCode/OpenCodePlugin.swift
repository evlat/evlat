import Foundation
import EvlatCore

/// The plugin Evlat drops into OpenCode's plugin folder: the unit's one file,
/// written whole (`OwnedFile`), marked and versioned, generated from the
/// constants below. It is the fifth installed contract (`AGENTS.md` →
/// Contracts) and `OpenCodePluginTests` pins its bytes.
///
/// OpenCode loads a plugin only as an ESM `.js` file in `plugins/` — an
/// `.mjs` is not picked up and a CommonJS `.js` is skipped silently by 2.x —
/// and calls a different entry point on each version line: 1.x calls
/// `server(input)` (and `setup` too, with a context that has no `event`),
/// 2.x calls `setup(ctx)` only, whose events arrive through
/// `ctx.event.subscribe()`'s async iterable.
///
/// The plugin only **listens**: no hook that OpenCode fires before a tool
/// (a hook that throws there refuses the tool), no `console` (a terminal UI
/// owns the screen) and no `$` (Node has none). Each event it posts goes to
/// Evlat's socket over `node:http` — the one transport measured on every
/// runtime OpenCode runs in (Bun, the desktop app's Node, Linux) — with its
/// own timeout, and every failure is silent.
///
/// What is kept here and not in Swift is what needs the process's memory:
/// de-duplication (2.x boots one plugin instance per folder and every one
/// receives every event), child session → root session, the 2.x call id →
/// tool name, whether a turn is open, and the 300 ms an answer-less
/// permission is held back (`--auto` answers in under 3 ms, and a flicker of
/// "waiting" is no wait). Everything else is Swift's: the plugin posts
/// OpenCode's own event names with the fields it pulled out, and
/// `OpenCodeHookAdapter` says what they mean.
enum OpenCodePlugin {
    /// Raised whenever the file's bytes change after a release.
    static let version = 1

    /// The marker's text, after the comment prefix: what makes the file
    /// Evlat's own.
    static let marker = "evlat-opencode-plugin"

    /// Where OpenCode scans, under the home. `XDG_CONFIG_HOME`, when a shell
    /// sets it, moves the folder OpenCode reads; Evlat cannot know that.
    static let path = ".config/opencode/plugins/evlat.js"

    /// The route the events are posted to (`HookChannel.paths`).
    static let route = RouteTable.installedPrefix + "/opencode"

    /// Events that say nothing about a row, dropped before anything else.
    /// `*x` ends with `x`, `x*` begins with `x`. These are the chatty names
    /// measured on 1.18–1.19 and 2.0; any other event that names a session
    /// reaches Swift and stays visible there as a word nothing reads.
    static let noise: [String] = [
        "*.delta", "plugin.added", "catalog.updated", "reference.updated", "integration.updated",
        "model.updated", "provider.updated", "agent.updated", "command.updated", "skill.updated",
        "websearch.updated", "plugin.updated", "vcs.branch.updated", "models-dev.refreshed",
        "session.updated", "session.diff", "session.renamed", "message.updated",
        "session.step.*", "session.text.*", "session.reasoning.*", "session.usage.updated",
        "session.inbox.*", "session.instructions.updated", "session.tool.input.ended",
        "session.tool.progress", "session.retry.scheduled", "shell.*", "location.shutdown",
    ]

    /// The tool input keys that leave the process: the subject of a step
    /// and the question a card asks, never a file's content.
    static let inputKeys = ["command", "filePath", "path", "pattern", "url", "query", "description", "questions"]

    /// The longest string kept from a tool input.
    static let textLimit = 2000

    /// How long a permission is held before it is told (`--auto`).
    static let holdMilliseconds = 300

    /// A request's timeout, as the installed hook command's `curl -m 2`.
    static let requestTimeoutMilliseconds = 2000

    /// The file, as `OwnedFile` installs it.
    static let file = OwnedFile(path: path, comment: "//", marker: marker, version: version, body: body)

    // MARK: - The text

    /// The header comment, the imports, the pure part, then the wrapper.
    static var body: String {
        header + "\n" + imports + "\n" + pure + "\n" + wrapper
    }

    private static let header = #"""
        // Evlat's plugin for OpenCode. Evlat wrote this file and rewrites it when a newer
        // one is needed; delete it (or use Evlat's settings) to remove it.
        // It only listens: it tells Evlat's socket what a session is doing and nothing
        // else, and stays silent when Evlat is not running.
        """#

    /// No I/O, no timers, no `import`/`export`: a state and a function from
    /// (state, event) to what to send. The tests run this part alone, in
    /// JavaScriptCore.
    static var pure: String {
        let noiseJSON = json(noise)
        let keysJSON = json(inputKeys)
        return #"""
        const NOISE = \#(noiseJSON);
        const INPUT_KEYS = \#(keysJSON);
        const TEXT_LIMIT = \#(textLimit);
        const HOLD_MS = \#(holdMilliseconds);
        const PLUGIN_VERSION = \#(version);
        const LIST_LIMIT = 8;
        const SEEN_LIMIT = 4096;
        const LINK_LIMIT = 2048;

        function isNoise(type) {
          for (const entry of NOISE) {
            if (entry.startsWith("*")) { if (type.endsWith(entry.slice(1))) return true; }
            else if (entry.endsWith("*")) { if (type.startsWith(entry.slice(0, -1))) return true; }
            else if (type === entry) return true;
          }
          return false;
        }

        function remember(set, key, limit) {
          set.add(key);
          if (set.size > limit) set.delete(set.values().next().value);
        }

        function store(map, key, value, limit) {
          map.delete(key);
          map.set(key, value);
          if (map.size > limit) map.delete(map.keys().next().value);
        }

        function createState() {
          return {
            seen: new Set(), tools: new Set(), parents: new Map(), dirs: new Map(), phase: new Map(),
            calls: new Map(), held: new Map(), outstanding: new Map(), version: null,
          };
        }

        function cut(value, limit) {
          return typeof value === "string" ? (value.length > limit ? value.slice(0, limit) : value) : undefined;
        }

        function strings(list) {
          if (!Array.isArray(list)) return undefined;
          const out = [];
          for (const item of list) {
            const text = cut(item, TEXT_LIMIT);
            if (text !== undefined && out.length < LIST_LIMIT) out.push(text);
          }
          return out;
        }

        function questions(list) {
          if (!Array.isArray(list)) return undefined;
          return list.slice(0, LIST_LIMIT).map((q) => ({
            question: cut(q && q.question, TEXT_LIMIT),
            header: cut(q && q.header, TEXT_LIMIT),
            options: Array.isArray(q && q.options)
              ? q.options.slice(0, LIST_LIMIT).map((o) => ({ label: cut(o && o.label, TEXT_LIMIT), description: cut(o && o.description, TEXT_LIMIT) }))
              : [],
          }));
        }

        function pick(input) {
          if (!input || typeof input !== "object") return undefined;
          const out = {};
          for (const key of INPUT_KEYS) {
            const value = input[key];
            if (key === "questions") { const list = questions(value); if (list) out[key] = list; }
            else { const text = cut(value, TEXT_LIMIT); if (text !== undefined) out[key] = text; }
          }
          return out;
        }

        function nonEmpty(value) {
          return typeof value === "string" && value ? value : null;
        }

        // The session an event is about, wherever its type keeps it.
        function sessionOf(p) {
          if (!p || typeof p !== "object") return null;
          return nonEmpty(p.sessionID) || nonEmpty(p.info && p.info.sessionID) || nonEmpty(p.form && p.form.sessionID)
            || nonEmpty(p.part && p.part.sessionID);
        }

        function directoryOf(ev, p) {
          return nonEmpty(p.info && p.info.directory) || nonEmpty(ev.location && ev.location.directory)
            || nonEmpty(p.location && p.location.directory);
        }

        function rootOf(state, id) {
          let current = id;
          for (let i = 0; i < 8; i++) {
            const parent = state.parents.get(current);
            if (!parent) return current;
            current = parent;
          }
          return current;
        }

        // A turn is open from its start to its end. A session first heard
        // mid-turn (the plugin was loaded under it) has no phase until an
        // event proves one.
        function begin(state, root) {
          const was = state.phase.get(root);
          store(state.phase, root, "busy", LINK_LIMIT);
          if (was !== "busy") clearAsks(state, root);
          return was !== "busy";
        }

        function end(state, root) {
          const was = state.phase.get(root);
          store(state.phase, root, "idle", LINK_LIMIT);
          if (was === "busy") clearAsks(state, root);
          return was === "busy";
        }

        // An interrupted turn never hears its dialogs answered, and a dialog
        // from a finished turn must not hold the next one back.
        function clearAsks(state, root) {
          for (const id of Array.from(state.outstanding.keys())) {
            if (rootOf(state, id) === root) state.outstanding.delete(id);
          }
          for (const entry of Array.from(state.held.entries())) {
            if (rootOf(state, entry[1].session) === root) state.held.delete(entry[0]);
          }
        }

        // Whether a dialog of this root session or any of its children is
        // up. Another tool of the same turn starting or finishing meanwhile
        // says nothing about it, and Swift would read it as the answer (a
        // reply with two tool calls asks twice, and a read goes on beside
        // a shell that waits).
        function waiting(state, root) {
          for (const entry of state.outstanding) {
            if (entry[1].size > 0 && rootOf(state, entry[0]) === root) return true;
          }
          return false;
        }

        function inside(state, root) {
          if (state.phase.get(root) === undefined) store(state.phase, root, "busy", LINK_LIMIT);
        }

        function closed(state, root) {
          return state.phase.get(root) === "idle";
        }

        function make(state, input, ev, id, type, fields) {
          const root = rootOf(state, id);
          const body = { event: type, session: root, line: input.line, plugin_version: PLUGIN_VERSION };
          if (ev.id) body.id = ev.id;
          if (root !== id) body.child = id;
          const directory = state.dirs.get(root) || state.dirs.get(id) || input.directory;
          if (directory) body.directory = directory;
          const version = input.version || state.version;
          if (version) body.opencode_version = version;
          return Object.assign(body, fields);
        }

        function askOf(p) {
          const meta = (p.metadata && typeof p.metadata === "object") ? p.metadata : {};
          const files = Array.isArray(meta.files) ? meta.files : [];
          return {
            id: nonEmpty(p.id),
            kind: nonEmpty(p.permission) || nonEmpty(p.action) || "permission",
            patterns: strings(p.patterns || p.resources) || [],
            command: cut(meta.command, TEXT_LIMIT),
            file: cut(meta.filepath, TEXT_LIMIT) || cut(files[0] && files[0].file, TEXT_LIMIT),
          };
        }

        function questionAsk(id, list) {
          return { id, kind: "question", patterns: [], questions: questions(list) || [] };
        }

        function formQuestions(form) {
          const fields = Array.isArray(form && form.fields) ? form.fields : [];
          return fields.slice(0, LIST_LIMIT).map((f) => ({
            question: cut(f && (f.description || f.title), TEXT_LIMIT),
            header: cut(f && f.title, TEXT_LIMIT),
            options: Array.isArray(f && f.options)
              ? f.options.slice(0, LIST_LIMIT).map((o) => ({ label: cut(o && o.label, TEXT_LIMIT), description: cut(o && o.description, TEXT_LIMIT) }))
              : [],
          }));
        }

        function raise(state, id, key) {
          let set = state.outstanding.get(id);
          if (!set) { set = new Set(); state.outstanding.set(id, set); }
          set.add(key);
        }

        // An answer lifts the wait when no other dialog of the session is up.
        function answered(state, input, ev, id, key, type, reply) {
          if (state.held.has(key)) { state.held.delete(key); return []; }
          const set = state.outstanding.get(id);
          if (set) set.delete(key);
          if (set && set.size > 0) return [];
          return [{ send: make(state, input, ev, id, type, { reply }) }];
        }

        // reduce(state, input) -> [{ send: body } | { hold: { token, ms } }]
        // input: { raw, line (1 or 2), directory, version }
        function reduce(state, input) {
          const ev = input && input.raw;
          if (!ev || typeof ev.type !== "string") return [];
          if (ev.id) {
            if (state.seen.has(ev.id)) return [];
            remember(state.seen, ev.id, SEEN_LIMIT);
          }
          const type = ev.type;
          const p = ev.properties || ev.data || {};
          const id = sessionOf(p);
          if (!id) return [];
          const where = directoryOf(ev, p);
          if (where) store(state.dirs, id, where, LINK_LIMIT);
          if (isNoise(type)) return [];
          if (type === "session.created") {
            const version = nonEmpty(p.info && p.info.version) || nonEmpty(p.version);
            if (version && !state.version) state.version = version;
          }
          const root = rootOf(state, id);
          const child = root !== id;
          switch (type) {
            case "session.created": {
              const parent = nonEmpty(p.info && p.info.parentID) || nonEmpty(p.parentID);
              if (parent) { store(state.parents, id, parent, LINK_LIMIT); return []; }
              return [{ send: make(state, input, ev, id, type, {}) }];
            }
            case "session.deleted": {
              if (child || state.parents.has(id)) { state.parents.delete(id); return []; }
              clearAsks(state, id);
              state.phase.delete(id); state.dirs.delete(id);
              return [{ send: make(state, input, ev, id, type, {}) }];
            }
            case "session.status": {
              if (child) return [];
              const status = p.status && p.status.type;
              if (status === "busy") return begin(state, root) ? [{ send: make(state, input, ev, id, type, { status }) }] : [];
              if (status === "idle") return end(state, root) ? [{ send: make(state, input, ev, id, "session.idle", {}) }] : [];
              return [];
            }
            case "session.idle":
              if (child) return [];
              return end(state, root) ? [{ send: make(state, input, ev, id, type, {}) }] : [];
            case "session.error": {
              if (child) return [];
              return end(state, root) ? [{ send: make(state, input, ev, id, type, { error: cut(p.error && p.error.name, 200) }) }] : [];
            }
            case "session.execution.started":
              if (child) return [];
              return begin(state, root) ? [{ send: make(state, input, ev, id, type, {}) }] : [];
            case "session.execution.succeeded":
            case "session.execution.interrupted":
              if (child) return [];
              return end(state, root) ? [{ send: make(state, input, ev, id, type, {}) }] : [];
            case "session.execution.failed":
              if (child) return [];
              return end(state, root) ? [{ send: make(state, input, ev, id, type, { error: cut(p.error && p.error.type, 200) }) }] : [];
            case "message.part.updated": {
              const part = p.part;
              if (!part || part.type !== "tool") return [];
              const status = part.state && part.state.status;
              if (status !== "running" && status !== "completed" && status !== "error") return [];
              const key = part.callID + ":" + status;
              if (state.tools.has(key)) return [];
              if (waiting(state, root)) return [];
              remember(state.tools, key, SEEN_LIMIT);
              if (closed(state, root)) return [];
              inside(state, root);
              return [{ send: make(state, input, ev, id, type, {
                status, tool: cut(part.tool, 200), call: cut(part.callID, 200), input: pick(part.state.input),
              }) }];
            }
            case "session.tool.input.started": {
              if (nonEmpty(p.id) && nonEmpty(p.name)) store(state.calls, p.id, p.name, LINK_LIMIT);
              return [];
            }
            case "session.tool.called":
            case "session.tool.success":
            case "session.tool.failed": {
              const call = nonEmpty(p.id);
              const key = type + ":" + call;
              if (state.tools.has(key)) return [];
              const tool = call ? state.calls.get(call) : undefined;
              if (type !== "session.tool.called" && call) state.calls.delete(call);
              if (waiting(state, root)) return [];
              remember(state.tools, key, SEEN_LIMIT);
              if (closed(state, root)) return [];
              inside(state, root);
              const fields = { tool: cut(tool, 200), call: cut(call, 200) };
              if (type === "session.tool.called") fields.input = pick(p.input);
              if (type === "session.tool.failed") fields.error = cut(p.error && p.error.type, 200);
              return [{ send: make(state, input, ev, id, type, fields) }];
            }
            case "permission.asked": {
              const ask = askOf(p);
              if (!ask.id) return [];
              inside(state, root);
              const body = make(state, input, ev, id, type, { ask });
              store(state.held, ask.id, { body, session: id }, LINK_LIMIT);
              return [{ hold: { token: ask.id, ms: HOLD_MS } }];
            }
            case "question.asked": {
              if (!nonEmpty(p.id)) return [];
              inside(state, root);
              raise(state, id, p.id);
              return [{ send: make(state, input, ev, id, type, { ask: questionAsk(p.id, p.questions) }) }];
            }
            case "form.created": {
              const form = p.form;
              if (!form || !nonEmpty(form.id) || !(form.metadata && form.metadata.kind === "question")) break;
              inside(state, root);
              raise(state, id, form.id);
              return [{ send: make(state, input, ev, id, type, { ask: { id: form.id, kind: "question", patterns: [], questions: formQuestions(form) } }) }];
            }
            case "permission.replied":
            case "question.replied":
            case "question.rejected": {
              const key = nonEmpty(p.requestID);
              if (!key) return [];
              const reply = type === "question.rejected" ? "reject" : (nonEmpty(p.reply) || "once");
              return answered(state, input, ev, id, key, type, reply);
            }
            case "form.replied": {
              const key = nonEmpty(p.id);
              if (!key) return [];
              return answered(state, input, ev, id, key, type, "once");
            }
            default:
              break;
          }
          return [{ send: make(state, input, ev, id, type, {}) }];
        }

        // The hold ran out: the permission is still unanswered, so it is real.
        function release(state, token) {
          const held = state.held.get(token);
          if (!held) return [];
          state.held.delete(token);
          raise(state, held.session, token);
          return [{ send: held.body }];
        }
        """#
    }

    /// Built, not written out: a line that begins with the word reads as a
    /// Swift import to the boundary test (`ImportPurityTests`).
    private static let imports = [("request", "node:http"), ("homedir", "node:os")]
        .map { "import { \($0.0) } from \"\($0.1)\";" }.joined(separator: "\n")

    /// The part that talks: Evlat's socket over `node:http`, a queue that
    /// keeps the events in order, and the two entry points.
    static var wrapper: String {
        #"""
        const SOCKET = "\#(EvlatSocket.relativePath)";
        const ROUTE = "\#(route)";
        const HOST = "127.0.0.1:\#(LocalAPI.defaultPort)";
        const TIMEOUT_MS = \#(requestTimeoutMilliseconds);
        const QUEUE_LIMIT = 200;

        // One state for the process: 2.x boots a plugin instance per folder and every
        // instance receives every event.
        const shared = (globalThis[Symbol.for("evlat.opencode.plugin")] ??= {
          state: createState(), server: false, queue: Promise.resolve(), queued: 0, version: null,
        });

        function post(body, pid) {
          return new Promise((resolve) => {
            let done = false;
            const finish = () => { if (!done) { done = true; resolve(); } };
            try {
              const data = Buffer.from(JSON.stringify(body));
              const headers = { Host: HOST, "Content-Type": "application/json", "Content-Length": data.length };
              if (pid) headers["X-Evlat-Pid"] = String(process.pid);
              const req = request({ socketPath: (process.env.HOME || homedir()) + "/" + SOCKET, path: ROUTE, method: "POST", headers }, (res) => {
                res.on("error", finish);
                res.on("end", finish);
                res.resume();
              });
              req.setTimeout(TIMEOUT_MS, () => req.destroy());
              req.on("error", finish);
              req.on("close", finish);
              req.end(data);
            } catch (error) { finish(); }
          });
        }

        function enqueue(body, pid) {
          if (shared.queued >= QUEUE_LIMIT) return;
          shared.queued += 1;
          shared.queue = shared.queue.then(() => post(body, pid)).catch(() => {}).then(() => { shared.queued -= 1; });
        }

        function run(items, entry) {
          for (const item of items) {
            if (item.send) enqueue(item.send, entry.pid);
            else if (item.hold) setTimeout(() => { try { run(release(shared.state, item.hold.token), entry); } catch (error) {} }, item.hold.ms);
          }
        }

        function feed(raw, entry) {
          try {
            run(reduce(shared.state, { raw, line: entry.line, directory: entry.directory, version: entry.version() }), entry);
          } catch (error) {}
        }

        function learnVersion(input) {
          try {
            const client = input && input.client && input.client._client;
            if (shared.version || !client || typeof client.get !== "function") return;
            Promise.resolve(client.get({ url: "/global/health" })).then((reply) => {
              const version = reply && ((reply.data && reply.data.version) || reply.version);
              if (typeof version === "string") shared.version = version;
            }).catch(() => {});
          } catch (error) {}
        }

        // 1.x: the TUI, `run`, `serve` and the desktop app. The plugin runs in the
        // agent's own process, so its pid is the agent's.
        async function server(input) {
          shared.server = true;
          const entry = {
            line: 1, pid: true, directory: typeof (input && input.directory) === "string" ? input.directory : undefined,
            version: () => shared.version,
          };
          learnVersion(input);
          return { event: async ({ event }) => feed(event, entry) };
        }

        // 2.x: the pid is the agent's only when it runs for one TUI (`--standalone`
        // starts `serve --stdio`); the shared service belongs to no terminal.
        async function setup(ctx) {
          try {
            if (shared.server || !ctx || !ctx.event || typeof ctx.event.subscribe !== "function") return;
            const entry = {
              line: 2, pid: Array.isArray(process.argv) && process.argv.includes("--stdio"), directory: undefined,
              version: () => ctx.app && ctx.app.version,
            };
            const events = ctx.event.subscribe();
            (async () => { try { for await (const event of events) feed(event, entry); } catch (error) {} })();
          } catch (error) {}
        }

        export default { id: "evlat", server, setup };
        """#
    }

    private static func json(_ list: [String]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: list, options: [.withoutEscapingSlashes])) ?? Data("[]".utf8)
        return String(decoding: data, as: UTF8.self)
    }
}
