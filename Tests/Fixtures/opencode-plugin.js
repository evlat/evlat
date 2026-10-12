// evlat-opencode-plugin
// version 2
// Evlat's plugin for OpenCode. Evlat wrote this file and rewrites it when a newer
// one is needed; delete it (or use Evlat's settings) to remove it.
// It tells Evlat's socket what a session is doing and, when you press Allow once
// or Deny on Evlat's bar, gives OpenCode that answer. Nothing else, and it stays
// silent when Evlat is not running.
import { request } from "node:http";
import { homedir } from "node:os";
const NOISE = ["*.delta","plugin.added","catalog.updated","reference.updated","integration.updated","model.updated","provider.updated","agent.updated","command.updated","skill.updated","websearch.updated","plugin.updated","vcs.branch.updated","models-dev.refreshed","session.updated","session.diff","session.renamed","message.updated","session.step.*","session.text.*","session.reasoning.*","session.usage.updated","session.inbox.*","session.instructions.updated","session.tool.input.ended","session.tool.progress","session.retry.scheduled","shell.*","location.shutdown"];
const INPUT_KEYS = ["command","filePath","path","pattern","url","query","description","questions"];
const TEXT_LIMIT = 2000;
const HOLD_MS = 300;
const PLUGIN_VERSION = 2;
const DECISION_FIELD = "decision";
const DECISIONS = ["once", "reject"];
const DEFER_LIMIT = 64;
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
    calls: new Map(), held: new Map(), outstanding: new Map(), bridges: new Map(), deferred: new Map(),
    version: null,
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
  // The card of a finished turn is let go by Evlat (it hears the turn end); what
  // was waiting its turn behind it is never opened.
  state.bridges.delete(root);
  state.deferred.delete(root);
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

// The outcome of a tool that ended while a dialog of its turn was up: told once
// the wait lifts, or Swift would count one tool fewer than ran.
function defer(state, root, body) {
  const list = state.deferred.get(root) || [];
  list.push(body);
  if (list.length > DEFER_LIMIT) list.shift();
  state.deferred.set(root, list);
}

function flush(state, root) {
  const list = state.deferred.get(root);
  state.deferred.delete(root);
  if (!list || waiting(state, root) || closed(state, root)) return [];
  return list.map((body) => ({ send: body }));
}

// One permission of a root session is on the card at a time: Evlat lets an older
// request of the same session go when a newer one arrives, and OpenCode asks twice
// at once when one reply holds two tool calls. The rest wait their turn here.
function offerBridge(state, ask) {
  const root = ask.body.session;
  let slot = state.bridges.get(root);
  if (!slot) { slot = { front: null, queue: [] }; store(state.bridges, root, slot, LINK_LIMIT); }
  if (slot.front === null) { slot.front = ask.id; return [{ bridge: ask }]; }
  slot.queue.push(ask);
  return [];
}

function advanceBridge(state, root, slot) {
  const next = slot.queue.shift();
  if (!next) { state.bridges.delete(root); return []; }
  slot.front = next.id;
  return [{ bridge: next }];
}

// OpenCode said the permission is answered (here, in its own dialog, or by a
// restart): the card is let go, and the next one of the session opens.
function leaveBridge(state, key) {
  for (const entry of Array.from(state.bridges.entries())) {
    const slot = entry[1];
    if (slot.front === key) return [{ abort: key }].concat(advanceBridge(state, entry[0], slot));
    const at = slot.queue.findIndex((ask) => ask.id === key);
    if (at >= 0) { slot.queue.splice(at, 1); return []; }
  }
  return [];
}

// The card's answer was applied: its place is the next one's.
function applied(state, key) {
  for (const entry of Array.from(state.bridges.entries())) {
    if (entry[1].front === key) return advanceBridge(state, entry[0], entry[1]);
  }
  return [];
}

