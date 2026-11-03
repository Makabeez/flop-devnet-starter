#!/usr/bin/env bash
# flop-devnet.sh — from zero to a settled inference call on FLOP devnet, using the official CLI.
#
#   ./flop-devnet.sh init            new sr25519 agent key in an encrypted keystore (random password)
#   ./flop-devnet.sh fund            test FLOP for your keystore key (needed by `direct`; retries while busy)
#   ./flop-devnet.sh credential      devnet gateway key (the CLI enrolls with its own wallet; see below)
#   ./flop-devnet.sh ask "prompt"    one chat completion through the gateway; saves the full exchange
#   ./flop-devnet.sh direct "prompt" one call on a miner channel opened and settled under your own key
#   ./flop-devnet.sh status          node, balance, network stats, models, your settlements
#   ./flop-devnet.sh mcp <tool> [json-args]   call any tool on the hosted FLOP MCP server
#   ./flop-devnet.sh all "prompt"    init (if needed) -> fund -> credential -> ask -> status
#
# Devnet only. Devnet FLOP has no value and earns no rewards or airdrop weight; the chain may reset.
# Never put a seed phrase, or a key that holds real funds, anywhere near this script.
set -euo pipefail

FLOP_HOME="${FLOP_HOME:-$HOME/.flop-devnet}"
CLI_VERSION="${FLOP_CLI_VERSION:-0.4.0}"
GATEWAY="${FLOP_GATEWAY_URL:-https://api.flop.network/v1}"
MCP_URL="${FLOP_MCP_URL:-https://mcp.flop.network/mcp}"
EXPLORER="${FLOP_EXPLORER_URL:-https://explorer.devnet.flop.network}"
MODEL="${FLOP_MODEL:-qwen/qwen2.5-0.5b-instruct}"                # gateway model id
GENESIS="0x99c172c095340ace980631f9123544c6bebd4839f3437e463533422d8be2d631"

die()  { echo "error: $*" >&2; exit 1; }
need() { command -v "$1" >/dev/null 2>&1 || die "$1 is required"; }
for t in curl python3 node npx openssl; do need "$t"; done
node_major=$(node -p 'process.versions.node.split(".")[0]')
[ "$node_major" -ge 22 ] || die "Node.js 22 or newer is required (found $(node --version))"

# The CLI prints polkadot RPC-CORE noise on stderr; keep real errors.
flop() { npx --yes --package "@flop-labs/cli@${CLI_VERSION}" flop --network devnet "$@" 2> >(grep -v -e 'RPC-CORE' -e '^npm warn' >&2); }
address() { [ -f "$FLOP_HOME/address" ] || die "no agent key yet: run ./flop-devnet.sh init"; cat "$FLOP_HOME/address"; }
# Exports the keystore password in THIS shell (never call it inside $(...)).
load_password() { [ -f "$FLOP_HOME/.pw" ] || die "missing $FLOP_HOME/.pw"; FLOP_KEY_PASSWORD="$(cat "$FLOP_HOME/.pw")"; export FLOP_KEY_PASSWORD; }
signed_flop() { load_password; flop --keystore "$FLOP_HOME/agent.json" --password-env FLOP_KEY_PASSWORD "$@"; }
is_ok() { python3 -I -c 'import json,sys
try: d=json.loads(sys.stdin.read())
except ValueError: sys.exit(1)
sys.exit(0 if isinstance(d, dict) and d.get("ok") is True else 1)'; }

cmd_init() {
  umask 077; mkdir -p "$FLOP_HOME"; chmod 700 "$FLOP_HOME"
  if [ -f "$FLOP_HOME/agent.json" ]; then echo "agent key already exists: $(address)"; return; fi
  [ -f "$FLOP_HOME/.pw" ] || openssl rand -hex 16 > "$FLOP_HOME/.pw"
  chmod 600 "$FLOP_HOME/.pw"; load_password
  flop keys generate --type sr25519 --name flop-devnet-agent --out "$FLOP_HOME/agent.json" \
       --password-env FLOP_KEY_PASSWORD --json
  python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["address"])' "$FLOP_HOME/agent.json" > "$FLOP_HOME/address"
  echo "agent address: $(address)"
  echo "keystore: $FLOP_HOME/agent.json (encrypted; password in $FLOP_HOME/.pw, owner-only)"
}

cmd_fund() {
  local a out tries="${FLOP_FUND_TRIES:-30}" wait="${FLOP_FUND_WAIT:-60}" i
  a=$(address)
  for i in $(seq 1 "$tries"); do
    out=$(flop faucet request "$a" --json 2>&1 || true)   # the CLI prints failures on stderr
    if printf '%s' "$out" | is_ok; then echo "$out"; break; fi
    echo "$(date -u +%H:%M:%S)Z faucet attempt $i/$tries: $(printf '%s' "$out" | tr -d '\n' | tr -s ' ' | cut -c1-170)"
    [ "$i" -lt "$tries" ] || die "faucet still failing after $tries attempts; try again later"
    sleep "$wait"
  done
  flop balance "$a" --json
}

