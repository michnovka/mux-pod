#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"
STATE_ROOT="${TMPDIR:-/tmp}/muxpod-terminal-debug"
CAPTURE_ROOT="${REPO_DIR}/build/terminal-captures"

usage() {
  cat <<'EOF'
Usage:
  scripts/terminal_debug_capture.sh start --pane %11 [--max-bytes 8388608]
  scripts/terminal_debug_capture.sh stop --pane %11
  scripts/terminal_debug_capture.sh snapshot --pane %11 [--device emulator-5554]

What it does:
  - start: enables a rolling raw byte capture for a tmux pane via pipe-pane
  - stop:  disables that rolling capture
  - snapshot: saves a timestamped bundle with:
      * adb screenshot
      * tmux pane metadata
      * visible pane capture (plain + ANSI)
      * recent scrollback tail (plain + ANSI)
      * session tree
      * filtered logcat
      * raw byte tail from the rolling pipe-pane capture, if running

Notes:
  - Use the exact tmux pane target, for example %11 or appex:2.0
  - snapshot is safe to run repeatedly while the pane is broken
EOF
}

die() {
  echo "error: $*" >&2
  exit 1
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "missing required command: $1"
}

shell_quote() {
  printf "'%s'" "${1//\'/\'\"\'\"\'}"
}

sanitize_name() {
  local value="$1"
  value="${value//\//_}"
  value="${value//:/_}"
  value="${value//%/pane_}"
  value="${value// /_}"
  printf '%s\n' "$value"
}

STATE_DIR=""
PANE_TARGET=""
ADB_DEVICE=""
MAX_BYTES=$((8 * 1024 * 1024))

parse_args() {
  [[ $# -ge 1 ]] || { usage; exit 1; }
  ACTION="$1"
  shift

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --pane)
        [[ $# -ge 2 ]] || die "--pane requires a value"
        PANE_TARGET="$2"
        shift 2
        ;;
      --device)
        [[ $# -ge 2 ]] || die "--device requires a value"
        ADB_DEVICE="$2"
        shift 2
        ;;
      --max-bytes)
        [[ $# -ge 2 ]] || die "--max-bytes requires a value"
        MAX_BYTES="$2"
        shift 2
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "unknown argument: $1"
        ;;
    esac
  done

  [[ -n "$PANE_TARGET" ]] || die "--pane is required"
  STATE_DIR="${STATE_ROOT}/$(sanitize_name "$PANE_TARGET")"
}

adb_cmd() {
  if [[ -n "$ADB_DEVICE" ]]; then
    adb -s "$ADB_DEVICE" "$@"
  else
    adb "$@"
  fi
}

start_capture() {
  mkdir -p "$STATE_DIR"
  local raw_path="${STATE_DIR}/raw.bin"
  local command
  command="python3 $(shell_quote "${REPO_DIR}/scripts/tmux_ring_buffer.py") $(shell_quote "$raw_path") --max-bytes $(printf '%q' "$MAX_BYTES")"

  tmux pipe-pane -o -t "$PANE_TARGET" "$command"

  {
    printf 'pane=%s\n' "$PANE_TARGET"
    printf 'started_at=%s\n' "$(date --iso-8601=seconds)"
    printf 'raw_path=%s\n' "$raw_path"
    printf 'max_bytes=%s\n' "$MAX_BYTES"
  } > "${STATE_DIR}/state.env"

  echo "started rolling capture for ${PANE_TARGET}"
  echo "state: ${STATE_DIR}"
}

stop_capture() {
  tmux pipe-pane -t "$PANE_TARGET"
  echo "stopped rolling capture for ${PANE_TARGET}"
}

snapshot_capture() {
  require_cmd tmux
  require_cmd python3
  require_cmd adb

  mkdir -p "$CAPTURE_ROOT"

  local timestamp
  timestamp="$(date +%Y%m%d-%H%M%S)"
  local bundle_dir="${CAPTURE_ROOT}/${timestamp}-$(sanitize_name "$PANE_TARGET")"
  mkdir -p "$bundle_dir"

  {
    printf 'captured_at=%s\n' "$(date --iso-8601=seconds)"
    printf 'repo=%s\n' "$REPO_DIR"
    printf 'branch=%s\n' "$(git -C "$REPO_DIR" rev-parse --abbrev-ref HEAD)"
    printf 'commit=%s\n' "$(git -C "$REPO_DIR" rev-parse --short HEAD)"
    printf 'pane=%s\n' "$PANE_TARGET"
    printf 'device=%s\n' "${ADB_DEVICE:-default}"
  } > "${bundle_dir}/context.txt"

  tmux display-message -p -t "$PANE_TARGET" \
    'pane=#{pane_id} session=#{session_name} window=#{window_index} pane_index=#{pane_index} size=#{pane_width}x#{pane_height} cursor=#{cursor_x},#{cursor_y} wrap=#{wrap_flag} insert=#{insert_flag} origin=#{origin_flag} alternate=#{alternate_on} mode=#{pane_mode} top=#{scroll_region_upper} bottom=#{scroll_region_lower} title=#{pane_title}' \
    > "${bundle_dir}/tmux-metadata.txt"

  tmux list-panes -a -F '#{session_name}:#{window_index}.#{pane_index} pane_id=#{pane_id} active=#{pane_active} size=#{pane_width}x#{pane_height} cursor=#{cursor_x},#{cursor_y} current=#{pane_current_command} title=#{pane_title}' \
    > "${bundle_dir}/tmux-tree.txt"

  tmux capture-pane -p -N -t "$PANE_TARGET" \
    > "${bundle_dir}/pane-visible-plain.txt"
  tmux capture-pane -p -e -N -t "$PANE_TARGET" \
    > "${bundle_dir}/pane-visible-ansi.txt"
  tmux capture-pane -p -N -t "$PANE_TARGET" -S -120 \
    > "${bundle_dir}/pane-tail-plain.txt"
  tmux capture-pane -p -e -N -t "$PANE_TARGET" -S -120 \
    > "${bundle_dir}/pane-tail-ansi.txt"

  if [[ -f "${STATE_DIR}/raw.bin" ]]; then
    python3 - "$STATE_DIR/raw.bin" "$bundle_dir/raw-tail.bin" "$bundle_dir/raw-tail.txt" <<'PY'
import sys
from pathlib import Path

src = Path(sys.argv[1])
dst_bin = Path(sys.argv[2])
dst_txt = Path(sys.argv[3])

data = src.read_bytes()
tail = data[-262144:]
dst_bin.write_bytes(tail)
dst_txt.write_text(
    tail.decode("utf-8", "replace").replace("\x1b", "<ESC>"),
    encoding="utf-8",
)
PY
  fi

  adb_cmd exec-out screencap -p > "${bundle_dir}/screenshot.png" || true
  adb_cmd logcat -d > "${bundle_dir}/logcat-full.txt" || true
  if [[ -f "${bundle_dir}/logcat-full.txt" ]]; then
    rg 'TerminalLoad|TerminalBackfill|flutter|mux_pod|tmux' \
      "${bundle_dir}/logcat-full.txt" > "${bundle_dir}/logcat-filtered.txt" || true
  fi

  echo "saved snapshot bundle:"
  echo "  ${bundle_dir}"
}

parse_args "$@"

case "$ACTION" in
  start)
    start_capture
    ;;
  stop)
    stop_capture
    ;;
  snapshot)
    snapshot_capture
    ;;
  *)
    usage
    die "unknown action: ${ACTION}"
    ;;
esac