// The only reply that is an answer: 200 and exactly one of the two words.
// `{}`, a refusal, a closed connection and the time running out are none.
function decisionOf(status, text) {
  if (status !== 200 || typeof text !== "string") return null;
  try {
    const value = JSON.parse(text);
    const decision = value && typeof value === "object" ? value[DECISION_FIELD] : null;
    return DECISIONS.includes(decision) ? decision : null;
  } catch (error) { return null; }
}

// An answer lifts the wait when no other dialog of the session is up.
function answered(state, input, ev, id, key, type, reply) {
  if (state.held.has(key)) { state.held.delete(key); return []; }
  const bridge = leaveBridge(state, key);
  const set = state.outstanding.get(id);
  if (set) set.delete(key);
  if (set && set.size > 0) return bridge;
  return bridge.concat([{ send: make(state, input, ev, id, type, { reply }) }], flush(state, rootOf(state, id)));
}

// reduce(state, input) -> [{ send: body } | { hold: { token, ms } } | { bridge: ask } | { abort: id }]
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
      const fields = { status, tool: cut(part.tool, 200), call: cut(part.callID, 200), input: pick(part.state.input) };
      if (waiting(state, root)) {
        // A start comes again when OpenCode says it again; an outcome does not.
        if (status !== "running") { remember(state.tools, key, SEEN_LIMIT); defer(state, root, make(state, input, ev, id, type, fields)); }
        return [];
      }
      remember(state.tools, key, SEEN_LIMIT);
      if (closed(state, root)) return [];
      inside(state, root);
      return [{ send: make(state, input, ev, id, type, fields) }];
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
      const fields = { tool: cut(tool, 200), call: cut(call, 200) };
      if (type === "session.tool.called") fields.input = pick(p.input);
      if (type === "session.tool.failed") fields.error = cut(p.error && p.error.type, 200);
      if (waiting(state, root)) {
        if (type !== "session.tool.called") { remember(state.tools, key, SEEN_LIMIT); defer(state, root, make(state, input, ev, id, type, fields)); }
        return [];
      }
      remember(state.tools, key, SEEN_LIMIT);
      if (closed(state, root)) return [];
      inside(state, root);
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

// The hold ran out: the permission is still unanswered, so it is real. It is told,
// and it goes to the card (the bridge) when it is the session's turn.
function release(state, token) {
  const held = state.held.get(token);
  if (!held) return [];
  state.held.delete(token);
  raise(state, held.session, token);
  return [{ send: held.body }].concat(offerBridge(state, { id: token, session: held.session, body: held.body }));
}
const SOCKET = ".config/evlat/run/evlat.sock";
const ROUTE = "/hook/opencode";
const APPROVAL_ROUTE = "/approval/opencode";
const HOST = "127.0.0.1:48151";
const TIMEOUT_MS = 2000;
const BRIDGE_TIMEOUT_MS = 600000;
const QUEUE_LIMIT = 200;
const REPLIER_LIMIT = 64;

// One state for the process: 2.x boots a plugin instance per folder and every
// instance receives every event.
const shared = (globalThis[Symbol.for("evlat.opencode.plugin")] ??= {
  state: createState(), server: false, queue: Promise.resolve(), queued: 0, version: null,
  inflight: new Map(), repliers: [],
});

// Resolves { status, text } when Evlat answered, else null; never rejects. The
// process's pid goes with an event: the agent's own where this process is its
// (`options.pid` true), the service's where it is shared by many terminals
// (`false`); a post that says nothing of it (the bridge) sends none.
function post(route, body, options) {
  return new Promise((resolve) => {
    let done = false;
    let responded = false;
    const finish = (reply) => { if (!done) { done = true; resolve(reply || null); } };
    try {
      const data = Buffer.from(JSON.stringify(body));
      const headers = { Host: HOST, "Content-Type": "application/json", "Content-Length": data.length };
      if (options.pid) headers["X-Evlat-Pid"] = String(process.pid);
      else if (options.pid === false) headers["X-Evlat-Service-Pid"] = String(process.pid);
      const req = request({ socketPath: (process.env.HOME || homedir()) + "/" + SOCKET, path: route, method: "POST", headers }, (res) => {
        responded = true;
        const chunks = [];
        const answer = () => finish({ status: res.statusCode, text: Buffer.concat(chunks).toString("utf8") });
        res.on("data", (chunk) => chunks.push(chunk));
        res.on("error", () => finish(null));
        res.on("end", answer);
        res.on("close", answer);
      });
      if (options.held) options.held.req = req;
      req.setTimeout(options.timeout, () => req.destroy());
      req.on("error", () => finish(null));
      req.on("close", () => { if (!responded) finish(null); });
      req.end(data);
    } catch (error) { finish(null); }
  });
}

