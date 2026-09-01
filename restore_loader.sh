#!/bin/sh
# Watchdog restore for hermes-claude-auth — re-applies the bypass if a
# `hermes update` venv rebuild wiped the `.pth`/bootstrap hook from
# site-packages. The post-merge git hook covers the merge step, but a venv
# rebuild that happens after the merge isn't caught by git hooks; this cron
# watchdog closes that gap. Intended to run via Hermes cron (every 15m):
#
#   hermes cron create "every 15m" --name restore-claude-auth-loader \
#     --no-agent --script restore_loader.sh --deliver local
#
# Idempotent and lightweight: exits immediately when the hook is already intact.
#
# Output contract (matches Hermes `--no-agent` cron semantics): stdout is
# delivered to the user verbatim, so the healthy path prints NOTHING to stdout
# (silent tick). A restore or failure prints one line to stdout so it surfaces
# as an alert; a failure also exits non-zero.

set -u

# Resolve the Hermes data ROOT (patches live there). HERMES_HOME may point at a
# profile dir (.../hermes/profiles/<name>); walk up to the root in that case.
if [ -n "${HERMES_HOME:-}" ]; then
  HERMES_ROOT="$HERMES_HOME"
  case "$(basename "$(dirname "$HERMES_HOME")")" in
    profiles) HERMES_ROOT="$(dirname "$(dirname "$HERMES_HOME")")" ;;
  esac
elif [ -n "${LOCALAPPDATA:-}" ]; then
  HERMES_ROOT="$LOCALAPPDATA/hermes"
else
  HERMES_ROOT="$HOME/.hermes"
fi

INSTALL="$HERMES_ROOT/patches/hermes-claude-auth/install.sh"
if [ ! -x "$INSTALL" ]; then
  echo "[restore_loader] installer not found at $INSTALL — cannot restore hermes-claude-auth"
  exit 1
fi

# Fast presence check across every plausible venv under hermes-agent.
AGENT_DIR="$HERMES_ROOT/hermes-agent"
HOOK_PRESENT=0
for base in "$AGENT_DIR/venv" "$AGENT_DIR/.venv"; do
  [ -d "$base" ] || continue
  pth="$(find "$base" -maxdepth 5 -name 'hermes_claude_auth.pth' -print -quit 2>/dev/null)"
  boot="$(find "$base" -maxdepth 5 -name '_hermes_claude_auth_bootstrap.py' -print -quit 2>/dev/null)"
  if [ -n "$pth" ] && [ -n "$boot" ] \
     && grep -q "import _hermes_claude_auth_bootstrap" "$pth" 2>/dev/null \
     && grep -q "hermes-claude-auth managed" "$boot" 2>/dev/null; then
    HOOK_PRESENT=1
    break
  fi
done

if [ "$HOOK_PRESENT" -eq 1 ]; then
  # Healthy — stay silent on stdout so the cron tick delivers nothing.
  exit 0
fi

LOG="${TMPDIR:-/tmp}/hermes_claude_auth_restore.log"
if HERMES_HOME="$HERMES_ROOT" "$INSTALL" --post-update >"$LOG" 2>&1; then
  echo "[restore_loader] Restored hermes-claude-auth loader (.pth/bootstrap hook was missing — likely after hermes update)."
  exit 0
else
  echo "[restore_loader] Reinstall FAILED — see $LOG"
  exit 1
fi