# NOTE (CLI 0.4.0): `agent credential` ignores --keystore. It enrolls with its OWN sr25519 wallet,
# created on first use at ~/.flop/devnet-enroll-wallet.json with the 12-word mnemonic in PLAIN TEXT
# (mode 600), funds that wallet from the faucet itself, and caches the gateway key in
# ~/.flop/devnet-wallet-agent-key.json. Devnet-only, but never reuse that mnemonic anywhere.
ENROLL_WALLET="$HOME/.flop/devnet-enroll-wallet.json"
enroll_address() { [ -f "$ENROLL_WALLET" ] && python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["address"])' "$ENROLL_WALLET"; }

cmd_credential() {
  local key out tries="${FLOP_FUND_TRIES:-30}" wait="${FLOP_FUND_WAIT:-60}" i
  for i in $(seq 1 "$tries"); do
    if out=$(flop agent credential --json 2>&1); then echo "$out"; break; fi
    echo "$(date -u +%H:%M:%S)Z credential attempt $i/$tries: $(printf '%s' "$out" | tr -d '\n' | tr -s ' ' | cut -c1-170)"
    [ "$i" -lt "$tries" ] || die "credential still failing after $tries attempts; try again later"
    sleep "$wait"
  done
  key=$(flop agent credential --print-key | tail -n 1 | tr -d '[:space:]')   # reuses the cached key
  case "$key" in flop_*) ;; *) die "no gateway key returned" ;; esac
  umask 077; printf '%s' "$key" > "$FLOP_HOME/gateway.key"; chmod 600 "$FLOP_HOME/gateway.key"
  echo "gateway key saved to $FLOP_HOME/gateway.key (owner-only; never commit, paste or screenshot it)"
  echo "enrollment wallet (created by the CLI, not your keystore): $(enroll_address)"
  echo "warning: $ENROLL_WALLET holds that wallet's mnemonic in plain text. Devnet only; never reuse it."
}

cmd_ask() {
  local prompt="${1:-Say hello from FLOP devnet in one sentence.}" run
  [ -f "$FLOP_HOME/gateway.key" ] || die "no gateway key yet: run ./flop-devnet.sh credential"
  run="$FLOP_HOME/runs/$(date -u +%Y%m%dT%H%M%SZ)"; mkdir -p "$run"
  python3 -I -c 'import json,sys; print(json.dumps({"model":sys.argv[1],"messages":[{"role":"user","content":sys.argv[2]}],"max_tokens":128}))' \
    "$MODEL" "$prompt" > "$run/request.json"
  # The key goes to curl through a header file, so it never appears in the process list.
  ( umask 077; printf 'Authorization: Bearer %s\n' "$(cat "$FLOP_HOME/gateway.key")" > "$run/.auth" )
  # 429 "gateway channel pool is full" is common on a busy devnet: honour Retry-After and try again.
  local i code tries="${FLOP_ASK_TRIES:-60}" wait
  for i in $(seq 1 "$tries"); do
    code=$(curl -sS -D "$run/headers.txt" -o "$run/response.json" -w '%{http_code}' \
         -H @"$run/.auth" -H 'Content-Type: application/json' \
         --data @"$run/request.json" "$GATEWAY/chat/completions" || echo 000)
    printf '%s' "$code" > "$run/http_code"
    case "$code" in 429|502|503|000) ;; *) break ;; esac
    wait=$(python3 -I -c 'import json,sys
try: print(int(json.load(open(sys.argv[1])).get("retry_after") or 0))
except Exception: print(0)' "$run/response.json")
    [ "$wait" -ge 30 ] || wait=30   # "channel pool is full" says retry-after: 1, but 1 s just trips the rate limit
    echo "$(date -u +%H:%M:%S)Z gateway HTTP $code ($(head -c 120 "$run/response.json" | tr -d '\n')); retry $i/$tries in ${wait}s"
    [ "$i" -lt "$tries" ] && sleep "$wait"
  done
  rm -f "$run/.auth"
  python3 -I - "$run" <<'PY'
import json, sys, pathlib
run = pathlib.Path(sys.argv[1])
print(f"HTTP {run.joinpath('http_code').read_text().strip()}  (request, headers and response saved in {run})")
for line in run.joinpath("headers.txt").read_text(errors="replace").splitlines():
    if line.lower().startswith(("x-flop", "x-task", "x-receipt", "x-settlement", "x-request-id", "x-channel")):
        print("header:", line.strip())
body = run.joinpath("response.json").read_text(errors="replace")
try:
    d = json.loads(body)
except ValueError:
    print(body[:800]); sys.exit(1)
if isinstance(d, dict) and d.get("choices"):
    print("reply :", (d["choices"][0].get("message") or {}).get("content", "").strip())
    print("model :", d.get("model"), "| id:", d.get("id"), "| usage:", d.get("usage"))
    extra = {k: v for k, v in d.items() if k not in ("choices", "model", "id", "usage", "object", "created")}
    if extra: print("other fields:", json.dumps(extra, indent=1)[:2000])
else:
    print(json.dumps(d, indent=1)[:1500]); sys.exit(1)
PY
}