function enqueue(body, pid) {
  if (shared.queued >= QUEUE_LIMIT) return;
  shared.queued += 1;
  shared.queue = shared.queue.then(() => post(ROUTE, body, { pid, timeout: TIMEOUT_MS })).catch(() => {}).then(() => { shared.queued -= 1; });
}

// The permission on the card: a request held until the user presses a button, or
// until OpenCode says the permission is answered and `abortBridge` closes it.
function openBridge(bridge, entry) {
  if (shared.inflight.has(bridge.id)) return;
  const held = { req: null, aborted: false };
  shared.inflight.set(bridge.id, held);
  post(APPROVAL_ROUTE, bridge.body, { timeout: BRIDGE_TIMEOUT_MS, held }).then((reply) => {
    shared.inflight.delete(bridge.id);
    const decision = held.aborted || !reply ? null : decisionOf(reply.status, reply.text);
    if (!decision) return null;
    return apply(bridge, decision, entry).then((done) => { if (done) run(applied(shared.state, bridge.id), entry); });
  }).catch(() => {});
}

function abortBridge(id) {
  const held = shared.inflight.get(id);
  if (!held) return;
  held.aborted = true;
  try { if (held.req) held.req.destroy(); } catch (error) {}
}

// The decision goes to the instance that heard the ask, then to the others: 2.x
// boots one per folder and only the session's own can answer ("not found" from
// the rest).
async function apply(bridge, decision, entry) {
  for (const candidate of [entry].concat(shared.repliers.filter((other) => other !== entry))) {
    try {
      if (candidate && typeof candidate.reply === "function" && await candidate.reply(bridge.session, bridge.id, decision)) return true;
    } catch (error) {}
  }
  return false;
}

function enroll(entry) {
  shared.repliers.push(entry);
  if (shared.repliers.length > REPLIER_LIMIT) shared.repliers.shift();
}

function run(items, entry) {
  for (const item of items) {
    if (item.send) enqueue(item.send, entry.pid);
    else if (item.bridge) openBridge(item.bridge, entry);
    else if (item.abort) abortBridge(item.abort);
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
    reply: async (session, id, decision) => {
      const result = await input.client.postSessionIdPermissionsPermissionId({ path: { id: session, permissionID: id }, body: { response: decision } });
      const status = result && result.response && result.response.status;
      return !!result && !result.error && (typeof status === "number" ? status >= 200 && status < 300 : result.data !== undefined);
    },
  };
  enroll(entry);
  learnVersion(input);
  return { event: async ({ event }) => feed(event, entry) };
}

// 2.x: the pid is the agent's only when it runs for one TUI (`--standalone`
// starts `serve --stdio`); the shared service belongs to no terminal, and its
// pid goes as the service's.
async function setup(ctx) {
  try {
    if (shared.server || !ctx || !ctx.event || typeof ctx.event.subscribe !== "function") return;
    const entry = {
      line: 2, pid: Array.isArray(process.argv) && process.argv.includes("--stdio"), directory: undefined,
      version: () => ctx.app && ctx.app.version,
      reply: async (session, id, decision) => {
        const result = await ctx.permission.reply({ sessionID: session, requestID: id, decision });
        return !(result && result.error);
      },
    };
    enroll(entry);
    const events = ctx.event.subscribe();
    (async () => { try { for await (const event of events) feed(event, entry); } catch (error) {} })();
  } catch (error) {}
}

export default { id: "evlat", server, setup };