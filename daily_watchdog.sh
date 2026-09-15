#!/usr/bin/env bash
# Daily watchdog for hermes-claude-auth (Hermes --no-agent cron, e.g. midnight).
#
# Does three things, in order, and prints ONLY when there is something to say
# (Hermes delivers stdout verbatim; empty stdout = silent tick):
#
#   1. UPDATE   git pull --ff-only the clone from origin. If the bypass
#               module changed, re-run install.sh --post-update so the deployed
#               copy matches. Also fetches `upstream` (if configured) and
#               reports when it has commits the clone doesn't (report only —
#               never auto-merges over local fixes).
#   2. RESTORE  delegate to restore_loader.sh (re-applies the .pth/bootstrap
#               hook if a venv rebuild wiped it).
#   3. CLI      keep the Claude Code CLI current, and migrate a host whose CLI
#               is not writable by the current user to the native per-user
#               install (any Linux/macOS host, no root required).
#   4. CREDS    keep THIS host's credential alive over the browser-free refresh
#               path. Linux refreshes (it owns the credential file); macOS only
#               verifies, because Claude Code owns the Keychain there. Silent
#               unless a human is needed. Never copies credentials between
#               hosts or between stores, and never mints credentials from
#               scratch — a first login / dead refresh token is a human step:
#               `claude auth login --claudeai` (no GUI needed on the server).
#   5. MODELS   fetch Anthropic's models overview, diff the "Claude API ID"
#               row against the last-seen set. For every NEW model ID:
#               smoke-test it through the bypass, and on success register
#               Hermes aliases (`<id minus claude- and date>` plus the family
#               short name opus/sonnet/haiku/fable pointing at the newest).
#               model.default is never changed.
#
# State (outside the repo): $HERMES_ROOT/patches/.claude_models_known
# Env:  HERMES_HOME, HERMES_BIN (path to hermes CLI),
#       CLAUDE_AUTH_UPDATE_FAMILY_ALIAS=0 to stop moving opus/sonnet/... aliases.
#
# Any step failure prints a line and the script exits non-zero at the end so
# the scheduler raises an error alert; earlier steps still run.

set -u

# ── resolve paths ──────────────────────────────────────────────────────
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
CLONE="$HERMES_ROOT/patches/hermes-claude-auth"
STATE="$HERMES_ROOT/patches/.claude_models_known"
MODELS_URL="${CLAUDE_MODELS_URL:-https://platform.claude.com/docs/en/models/overview.md}"
LOGDIR="${TMPDIR:-/tmp}"

HERMES_BIN="${HERMES_BIN:-}"
if [ -z "$HERMES_BIN" ]; then
  for cand in "$(command -v hermes 2>/dev/null || true)" "$HOME/.local/bin/hermes" "$HERMES_ROOT/hermes-agent/venv/bin/hermes"; do
    [ -n "$cand" ] && [ -x "$cand" ] && HERMES_BIN="$cand" && break
  done
fi

RC=0
say() { printf '%s\n' "$*"; }

# ── 1. UPDATE ──────────────────────────────────────────────────────────
if [ -d "$CLONE/.git" ]; then
  before="$(git -C "$CLONE" rev-parse HEAD 2>/dev/null)"
  if git -C "$CLONE" fetch -q origin 2>>"$LOGDIR/hermes_claude_auth_daily.log"; then
    if git -C "$CLONE" pull -q --ff-only origin main >>"$LOGDIR/hermes_claude_auth_daily.log" 2>&1; then
      after="$(git -C "$CLONE" rev-parse HEAD 2>/dev/null)"
      if [ "$before" != "$after" ]; then
        # Routine clone moves are logged, not announced: every host pulls, so
        # announcing on each would double every message. Only substantive
        # events (a redeploy, or a failure) reach stdout.
        printf '%s [claude-auth] clone %s → %s (origin/main)\n' \
          "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "${before:0:7}" "${after:0:7}" \
          >>"$LOGDIR/hermes_claude_auth_daily.log" 2>/dev/null || true
        if ! git -C "$CLONE" diff --quiet "$before" "$after" -- anthropic_billing_bypass.py _hermes_claude_auth_bootstrap.py hermes_claude_auth.pth; then
          if HERMES_HOME="$HERMES_ROOT" "$CLONE/install.sh" --post-update >"$LOGDIR/hermes_claude_auth_daily_install.log" 2>&1; then
            say "[claude-auth] Bypass module changed — redeployed via install.sh --post-update."
          else
            say "[claude-auth] Bypass module changed but redeploy FAILED — see $LOGDIR/hermes_claude_auth_daily_install.log"; RC=1
          fi
        fi
      fi
    else
      say "[claude-auth] git pull --ff-only FAILED (local changes or diverged history) — clone left untouched. See $LOGDIR/hermes_claude_auth_daily.log"; RC=1
    fi
  else
    say "[claude-auth] git fetch origin FAILED (offline?) — skipping update."; RC=1
  fi
  if git -C "$CLONE" remote get-url upstream >/dev/null 2>&1 \
     && git -C "$CLONE" fetch -q upstream 2>/dev/null; then
    ahead="$(git -C "$CLONE" rev-list --count HEAD..upstream/main 2>/dev/null || echo 0)"
    if [ "${ahead:-0}" -gt 0 ]; then
      say "[claude-auth] Upstream (kristianvast) has $ahead new commit(s) not in the fork — review and merge manually: git -C $CLONE log HEAD..upstream/main --oneline"
    fi
  fi
