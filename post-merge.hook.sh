#!/bin/sh
# post-merge hook for the hermes-claude-auth repo itself.
#
# If you clone THIS repo and use it as the source of truth for your
# hermes-claude-auth install, this hook re-installs the loader into the
# hermes-agent venv after every `git pull` of the auth repo.
#
# It is the companion to the hermes-agent repo's own post-merge hook
# (which restores the loader after `hermes update`). Together they keep
# the loader alive across updates of BOTH repos.
#
# Idempotent and never fatal.

set -u

REPO_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$REPO_DIR/sitecustomize_hook.py"

if [ ! -f "$SRC" ]; then
  echo "[post-merge] sitecustomize_hook.py not found in $REPO_DIR — skipping" >&2
  exit 0
fi

# Resolve hermes-agent venv
if [ -n "${HERMES_HOME:-}" ]; then
  case "$(basename "$(dirname "$HERMES_HOME")")" in
    profiles) HM="$HERMES_HOME/../.." ;;
    *) HM="$HERMES_HOME" ;;
  esac
elif [ -n "${LOCALAPPDATA:-}" ]; then
  HM="$LOCALAPPDATA/hermes"
else
  HM="$HOME/.hermes"
fi

AGENT_DIR="$HM/hermes-agent"
VENV=""
for c in "$AGENT_DIR/venv" "$AGENT_DIR/.venv"; do
  [ -d "$c" ] && VENV="$c" && break
done

[ -z "$VENV" ] && { echo "[post-merge] hermes-agent venv not found — skipping" >&2; exit 0; }

DEST="$VENV/Lib/site-packages/sitecustomize.py"

if [ -f "$DEST" ] && ! grep -q "hermes-claude-auth managed" "$DEST" 2>/dev/null; then
  echo "[post-merge] $DEST is not the claude-auth loader — refusing" >&2
  exit 0
fi

cp -f "$SRC" "$DEST" 2>/dev/null \
  && echo "[post-merge] hermes-claude-auth loader reinstalled to $DEST" >&2 \
  || echo "[post-merge] copy failed — ignored" >&2
exit 0
