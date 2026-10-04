#!/bin/sh
# A full bar to look at: an isolated Evlat (its own port, home, sessions and
# chats; the user's Evlat and files untouched) filled with every kind of row —
# local sessions in each phase, worktrees of one repository, Codex, three
# remote machines through the fake ssh, Docker sandboxes, outside jobs and
# usage windows. A local approval and a local question are held, so their cards
# draw their buttons (a press answers only the demo's own request); the remote
# and sandboxed waits are only heard, as they are for real.
#
#   scripts/demo.sh [left|right] [--no-build]
#       --no-build  run the binary already built
#   scripts/demo.sh stop
#
# Everything lives under $TMPDIR/evlat-demo and goes on the next start or stop.
set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
DIR="${TMPDIR:-/tmp}"
DIR="${DIR%/}/evlat-demo"
PORT=48999
SANDBOX_PORT=48998

stop() {
    [ -d "$DIR" ] || return 0
    for f in "$DIR"/*.pid; do
        [ -f "$f" ] || continue
        while read -r pid; do
            [ -n "$pid" ] && kill "$pid" 2>/dev/null || true
        done < "$f"
    done
    case "$DIR" in */evlat-demo) rm -rf "$DIR" ;; esac
}

EDGE=left
BUILD=1
for arg in "$@"; do
    case "$arg" in
        stop) stop; exit 0 ;;
        left|right) EDGE=$arg ;;
        --no-build) BUILD=0 ;;
        *) echo "usage: scripts/demo.sh [left|right] [--no-build] | stop" >&2; exit 2 ;;
    esac
done

stop
[ "$BUILD" = 1 ] && (cd "$ROOT" && swift build >/dev/null)
mkdir -p "$DIR/home/.claude" "$DIR/home/.codex/sessions" "$DIR/home/.gemini/antigravity-cli" \
         "$DIR/sessions" "$DIR/chats"

# Stand-ins for the agents' processes: a session record lives as long as its
# pid does and the process started when the record says.
for _ in 1 2 3 4 5 6 7 8 9; do
    sleep 86400 </dev/null >/dev/null 2>&1 &
    echo $! >> "$DIR/agents.pid"
done

EVLAT_PORT=$PORT EVLAT_HOME="$DIR/home" EVLAT_SESSIONS="$DIR/sessions" EVLAT_CHATS="$DIR/chats" \
EVLAT_EDGE=$EDGE EVLAT_BODY=always \
EVLAT_MACHINES="dev@10.0.4.21,ubuntu@192.168.1.217,deploy@gpu-01.eu-central.internal.example.com" \
EVLAT_SSH="$ROOT/Tests/Fixtures/fake-ssh" FAKE_SSH_LOG="$DIR/ssh.log" \
EVLAT_SANDBOXES=on EVLAT_SANDBOX_PORT=$SANDBOX_PORT \
    nohup "$ROOT/.build/debug/Evlat" > "$DIR/evlat.log" 2>&1 </dev/null &
echo $! > "$DIR/evlat.pid"

# Ready once it answers; the machines' listeners are logged by then.
tries=0
until curl -s -m 1 "http://127.0.0.1:$PORT/health" >/dev/null 2>&1; do
    tries=$((tries + 1))
    [ "$tries" -lt 50 ] || { echo "Evlat did not come up; see $DIR/evlat.log" >&2; exit 1; }
    sleep 0.2
done

python3 "$ROOT/scripts/demo-seed.py" --dir "$DIR" --repo "$ROOT" --port $PORT \
    --sandbox-port $SANDBOX_PORT
echo "Demo up on the $EDGE edge. Stop it with: scripts/demo.sh stop"
