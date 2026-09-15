#!/usr/bin/env python3
"""Per-host Claude credential health for the daily watchdog.

Exactly ONE process per host may refresh a Claude Code OAuth credential:
refresh tokens are single-use and rotate, so a second refresher races the
first and the loser is invalidated (``invalid_grant``), which strips the
stored credential.  Ownership is therefore decided by *store*, not by hostname:

  Linux   ``~/.claude/.credentials.json`` IS the store  -> this script refreshes.
  macOS   Claude Code owns the Keychain, and refreshes the file on its own
          schedule -> this script only VERIFIES and reports.  Refreshing from
          the file side here would rotate the pair behind Claude Code's back.

This script never copies credentials between stores, never prints token
material, and never mints credentials from scratch (a first login or a dead
refresh token needs ``claude auth login --claudeai`` — that is a human step by
design).

Output contract (matched to the no-agent cron contract — empty stdout is a
silent tick, and a non-zero exit raises a separate scheduler error alert):

  healthy                      -> no stdout, exit 0
  refreshed                    -> no stdout, exit 0 (recorded in the history log)
  needs a human                -> ONE actionable line, exit 0  (delivered once,
                                  deliberately not an exit-1 error alert)
  cannot run (import failure)  -> one line, exit 1

Every run appends both expiry stamps to the history file, so the refresh
window can be measured over time (it is not documented anywhere, and it is the
thing that decides how long a host can stay autonomous).
"""

from __future__ import annotations

import argparse
import datetime
import json
import os
import platform
import socket
import subprocess
import sys


def _hermes_home() -> str:
    return os.environ.get("HERMES_HOME") or os.path.expanduser("~/.hermes")


def _host() -> str:
    try:
        return socket.gethostname().split(".")[0]
    except Exception:
        return "unknown-host"


def _load_adapter():
    """Import Hermes' own credential resolver — the single source of truth."""
    try:
        from agent import anthropic_adapter as adapter

        return adapter
    except Exception as exc:  # pragma: no cover - environment dependent
        raise SystemExit(
            f"[claude-auth] {_host()}: cannot import agent.anthropic_adapter "
            f"({type(exc).__name__}: {exc}) — is this the hermes venv python?"
        )


def _fmt(ms: int) -> str:
    if not ms:
        return "none"
    try:
        return datetime.datetime.fromtimestamp(ms / 1000).strftime("%Y-%m-%d %H:%M")
    except Exception:
        return f"raw:{ms}"


def _stamps(creds) -> tuple[int, int]:
    if not creds:
        return 0, 0
    return int(creds.get("expiresAt") or 0), int(creds.get("refreshTokenExpiresAt") or 0)


def _raw_refresh_expiry() -> int:
    """``refreshTokenExpiresAt`` from the host's raw credential record.

    Hermes' adapter normalises the record down to access/refresh/expiry, so the
    refresh-token clock — the thing that actually decides how long a host can
    stay autonomous — has to be read from the platform's raw store. Read-only;
    the value is never printed, only its date in the append-only history log.
    """
    raw = None
    if platform.system() == "Darwin":
        try:
            proc = subprocess.run(
                ["security", "find-generic-password", "-s", "Claude Code-credentials", "-w"],
                capture_output=True, text=True, timeout=10,
            )
            raw = proc.stdout or None
        except Exception:
            raw = None
    if not raw:
        try:
            with open(os.path.expanduser("~/.claude/.credentials.json"), encoding="utf-8") as fh:
                raw = fh.read()
        except OSError:
            return 0
    try:
        return int((json.loads(raw).get("claudeAiOauth") or {}).get("refreshTokenExpiresAt") or 0)
    except Exception:
        return 0


def _log(path: str, mode: str, result: str, exp: int, rt_exp: int) -> None:
    if not path:
        return
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        stamp = datetime.datetime.now().isoformat(timespec="seconds")
        with open(path, "a", encoding="utf-8") as fh:
            fh.write(
                f"{stamp} host={_host()} mode={mode} result={result} "
                f"access_exp={_fmt(exp)} refresh_exp={_fmt(rt_exp)}\n"
            )
    except OSError:
        pass


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--mode",
        choices=("refresh", "verify"),
        default="verify",
        help="refresh = this host owns the store (Linux); verify = report only (macOS)",
    )
    parser.add_argument("--history", default="", help="append-only stamp history file")
    args = parser.parse_args()

    adapter = _load_adapter()
    creds = adapter.read_claude_code_credentials()
    exp, rt_exp = _stamps(creds)
    if not rt_exp:
        # The adapter drops refreshTokenExpiresAt; read the raw store for it so
        # the history can show whether the refresh window rolls forward.
        rt_exp = _raw_refresh_expiry()
    valid = bool(creds) and adapter.is_claude_code_token_valid(creds)
    has_refresh = bool((creds or {}).get("refreshToken"))
    result = "valid" if valid else "expired"

    if args.mode == "refresh" and not valid and has_refresh:
        # Refresh through Hermes' own resolver so there is exactly one
        # implementation; it rotates the pair and persists it to the file.
        token = None
        private = getattr(adapter, "_resolve_claude_code_token_from_credentials", None)
        try:
            token = private(creds) if callable(private) else adapter.resolve_anthropic_token()
        except Exception:
            token = None
        creds = adapter.read_claude_code_credentials()
        exp, rt_exp = _stamps(creds)
        valid = bool(creds) and adapter.is_claude_code_token_valid(creds)
        result = "refreshed" if valid else "refresh-failed"

    _log(args.history, args.mode, result, exp, rt_exp)

    if valid:
        return 0  # healthy: silent tick

    # A dead refresh token is the one state a human must clear.
    if args.mode == "refresh" and has_refresh and result == "refresh-failed":
        print(
            f"[claude-auth] {_host()}: Claude credential refresh FAILED "
            f"(refresh token rejected?) — run: claude auth login --claudeai"
        )
        return 0

    if not has_refresh:
        print(
            f"[claude-auth] {_host()}: no usable Claude credential "
            f"(access token {_fmt(exp)}, no refresh token) — "
            f"run: claude auth login --claudeai"
        )
        return 0

    # Expired but refreshable. Linux refreshes (handled above), so reaching
    # here in refresh mode means the refresh produced nothing usable.
    if args.mode == "refresh":
        print(
            f"[claude-auth] {_host()}: Claude credential expired {_fmt(exp)} "
            f"and could not be refreshed — run: claude auth login --claudeai"
        )
    # verify mode (macOS): an expired-but-refreshable record is normal and
    # Claude Code/Hermes handle it, so stay silent rather than cry wolf daily.
    return 0


if __name__ == "__main__":
    sys.exit(main())