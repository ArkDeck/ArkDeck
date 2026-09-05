#!/bin/sh
# SPK-2 orchestration. Every step is logged; the production LaunchAgent is
# booted out for the shortest window that covers the raw-xpc measurements and
# bootstrapped back from its own plist, then verified over the Unix socket.
#
# Usage: sh run-spike.sh <spk2-root> <phase>
#   phase = baseline | swap-in | measure | swap-out | verify
set -eu
ROOT="$1"
PHASE="$2"
BUILD="$ROOT/build"
RESULTS="$ROOT/results"
LABEL="com.arkdeck.agentd"
DOMAIN="gui/$(id -u)"
PRODUCTION_PLIST="$HOME/Library/LaunchAgents/com.arkdeck.agentd.plist"
SPIKE_PLIST="$ROOT/launchd/com.arkdeck.agentd.spk2.plist"
SOCKET="$HOME/Library/Application Support/ArkDeck/Agentd/agentd.sock"
CLIENT="$BUILD/SPK2Client.app/Contents/MacOS/spk2-client"
mkdir -p "$RESULTS"

stamp() { date -u +%Y-%m-%dT%H:%M:%SZ; }
say() { printf '%s %s\n' "$(stamp)" "$*" | tee -a "$RESULTS/run.log"; }

uds_health() {
  python3 - "$SOCKET" <<'EOF'
import json, socket, sys, time
path = sys.argv[1]
s = None
deadline = time.time() + 20
while True:
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.settimeout(10)
    try:
        s.connect(path)
        break
    except OSError as error:
        if time.time() > deadline:
            print("UDS connect failed:", error)
            sys.exit(1)
        time.sleep(0.5)
frame = json.dumps({"protocolVersion": "1.0.0", "id": "spk2", "method": "health", "params": None}, separators=(",", ":")) + "\n"
t = time.perf_counter()
s.sendall(frame.encode())
buffer = b""
while not buffer.endswith(b"\n"):
    chunk = s.recv(65536)
    if not chunk:
        break
    buffer += chunk
reply = json.loads(buffer)
print("UDS health ok=%s status=%s rtt=%.3f ms" % (reply.get("ok"), (reply.get("result") or {}).get("status"), (time.perf_counter() - t) * 1000))
EOF
}

service_state() {
  launchctl print "$DOMAIN/$LABEL" 2>/dev/null | grep -E '^\s*(state|pid|program) =' | tr -s ' ' | tr '\n' ';'
  echo
}

case "$PHASE" in
baseline)
  say "phase baseline: production daemon state: $(service_state)"
  uds_health | tee -a "$RESULTS/run.log"
  for spec in "runtime.storage.status 2.0.0" "target.list 1.0.0"; do
    set -- $spec
    say "nsxpc round trips against the production Swift daemon: $1 @ $2 (sandboxed client, Developer ID)"
    "$CLIENT" nsxpc --count 1000 --warmup 100 --method "$1" --protocol "$2" \
      > "$RESULTS/baseline-nsxpc-$1.json"
    python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); r=lambda x: {k: round(v,4) if isinstance(v,float) else v for k,v in x.items()}; print("persistent", r(d["persistentConnection"])); print("per-request", r(d["connectionPerRequest"]["latency"])); print("replyBytes", d["replyBytes"], "errors", d["errors"], "refusals", d["refusals"]); print("replySample", d["replySample"][:160])' \
      "$RESULTS/baseline-nsxpc-$1.json" | tee -a "$RESULTS/run.log"
  done
  ;;

swap-in)
  say "phase swap-in: booting out the production job"
  say "before: $(service_state)"
  launchctl bootout "$DOMAIN/$LABEL"
  sleep 1
  say "after bootout: $(service_state || true)"
  rm -f "$RESULTS/listener.stderr.log" "$RESULTS/listener.stdout.log"
  launchctl bootstrap "$DOMAIN" "$SPIKE_PLIST"
  sleep 1
  say "after bootstrap of the spike plist: $(service_state)"
  launchctl print "$DOMAIN/$LABEL" > "$RESULTS/launchctl-print-spike.txt" 2>&1 || true
  ;;

measure)
  say "phase measure: raw libxpc against the Rust listener"
  run() {
    name="$1"; shift
    say "  $name: $*"
    if "$@" > "$RESULTS/$name.json" 2> "$RESULTS/$name.stderr"; then
      say "  $name: exit 0"
    else
      say "  $name: exit $?"
    fi
  }
  # A: the expected client, production entitlements.
  run a-client-roundtrips "$CLIENT" roundtrips --count 1000 --warmup 100
  run a-client-fresh "$CLIENT" fresh --count 200 --warmup 10
  run a-client-sizes "$CLIENT" sizes --count 100
  # A with the daemon identity pinned by the client (right and wrong).
  run a-client-pin-right "$CLIENT" probe --pin-server 'anchor apple generic and certificate leaf[subject.OU] = "8AQTYW5FKR" and identifier "com.arkdeck.spk2-listener"'
  run a-client-pin-wrong "$CLIENT" probe --pin-server 'anchor apple generic and certificate leaf[subject.OU] = "8AQTYW5FKR" and identifier "com.arkdeck.agentd"'
  # B: ad-hoc signature, same entitlements.
  run b-adhoc-probe "$BUILD/SPK2ClientAdhoc.app/Contents/MacOS/spk2-client" probe --timeout 5
  # C: Developer ID, wrong identifier.
  run c-impostor-probe "$BUILD/SPK2Impostor.app/Contents/MacOS/spk2-client" probe --timeout 5
  # D: right identity, sandbox without the mach-lookup exception.
  run d-nolookup-probe "$BUILD/SPK2ClientNoLookup.app/Contents/MacOS/spk2-client" probe --timeout 5
  # E: Apple Development certificate, right identifier.
  run e-devcert-probe "$BUILD/SPK2ClientDevCert.app/Contents/MacOS/spk2-client" probe --timeout 5
  # F: bare unsandboxed ad-hoc tool.
  run f-bare-probe "$BUILD/spk2-bare" probe --timeout 5
  ;;

swap-out)
  say "phase swap-out: booting out the spike job, bootstrapping the production plist"
  launchctl bootout "$DOMAIN/$LABEL" || say "  bootout of the spike job returned $?"
  sleep 1
  launchctl bootstrap "$DOMAIN" "$PRODUCTION_PLIST"
  sleep 3
  say "after restore: $(service_state)"
  ;;

verify)
  say "phase verify: production daemon reachable again"
  say "state: $(service_state)"
  uds_health | tee -a "$RESULTS/run.log"
  launchctl print "$DOMAIN/$LABEL" | grep -E 'path =|program =|state =' | head -3 | tee -a "$RESULTS/run.log"
  ;;

*)
  echo "unknown phase $PHASE" >&2
  exit 2
  ;;
esac
