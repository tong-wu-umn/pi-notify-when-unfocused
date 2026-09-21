#!/usr/bin/env bash
#
# Write N fake registry files so the menu bar can be exercised without N real pi
# sessions: `menubar/dev/fake-sessions.sh 24`.
#
# Rows are marked `simulated` with a short expiry, so the app hides them automatically
# once they go stale and a real session is never shadowed. They are written with the same
# 0600 permissions and v1 shape as the extension.
#
#   ./fake-sessions.sh 6            # six rows, mixed states, 60s expiry
#   ./fake-sessions.sh 24 600       # twenty-four rows, 10 minute expiry
#   ./fake-sessions.sh 0            # clean up
#
set -euo pipefail

COUNT="${1:-6}"
TTL="${2:-60}"
DIR="${PI_MENUBAR_REGISTRY_DIR:-$HOME/.pi/agent/menubar/sessions}"

mkdir -p "$DIR"
chmod 700 "$DIR" 2>/dev/null || true

# Remove rows written by earlier runs of this script.
find "$DIR" -name 'fake-*.json' -delete 2>/dev/null || true

if [ "$COUNT" = "0" ]; then
	echo "removed fake registry rows from $DIR"
	exit 0
fi

STATES=(working working idle blocked working idle)
PROJECTS=(
	"pi-notify-when-unfocused" "mobile_pda" "spend_tracker" "jev-sts2" "ai_stock_trader"
	"medical_billing" "sts1_sim" "test_dsh" "misc" "card_spend"
)
TOOLS=(bash read grep edit write find)

now_ms() { python3 -c 'import time; print(int(time.time()*1000))'; }
NOW="$(now_ms)"
EXPIRES=$((NOW + TTL * 1000))

for i in $(seq 1 "$COUNT"); do
	state="${STATES[$((i % ${#STATES[@]}))]}"
	project="${PROJECTS[$((i % ${#PROJECTS[@]}))]}"
	tool="${TOOLS[$((i % ${#TOOLS[@]}))]}"
	pid=$((90000 + i))
	file="$DIR/fake-$pid.json"

	# Spread ages so sorting and duration labels are visible.
	updated=$((NOW - (i * 7000) % 240000))
	run_started=$((updated - 60000 - i * 15000))
	waiting=$([ "$state" = "blocked" ] && echo $((updated - 45000)) || echo null)
	settled=$([ "$state" = "idle" ] && echo $((updated - 30000)) || echo null)
	ctx=$((20000 + i * 5000))
	window=200000

	STATE="$state" PROJECT="$project" TOOL="$tool" FILE="$file" PID="$pid" \
	UPDATED="$updated" RUN_STARTED="$run_started" WAITING="$waiting" SETTLED="$settled" \
	CTX="$ctx" WINDOW="$window" EXPIRES="$EXPIRES" DIR="$DIR" INDEX="$i" \
	python3 - <<'PY'
import json, os

index = int(os.environ["INDEX"])
state = os.environ["STATE"]
nullable = lambda value: None if value == "null" else int(value)

payload = {
    "v": 1,
    "revision": int(os.environ["UPDATED"]) * 1000 + index,
    "pid": int(os.environ["PID"]),
    "processStartedAt": int(os.environ["UPDATED"]) - 600000,
    "sessionId": f"fake-session-{index}",
    "sessionFile": f"/tmp/fake-project-{index}/session.jsonl",
    "sessionName": None if index % 3 == 0 else f"fake task {index}",
    "cwd": f"/Users/fake/projects/{os.environ['PROJECT']}",
    "project": os.environ["PROJECT"],
    "mode": "tui",
    "state": state,
    "stateLabel": "Approve or reject — Bash command" if state == "blocked" else None,
    "blockedKind": "confirm" if state == "blocked" else None,
    "model": ["deepseek-flash", "gpt-5", "claude-sonnet-4.5", "kimi-k2"][index % 4],
    "provider": "fake",
    "thinking": "high",
    "contextTokens": int(os.environ["CTX"]),
    "contextWindow": int(os.environ["WINDOW"]),
    "turnIndex": index,
    "activeTools": [] if state != "working" else [
        {"id": f"call-{index}", "name": os.environ["TOOL"], "startedAt": int(os.environ["UPDATED"]) - 5000}
    ],
    "lastTool": os.environ["TOOL"],
    "runStartedAt": int(os.environ["RUN_STARTED"]) if state != "idle" else None,
    "waitingSince": nullable(os.environ["WAITING"]),
    "settledAt": nullable(os.environ["SETTLED"]),
    "hasPendingMessages": False,
    "lastUserPrompt": None,
    "terminalBundleId": "com.mitchellh.ghostty",
    "updatedAt": int(os.environ["UPDATED"]),
    "simulated": True,
    "expiresAt": int(os.environ["EXPIRES"]),
}
# No herdr block on purpose: these rows exercise the registry-only path.
with open(os.environ["FILE"], "w") as handle:
    json.dump(payload, handle)
os.chmod(os.environ["FILE"], 0o600)
PY
done

echo "wrote $COUNT fake registry row(s) to $DIR (expiring in ${TTL}s)"
echo "run the app with: make run    (or inspect with: make probe)"
