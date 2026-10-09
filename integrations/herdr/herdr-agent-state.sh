#!/bin/sh
# herdr-agent-state.sh — report NeoAI agent lifecycle state to Herdr.
#
# NeoAI's Neovim plugin already reports lifecycle state itself
# (see lua/NeoAI/services/herder.lua). This standalone script mirrors the
# same protocol so non-Neovim contexts (launchers, wrappers, CI shims, other
# editors) can drive the same Herdr pane lifecycle authority over the
# `herdr pane` CLI.
#
# Usage:
#   herdr-agent-state.sh --state working|idle|blocked|unknown \
#       [--agent neoai] [--source custom:neoai] [--display-agent NeoAI] \
#       [--seq N] [--message TEXT]
#   herdr-agent-state.sh --release
#
# Outside a Herdr-managed pane (HERDR_ENV != 1) this is a no-op (exit 0).
# Requires HERDR_PANE_ID and a herdr binary (HERDER_BIN_PATH / HERDR_BIN_PATH,
# else `herdr` on PATH).

set -u

[ "${HERDR_ENV:-}" = "1" ] || exit 0
[ -n "${HERDR_PANE_ID:-}" ] || exit 0

BIN="${HERDER_BIN_PATH:-${HERDR_BIN_PATH:-herdr}}"
command -v "$BIN" >/dev/null 2>&1 || exit 0

AGENT="neoai"
SOURCE="custom:neoai"
STATE=""
SEQ=""
MESSAGE=""
DISPLAY_AGENT=""
RELEASE=0

while [ $# -gt 0 ]; do
  case "$1" in
    --state)         STATE="${2:-}"; shift 2 ;;
    --agent)         AGENT="${2:-}"; shift 2 ;;
    --source)        SOURCE="${2:-}"; shift 2 ;;
    --seq)           SEQ="${2:-}"; shift 2 ;;
    --message)       MESSAGE="${2:-}"; shift 2 ;;
    --display-agent) DISPLAY_AGENT="${2:-}"; shift 2 ;;
    --release)       RELEASE=1; shift ;;
    -h|--help)
      sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *) shift ;;
  esac
done

if [ "$RELEASE" = "1" ]; then
  set -- pane release-agent "$HERDR_PANE_ID" --source "$SOURCE" --agent "$AGENT"
  [ -n "$SEQ" ] && set -- "$@" --seq "$SEQ"
  "$BIN" "$@" >/dev/null 2>&1 || true
  exit 0
fi

case "$STATE" in
  working|idle|blocked|unknown) : ;;
  *) echo "herdr-agent-state: invalid --state '${STATE}' (expect working|idle|blocked|unknown)" >&2; exit 2 ;;
esac

set -- pane report-agent "$HERDR_PANE_ID" --source "$SOURCE" --agent "$AGENT" --state "$STATE"
[ -n "$SEQ" ] && set -- "$@" --seq "$SEQ"
[ -n "$MESSAGE" ] && set -- "$@" --message "$MESSAGE"
"$BIN" "$@" >/dev/null 2>&1 || true

# Optional display metadata: let Herdr's sidebar show "NeoAI" plus localized
# state labels instead of the bare agent id.
if [ -n "$DISPLAY_AGENT" ]; then
  set -- pane report-metadata "$HERDR_PANE_ID" --source "$SOURCE" --agent "$AGENT" \
    --display-agent "$DISPLAY_AGENT" \
    --state-label working=生成中 --state-label blocked=等待确认 --state-label idle=就绪
  [ -n "$SEQ" ] && set -- "$@" --seq "$SEQ"
  "$BIN" "$@" >/dev/null 2>&1 || true
fi

exit 0