else
  say "[claude-auth] clone not found at $CLONE — cannot update or restore."; RC=1
fi

# ── 2. RESTORE ─────────────────────────────────────────────────────────
if [ -f "$CLONE/restore_loader.sh" ]; then
  out="$(HERMES_HOME="$HERMES_ROOT" sh "$CLONE/restore_loader.sh")" || RC=1
  [ -n "$out" ] && say "$out"
fi

# ── 2b. CLAUDE CODE CLI ────────────────────────────────────────────────
# Anthropic rejects requests claiming a Claude Code version below a moving
# minimum ("version X or newer is required"). The bypass reads the installed
# `claude` version, so keeping the CLI current keeps the fingerprint valid.
#
# Install layout decides updateability, so a host whose `claude` is not
# writable by the current user is migrated to the native per-user install
# (~/.local/share/claude, self-updating via `claude update`) rather than
# failing every night. That keeps this one script correct on any Linux/macOS
# host with no per-host forks.
cc_version_of() { "$1" --version 2>/dev/null | awk '{print $1}'; }

install_native_claude() {
  # $1 = reason, for the message on failure
  if ! command -v curl >/dev/null 2>&1; then
    say "[claude-auth] $1 and curl is unavailable — cannot install the native Claude Code CLI."; RC=1; return 1
  fi
  if curl -fsSL --max-time 120 https://claude.ai/install.sh 2>/dev/null \
       | bash >"$LOGDIR/hermes_claude_code_install.log" 2>&1; then
    hash -r 2>/dev/null || true
    return 0
  fi
  say "[claude-auth] $1 and the native install FAILED — see $LOGDIR/hermes_claude_code_install.log"; RC=1
  return 1
}

CLAUDE_BIN="$(command -v claude 2>/dev/null || true)"
if [ -z "$CLAUDE_BIN" ]; then
  if install_native_claude "Claude Code CLI is not installed"; then
    new_bin="$(command -v claude 2>/dev/null || true)"
    [ -n "$new_bin" ] \
      && say "[claude-auth] Installed the native Claude Code CLI ($(cc_version_of "$new_bin")) at $new_bin."
  fi
else
  cur="$(cc_version_of "$CLAUDE_BIN")"
  latest="$(npm view @anthropic-ai/claude-code version 2>/dev/null || true)"
  if [ -n "$latest" ] && [ "$cur" != "$latest" ]; then
    if [ -L "$CLAUDE_BIN" ] && readlink "$CLAUDE_BIN" | grep -q "/.local/share/claude/"; then
      # Native install: `claude update` needs no root on any platform.
      if claude update >"$LOGDIR/hermes_claude_code_update.log" 2>&1; then
        say "[claude-auth] Claude Code CLI updated $cur → $(cc_version_of "$CLAUDE_BIN") via 'claude update'."
      else
        say "[claude-auth] Claude Code CLI update ('claude update') FAILED — see $LOGDIR/hermes_claude_code_update.log"; RC=1
      fi
    else
      npm_prefix="$(npm config get prefix 2>/dev/null || true)"
      if command -v npm >/dev/null 2>&1 && [ -n "$npm_prefix" ] && [ -w "$npm_prefix/lib/node_modules" ]; then
        if npm install -g "@anthropic-ai/claude-code@$latest" >"$LOGDIR/hermes_claude_code_update.log" 2>&1; then
          say "[claude-auth] Claude Code CLI updated $cur → $latest via 'npm install -g'."
        else
          say "[claude-auth] Claude Code CLI update (npm install -g) FAILED — see $LOGDIR/hermes_claude_code_update.log"; RC=1
        fi
      else
        # e.g. a root-owned /usr/lib/node_modules install: npm cannot fix this
        # without root, so migrate to the native per-user install instead.
        if install_native_claude "Claude Code CLI at $CLAUDE_BIN is not writable by $(id -un)"; then
          new_bin="$(command -v claude 2>/dev/null || true)"
          if [ -n "$new_bin" ] && [ "$new_bin" != "$CLAUDE_BIN" ]; then
            say "[claude-auth] Migrated Claude Code CLI to the native install: $(cc_version_of "$new_bin") at $new_bin (was $cur at $CLAUDE_BIN)."
          else
            say "[claude-auth] Installed the native Claude Code CLI, but 'claude' still resolves to $CLAUDE_BIN ($cur). Put \$HOME/.local/bin ahead of it in PATH, or remove that copy."; RC=1
          fi
        fi
      fi
    fi
  fi
