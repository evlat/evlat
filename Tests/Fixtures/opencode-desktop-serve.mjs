// Runs the OpenCode desktop app's own server module (out/main/chunks/node-*.js)
// under the app's Electron-as-Node, the way out/main/sidecar.js does, minus the
// parent port. The archive is read in place, as the app reads it.
// usage: ELECTRON_RUN_AS_NODE=1 OpenCode opencode-desktop-serve.mjs APP.ASAR PORT
// Basic auth `opencode:pw`; the routes that need it answer 401 for a moment after /global/health does.
import * as http from "node:http"
import { readdirSync } from "node:fs"
const [asar, port] = process.argv.slice(2)
for (const key of ["NO_PROXY", "no_proxy"]) {
  const items = (process.env[key] ?? "").split(",").map((v) => v.trim()).filter(Boolean)
  for (const h of ["127.0.0.1", "localhost", "::1"]) if (!items.includes(h)) items.push(h)
  process.env[key] = items.join(",")
}
Object.assign(process.env, { OPENCODE_SERVER_USERNAME: "opencode", OPENCODE_SERVER_PASSWORD: "pw" })
try { http.setGlobalProxyFromEnv() } catch {}
const chunk = readdirSync(asar + "/out/main/chunks").find((f) => /^node-.*\.js$/.test(f))
const { Server } = await import(asar + "/out/main/chunks/" + chunk)
await Server.listen({ port: Number(port), hostname: "127.0.0.1", username: "opencode", password: "pw", cors: ["oc://renderer"] })
console.log("desk-serve listening", port)
