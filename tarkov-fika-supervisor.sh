#!/usr/bin/env bash
set -euo pipefail

enable_headless="false"
headless_executable="Fika.Dedicated"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --enable-headless)
      enable_headless="${2:-false}"; shift 2 ;;
    --headless-executable)
      headless_executable="${2:-Fika.Dedicated}"; shift 2 ;;
    *)
      shift 1 ;;
  esac
done

root_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$root_dir"

server_dir="$root_dir/server/SPT"
server_exe="$server_dir/SPT.Server.Linux"

headless_dir="$root_dir/headless"
headless_exe="$headless_dir/$headless_executable"

server_fifo="$root_dir/.server.stdin"
headless_fifo="$root_dir/.headless.stdin"

server_pid=""
headless_pid=""

cleanup() {
  if type stop_headless >/dev/null 2>&1; then
    stop_headless >/dev/null 2>&1 || true
  fi
  rm -f "$server_fifo" "$headless_fifo" 2>/dev/null || true
}
trap cleanup EXIT

[[ -p "$server_fifo" ]] || mkfifo "$server_fifo"

if [[ ! -x "$server_exe" ]]; then
  echo "[SUPERVISOR] Missing server executable: $server_exe" >&2
  exit 1
fi

echo "[SUPERVISOR] Starting server..."
(
  cd "$server_dir"
  "$server_exe" <"$server_fifo"
) &
server_pid=$!

start_headless() {
  case "${enable_headless,,}" in
    1|true|yes|y|on) ;;
    *) echo "[SUPERVISOR] Headless disabled (EnableHeadless=false)."; return 0 ;;
  esac

  if [[ -n "$headless_pid" ]] && kill -0 "$headless_pid" 2>/dev/null; then
    echo "[SUPERVISOR] Headless already running."
    return 0
  fi

  [[ -p "$headless_fifo" ]] || mkfifo "$headless_fifo"

  if [[ ! -f "$headless_exe" ]]; then
    echo "[SUPERVISOR] Missing headless executable: $headless_exe" >&2
    return 0
  fi

  echo "[SUPERVISOR] Starting headless..."
  (
    cd "$headless_dir"
    "$headless_exe" <"$headless_fifo"
  ) &
  headless_pid=$!
}

stop_headless() {
  if [[ -z "$headless_pid" ]] || ! kill -0 "$headless_pid" 2>/dev/null; then
    echo "[SUPERVISOR] Headless not running."
    return 0
  fi
  echo "[SUPERVISOR] Stopping headless..."
  echo "exit" >"$headless_fifo" 2>/dev/null || true
  sleep 2 || true
  kill "$headless_pid" 2>/dev/null || true
  headless_pid=""
}

restart_headless() {
  stop_headless
  start_headless
}

start_headless || true

echo "[SUPERVISOR] Ready. Commands: headless start|stop|restart (forwarded server commands otherwise)."

while IFS= read -r line; do
  if [[ -n "$server_pid" ]] && ! kill -0 "$server_pid" 2>/dev/null; then
    echo "[SUPERVISOR] Server exited. Shutting down."
    break
  fi

  cmd="$(echo "$line" | awk '{$1=$1;print}')"
  case "$cmd" in
    "") continue ;;
    "headless start") start_headless ;;
    "headless stop") stop_headless ;;
    "headless restart") restart_headless ;;
    "exit")
      echo "exit" >"$server_fifo" 2>/dev/null || true
      break
      ;;
    *)
      echo "$line" >"$server_fifo" 2>/dev/null || true
      ;;
  esac
done