fi

# ── 2c. CREDENTIAL HEALTH ──────────────────────────────────────────────
# Keep THIS host's Claude credential alive, on its own, with no browser and no
# copying between hosts or stores. Refresh tokens are single-use and rotate, so
# exactly one refresher per host may exist: credential_health.py refreshes on
# hosts that own their credential file (Linux) and only verifies on macOS,
# where Claude Code owns the Keychain. It is silent unless a human is needed.
CRED_HELPER="$CLONE/credential_health.py"
if [ -f "$CRED_HELPER" ]; then
  VENV_PY=""
  for cand in "$HERMES_ROOT/hermes-agent/venv/bin/python" "$HERMES_ROOT/hermes-agent/.venv/bin/python"; do
    [ -x "$cand" ] && VENV_PY="$cand" && break
  done
  if [ -n "$VENV_PY" ]; then
    case "$(uname -s)" in
      Darwin) CRED_MODE="verify" ;;
      *)      CRED_MODE="refresh" ;;
    esac
    # Capture stdout ONLY: the .pth/bootstrap pair writes progress lines to
    # stderr on every interpreter start, and merging it in would deliver that
    # noise as a cron message every night.
    if cred_out="$("$VENV_PY" "$CRED_HELPER" --mode "$CRED_MODE" \
                      --history "$HERMES_ROOT/patches/.claude_cred_history" \
                      2>"$LOGDIR/hermes_claude_cred.log")"; then
      [ -n "$cred_out" ] && say "$cred_out"
    else
      [ -n "$cred_out" ] && say "$cred_out"
      say "[claude-auth] credential check failed — see $LOGDIR/hermes_claude_cred.log"
      RC=1
    fi
  else
    say "[claude-auth] credentials: hermes venv python not found — credential check skipped."; RC=1
  fi
fi

# ── 3. MODELS ──────────────────────────────────────────────────────────
page="$(curl -fsSL --max-time 30 "$MODELS_URL" 2>/dev/null)" || page=""
if [ -z "$page" ]; then
  say "[claude-auth] Could not fetch $MODELS_URL — model check skipped."; RC=1
else
  current="$(printf '%s\n' "$page" | grep -E '^\| *Claude API ID' | grep -oE '`claude-[a-z0-9-]+`' | tr -d '`' | sort -u)"
  if [ -z "$current" ]; then
    say "[claude-auth] Models page fetched but the 'Claude API ID' row was not found — page layout changed? Check $MODELS_URL"; RC=1
  elif [ ! -f "$STATE" ]; then
    printf '%s\n' "$current" > "$STATE"
    say "[claude-auth] Model baseline established ($(printf '%s\n' "$current" | wc -l | tr -d ' ') IDs): $(printf '%s' "$current" | tr '\n' ' ')"
  else
    new="$(comm -13 <(sort -u "$STATE") <(printf '%s\n' "$current"))"
    if [ -n "$new" ]; then
      for id in $new; do
        short="${id#claude-}"; short="$(printf '%s' "$short" | sed -E 's/-[0-9]{8}$//')"
        family="${short%%-*}"
        if [ -z "$HERMES_BIN" ]; then
          say "[claude-auth] NEW MODEL $id — hermes CLI not found, cannot register alias."; RC=1; continue
        fi
        resp="$("$HERMES_BIN" chat -q 'Reply with exactly: OK' -Q --provider anthropic -m "$id" 2>&1 | tail -n 1)"
        if [ "$resp" = "OK" ]; then
          "$HERMES_BIN" config set "model.aliases.$short" "anthropic/$id" >/dev/null 2>&1 \
            && msg="alias '$short'" || { msg="alias '$short' FAILED to save"; RC=1; }
          if [ "${CLAUDE_AUTH_UPDATE_FAMILY_ALIAS:-1}" = "1" ] && [ -n "$family" ] && [ "$family" != "$short" ]; then
            "$HERMES_BIN" config set "model.aliases.$family" "anthropic/$id" >/dev/null 2>&1 \
              && msg="$msg, '$family' → $id" || { msg="$msg ('$family' FAILED to save)"; RC=1; }
          fi
          say "[claude-auth] NEW MODEL $id — works on your subscription ✓ Registered $msg. Use: /model $short"
        else
          say "[claude-auth] NEW MODEL $id — smoke test FAILED (not on your plan yet?): ${resp:-<no output>}. No alias added."; RC=1
        fi
      done
    fi
    # Always refresh the known set (also records removals silently).
    printf '%s\n' "$current" > "$STATE"
  fi
fi

exit $RC
