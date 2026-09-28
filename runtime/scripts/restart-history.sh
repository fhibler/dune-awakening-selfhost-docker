#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/../.."

HISTORY_FILE="${DUNE_RESTART_HISTORY_FILE:-runtime/generated/restart-history.jsonl}"
LOCK_FILE="${HISTORY_FILE}.lock"

record() {
  [ "$#" -eq 8 ] || { echo "Usage: $0 record <scope> <target> <source> <reason> <result> <started-at> <finished-at> <duration-seconds>" >&2; exit 2; }
  mkdir -p "$(dirname "$HISTORY_FILE")"
  flock "$LOCK_FILE" python3 - "$HISTORY_FILE" "$@" <<'PY'
import json
import os
import sys
from pathlib import Path

path = Path(sys.argv[1])
scope, target, source, reason, result, started_at, finished_at, duration = sys.argv[2:]

def clean(value, limit):
    return str(value).replace("\r", " ").replace("\n", " ").replace("\t", " ")[:limit]

row = {
    "id": f"runtime-{os.getpid()}-{finished_at}",
    "startedAt": clean(started_at, 40),
    "finishedAt": clean(finished_at, 40),
    "durationSeconds": max(0, min(86400, int(duration))),
    "scope": scope if scope in {"battlegroup", "map", "service"} else "service",
    "target": clean(target, 160) or "Unknown",
    "map": "",
    "partitionId": "",
    "source": clean(source, 80) or "Runtime",
    "reason": clean(reason, 160) or "Restart",
    "result": "Succeeded" if result == "Succeeded" else "Failed",
}
with path.open("a", encoding="utf-8") as handle:
    handle.write(json.dumps(row, separators=(",", ":")) + "\n")
os.chmod(path, 0o600)
if path.stat().st_size > 2 * 1024 * 1024:
    lines = path.read_text(encoding="utf-8").splitlines()[-500:]
    temp = path.with_suffix(path.suffix + ".tmp")
    temp.write_text("\n".join(lines) + ("\n" if lines else ""), encoding="utf-8")
    os.chmod(temp, 0o600)
    temp.replace(path)
PY
}

case "${1:-}" in
  record)
    shift
    record "$@"
    ;;
  *)
    echo "Usage: $0 record <scope> <target> <source> <reason> <result> <started-at> <finished-at> <duration-seconds>" >&2
    exit 2
    ;;
esac