# Direct path: a channel with a miner, opened and settled under YOUR keystore key (flop session run).
# It needs a live signed offer from a miner; tries each miner that quotes the model on the gateway.
cmd_direct() {
  local prompt="${1:-Say hello from FLOP devnet in one sentence.}" miners m out
  miners=$(curl -sS "$GATEWAY/models" | python3 -I -c '
import json, sys
want = sys.argv[1]
for m in json.load(sys.stdin)["data"]:
    if m["id"] == want:
        for s in (m.get("x-flop") or {}).get("price_sources") or []: print(s["miner_address"])' "$MODEL")
  [ -n "$miners" ] || die "no miner quotes $MODEL on the gateway right now"
  for m in $miners; do
    echo "== miner $m"
    if out=$(signed_flop session run --miner "$m" --model "$MODEL" --prompt "$prompt" \
               --max-flop "${FLOP_MAX_FLOP:-2}" --via offer --json 2>&1); then echo "$out"; return 0; fi
    printf '%s\n' "$out" | grep -E '"(code|message)"' || printf '%s\n' "$out" | tail -n 3
  done
  die "no miner had a live signed offer for $MODEL within ${FLOP_MAX_FLOP:-2} FLOP"
}

cmd_mcp() {
  local tool="${1:?usage: mcp <tool> [json-args]}" args="${2:-}" body
  [ -n "$args" ] || args='{}'
  body=$(python3 -I -c 'import json,sys; print(json.dumps({"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":sys.argv[1],"arguments":json.loads(sys.argv[2])}}))' "$tool" "$args" 2>/dev/null) \
    || die "arguments must be a JSON object"
  curl -sS -X POST "$MCP_URL" -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' -d "$body" |
  python3 -I -c '
import json, sys
raw = sys.stdin.read()
lines = [l[6:] for l in raw.splitlines() if l.startswith("data: ")] or [raw]
d = json.loads(lines[-1])
if "error" in d: print(json.dumps(d["error"], indent=1)); sys.exit(1)
r = d.get("result", {})
if r.get("structuredContent") is not None: print(json.dumps(r["structuredContent"], indent=1))
else:
    for c in r.get("content", []): print(c.get("text", ""))
sys.exit(1 if r.get("isError") else 0)'
}

settlements() {  # $1 = JSON args for flop_list_settlements
  cmd_mcp flop_list_settlements "$1" | python3 -I -c '
import json, sys
t = sys.stdin.read()
try: d = json.loads(t)
except ValueError: print(t[:600]); sys.exit()
rows = d.get("data") or []
print("   total:", (d.get("pagination") or {}).get("total", len(rows)))
for s in rows:
    print("   -", s.get("settlementEvent"), "block", s.get("settledBlock"), "| channel", s.get("channelId"))
    print("     agent", s.get("agent"), "| miner", s.get("miner"), "| tier", s.get("assuranceTier"))
    paid = int(s.get("minerPaid") or 0) / 10**18
    print(f"     miner paid {paid:.6f} test FLOP | extrinsic", s.get("extrinsicHash"))'
}

cmd_status() {
  local a="" e=""
  [ -f "$FLOP_HOME/address" ] && a=$(cat "$FLOP_HOME/address")
  echo "== node";    flop health --json || true
  echo "   devnet genesis $GENESIS (faucet requests verify it before sending)"
  if [ -n "$a" ]; then
    echo "== your keystore key $a"; flop balance "$a" --json || true
    echo "   settlements where agent = this key (direct / flop chat runs)"; settlements "{\"agent\":\"$a\",\"limit\":5}" || true
  fi
  e=$(enroll_address || true)
  if [ -n "$e" ]; then
    echo "== CLI enrollment wallet $e (used by agent credential)"; flop balance "$e" --json || true
    echo "   settlements where agent = this wallet"; settlements "{\"agent\":\"$e\",\"limit\":5}" || true
    echo "   note: hosted-gateway runs may settle under a shared gateway account, not under either address"
  fi
  echo "== latest settlement on the network"; settlements '{"limit":1}' || true
  echo "== network"; cmd_mcp flop_get_stats '{}' || true
  echo "== gateway models"
  curl -sS "$GATEWAY/models" | python3 -I -c '
import json, sys
for m in json.load(sys.stdin)["data"]:
    src = (m.get("x-flop") or {}).get("price_sources") or []
    print("  -", m["id"], "| registry", (m.get("x-flop") or {}).get("registry_model"), "| price quotes from", len(src), "miners (not the same as miners online)")'
  echo "== explorer: $EXPLORER"
}

case "${1:-}" in
  init)       cmd_init ;;
  fund)       cmd_fund ;;
  credential) cmd_credential ;;
  ask)        shift; cmd_ask "${1:-}" ;;
  direct)     shift; cmd_direct "${1:-}" ;;
  status)     cmd_status ;;
  mcp)        shift; cmd_mcp "$@" ;;
  all)        shift; cmd_init; cmd_fund; cmd_credential; cmd_ask "${1:-}"; cmd_status ;;
  *)          sed -n '2,14p' "$0"; exit 1 ;;
esac
