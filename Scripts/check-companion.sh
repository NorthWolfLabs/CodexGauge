#!/bin/zsh
# Local, disposable relay checks; never loads production push credentials.
set -euo pipefail
root="${0:A:h:h}"
port="${COMPANION_TEST_PORT:-8794}"
[[ "$port" == <-> && "$port" -ge 1024 && "$port" -le 65535 ]] || { print -u2 'Choose an unprivileged COMPANION_TEST_PORT.'; exit 1; }
command -v vp >/dev/null || { print -u2 'Vite+ (vp) is required.'; exit 1; }
if lsof -nP -iTCP:"$port" -sTCP:LISTEN >/dev/null 2>&1; then
  print -u2 "Port $port is busy. Set COMPANION_TEST_PORT to another port."
  exit 1
fi
run_dir="$(mktemp -d "${TMPDIR:-/tmp/}codexgauge-relay-check.XXXXXX")"
server_pid=''
socket_pid=''
collect_tree() {
  local parent="$1" child
  process_tree+=("$parent")
  for child in $(pgrep -P "$parent" 2>/dev/null || true); do collect_tree "$child"; done
}
stop_tree() {
  local -a process_tree=()
  collect_tree "$1"
  # Snapshot descendants first, then stop parents before workers. Killing only
  # children first lets Wrangler's watch process respawn an orphan during cleanup.
  kill -TERM "${process_tree[@]}" 2>/dev/null || true
}
cleanup() {
  # Cleanup must also run after a failed test under errexit. A descendant may
  # exit between discovery and kill; that must not skip the other fixture.
  set +e
  if [[ -n "$socket_pid" ]]; then stop_tree "$socket_pid"; wait "$socket_pid" 2>/dev/null || true; fi
  if [[ -n "$server_pid" ]]; then stop_tree "$server_pid"; wait "$server_pid" 2>/dev/null || true; fi
  # Keep diagnostics on failure; state belongs only to this synthetic run.
  print "Relay check artifacts: $run_dir"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
cd "$root"
cd Companion/Relay
vp run typecheck
# An explicit env file skips Wrangler's automatic .dev.vars/.env discovery.
print 'APNS_PRIVATE_KEY=' > "$run_dir/test.env"
vp exec wrangler dev --local --ip 127.0.0.1 --port "$port" \
  --persist-to "$run_dir/state" --env-file "$run_dir/test.env" > "$run_dir/server.log" 2>&1 &
server_pid=$!
ready=false
for attempt in {1..100}; do
  if curl --silent --fail "http://127.0.0.1:$port/health" >/dev/null; then ready=true; break; fi
  kill -0 "$server_pid" 2>/dev/null || { cat "$run_dir/server.log"; exit 1; }
  sleep 0.2
done
[[ "$ready" == true ]] || { cat "$run_dir/server.log"; exit 1; }
vp exec node tests/socket-fixture.mjs > "$run_dir/socket-url" 2> "$run_dir/socket.log" &
socket_pid=$!
for attempt in {1..50}; do
  [[ -s "$run_dir/socket-url" ]] && break
  kill -0 "$socket_pid" 2>/dev/null || { cat "$run_dir/socket.log"; exit 1; }
  sleep 0.1
done
socket_url="$(cat "$run_dir/socket-url")"
[[ "$socket_url" == ws://127.0.0.1:<-> ]] || { cat "$run_dir/socket.log"; exit 1; }
COMPANION_SOCKET_FIXTURE_URL="$socket_url" COMPANION_WIRE_FIXTURE_PATH="$run_dir/wire.json" swift test --package-path "$root/Companion"
RELAY_URL="http://127.0.0.1:$port" COMPANION_WIRE_FIXTURE_PATH="$run_dir/wire.json" vp run test
vp run build
print 'Companion core, relay types, relay integration tests, and bundle checks passed.'
