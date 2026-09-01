#!/bin/sh
# post-checkout hook — restore the hermes-claude-auth bypass after a branch
# switch that rebuilds the venv (e.g. `hermes update` on a branch change).
#
# Re-run the installer's idempotent `--post-update` path. Idempotent and never
# fatal: any failure is logged to stderr and ignored so it can never break the
# checkout itself.
#
# HERMES-CLAUDE-AUTH-HOOK  (marker line — install.sh --check greps for it)

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
  echo "[post-checkout] hermes-claude-auth installer not found at $INSTALL — skipping" >&2
  exit 0
fi

HERMES_HOME="$HERMES_ROOT" "$INSTALL" --post-update >&2 || true
exit 0
