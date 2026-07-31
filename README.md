# hermes-claude-auth
Claude Code OAuth bypass for hermes-agent, use your Claude Code subscription (Max/Pro) with Hermes.

## What this does
Patches hermes-agent at runtime to pass Anthropic's server-side OAuth content validation. It does not modify hermes-agent source files. Installation happens through a Python import hook that monkey-patches `build_anthropic_kwargs` on startup.

## Why this exists
On 2026-04-04, Anthropic added server-side validation that rejects OAuth requests from third-party tools. This patch adds the billing header signature and system prompt structure the API expects.

## Prerequisites
- hermes-agent installed (`~/.hermes/hermes-agent/`)
- Claude Code CLI authenticated (valid credentials at `~/.claude/.credentials.json`)
- hermes-agent configured for OAuth (`credential_pool` has a `claude_code` entry in `~/.hermes/auth.json`)
- Python 3.11+

## Install
```bash
curl -fsSL https://raw.githubusercontent.com/kristianvast/hermes-claude-auth/main/install-remote.sh | bash
```

Or clone manually:
```bash
git clone https://github.com/kristianvast/hermes-claude-auth.git
cd hermes-claude-auth
./install.sh
```

What `install.sh` does:
- Copies `anthropic_billing_bypass.py` to `~/.hermes/patches/`
- Installs the import hook as `sitecustomize.py` in the hermes venv's site-packages
- Restarts `hermes-gateway.service` if running

## Uninstall
```bash
./uninstall.sh          # remove hook only
./uninstall.sh --purge  # remove hook + patch file
```

## Surviving `hermes update` (auto-recovery)

`hermes update` runs `git merge --ff-only` + `uv pip install`, which can
wipe the loader from the venv's `site-packages/`. To restore it automatically
after every update, install the bundled `post-merge` hook into **the
hermes-agent repo** (not this one):

```bash
# From inside your hermes-agent checkout:
cp /path/to/hermes-claude-auth/post-merge.hook.sh .git/hooks/post-merge
chmod +x .git/hooks/post-merge
```

The hook copies `sitecustomize_hook.py` (kept as the canonical loader at
`$HERMES_HOME/patches/sitecustomize.py`) back into the venv after each pull.
It is idempotent and never breaks the update — if anything is off, it logs to
stderr and returns 0.

For a full two-way setup (so pulling *this* repo also re-installs), copy the
same file into this repo's `.git/hooks/post-merge` as well.

> **Note:** Windows users — the hook is a POSIX shell script. It runs under
> Git Bash (which ships with Git for Windows) and is invoked by git's own
> hook runner, so no extra setup is needed.


1. **Billing header**: SHA-256 signed `x-anthropic-billing-header` injected as `system[0]`
2. **System prompt relocation**: Non-identity system entries moved to the first user message as `<system-reminder>` blocks
3. **Beta flags**: Adds `prompt-caching-scope-2026-01-05` and `advisor-tool-2026-03-01`
4. **Stainless SDK spoof**: Lowercase `x-stainless-*` headers + `anthropic-dangerous-direct-browser-access` + `?beta=true` query param matching real Claude Code 2.1.112
5. **Tool name namespacing**: Hermes's `mcp_bash` is rewritten to `mcp__hermes__Bash` outbound; the response normalizer unwraps it back to `bash` so hermes's tool dispatcher resolves the registered name without auto-repair noise
6. **Tool pair repair**: Orphaned `tool_use` / `tool_result` blocks (left by long conversations or partial summaries) are stripped before signing — prevents HTTP 400 (upstream PR #136)
7. **Haiku effort stripping**: `effort` parameter is removed for haiku models that reject it with HTTP 400 (upstream PR #126)
8. **Temperature fix**: Strips non-default `temperature` on Opus 4.6 adaptive thinking, which otherwise rejects with HTTP 400
9. **Account metadata**: Maps `~/.claude.json::oauthAccount.accountUuid` to `metadata.user_id` (Anthropic rejected the older `account_uuid` key with HTTP 400 on 2026-04-29)

Installed through a `sitecustomize.py` MetaPathFinder hook, so it runs at interpreter startup with no source modifications.

## Subscription rate-limit auto-wait (Claude Pro/Max windows: 5h, 1d, 7d)

When a long agent run exhausts a Claude Pro/Max usage window mid-flight,
api.anthropic.com returns HTTP 429 with a reset time in the
`anthropic-ratelimit-unified-*-reset` headers.  Hermes core's retry loop
caps backoff at 120s and abandons the run, surfacing "rate-limiting
requests" on Telegram and killing the session.

This patch wraps the two API-call entry points on `run_agent.AIAgent` so a
genuine subscription-window 429 instead **sleeps until the window resets**
(interruptibly, in short chunks) and then retries the same call transparently.
It picks the **longest** throttled window (e.g. a 7d hit also clears the 5h
window, so a single sleep covers both) and applies a **per-window** safety
cap (5h=6h, 1d=26h, 7d=7.5d). Behaviour is tunable via env vars:

| Env var | Default | Meaning |
|---------|---------|---------|
| `HERMES_RL_AUTOWAIT` | `1` | `0` disables auto-wait entirely |
| `HERMES_RL_AUTOWAIT_MAX_S` | `21600` | fallback cap (s) when no window detected |
| `HERMES_RL_AUTOWAIT_MAX_5H_S` | `21600` | 5h-window safety cap (6h) |
| `HERMES_RL_AUTOWAIT_MAX_1D_S` | `93600` | 1d-window safety cap (26h) |
| `HERMES_RL_AUTOWAIT_MAX_7D_S` | `648000` | 7d-window safety cap (7.5d) |
| `HERMES_RL_AUTOWAIT_BUFFER_S` | `5` | pad added after reset |
| `HERMES_RL_AUTOWAIT_DEFAULT_S` | `300` | wait when no reset header found |

The wait loop also calls `agent._touch_activity(...)` every ~25s so the
gateway's inactivity watchdog doesn't kill the agent mid-wait.  Idempotent
and never breaks the billing path: if anything goes wrong, the original
call/exception behaviour is preserved.

Ported from kristianvast/hermes-claude-auth PR #27 (window-aware auto-wait);
the fingerprint parity fix below from PR #21.

## Fingerprint parity (avoids "extra usage" billing)

Anthropic's validator cross-references the `user-agent` header and the
`cc_version=` field in the billing header.  If the SDK client sends
`claude-cli/<ver> (external, cli)` while the billing header claims
`cc_entrypoint=sdk-cli`, the request is flagged as third-party and routed to
pay-per-token **extra usage** instead of your Max/Pro plan
(`HTTP 400 You're out of extra usage`).  This patch pins the Claude Code
version to `2.1.112` for **both** the user-agent and the signed billing
header, and forces `x-app: cli`, eliminating the drift that triggered
upstream issue #6.

## What gets modified
| File | Action |
|------|--------|
| `~/.hermes/patches/anthropic_billing_bypass.py` | Created |
| `<venv>/lib/pythonX.Y/site-packages/sitecustomize.py` | Created or replaced |
| hermes-agent source files | NOT modified |

## Compatibility
- Tested with hermes-agent on Python 3.11+
- Linux, macOS, and **Windows** (native: `%LOCALAPPDATA%\hermes`; the bypass
  patch lives at `%LOCALAPPDATA%\hermes\patches\anthropic_billing_bypass.py`)
- **Multiple profiles**: Hermes supports `profiles/<name>/` under the data
  root. The patch is installed once at the data root and shared by every
  profile; `HERMES_HOME` may point at a profile dir and the loader still
  resolves the patch correctly.
- Depends on `build_anthropic_kwargs(is_oauth=...)` in `agent.anthropic_adapter`, so it may need updating if hermes-agent changes that interface

## Verifying the bypass is active (not falling back to extra usage)

After install, confirm Hermes is using the subscription path and not silently
billing pay-per-token:

1. **Startup log** — look for these lines in the Hermes gateway log
   (`%LOCALAPPDATA%\hermes\logs\` on Windows):
   ```
   [anthropic_billing_bypass] Bypass installed
   [anthropic_billing_bypass] Transport unwrap hook installed
   [anthropic_billing_bypass] Rate-limit auto-wait installed
   ```
2. **No `extra usage` errors** — if you see `HTTP 400 You're out of extra
   usage` or `HTTP 429 ... extra usage required`, the fingerprint drifted and
   the request was routed to the pay-per-token bucket. Re-run `install.sh`.
3. **Token flow** — calls should succeed with `provider=anthropic` in
   `agent.log` and normal in/out token counts (not 429s).

> **Version pin note:** This build pins Claude Code `2.1.112` for the
> user-agent + signed billing header. The real Claude Code on your machine may
> be newer (e.g. `2.1.186`); the upstream project intentionally stays on
> `2.1.112` because the validator still accepts it. If Anthropic tightens the
> wire-format check, bump `_PINNED_CC_VERSION` in `anthropic_billing_bypass.py`
> and re-test. Track upstream PRs #10 (2.1.123) and #15 (2.1.117) for the
> newer wire-format parity if needed.



### Install issues
- **"hermes-agent not found"**: Make sure Hermes is installed at `~/.hermes/hermes-agent/` (Linux/macOS) or `%LOCALAPPDATA%\hermes\hermes-agent\` (Windows)
- **"No virtualenv found"**: Set `HERMES_VENV` to point to your venv
- **"ModuleNotFoundError: No module named 'anthropic_billing_bypass'"** on every startup: the `sitecustomize.py` hook couldn't find the patch. This happens when `HERMES_HOME` points at a **profile** directory (`.../hermes/profiles/<name>`) but the patch lives at the data root. This build resolves that case automatically — reinstall the hook from this repo (`install.sh`) or copy `sitecustomize_hook.py` into the venv's `site-packages/` as `sitecustomize.py`.
- **Patch not loading**: Check `journalctl --user -u hermes-gateway -n 50` (Linux) or the Hermes log under `%LOCALAPPDATA%\hermes\logs\` (Windows) for `[anthropic_billing_bypass]` or `[hermes-claude-auth]` messages

### Auth issues

- **`Anthropic 401 authentication failed`** or **`No Anthropic credentials found`**: Hermes reads Claude subscription credentials from `~/.claude/.credentials.json`. If Claude Code is authenticated (e.g. in macOS Keychain) but that file is missing or stale, Hermes fails even when Claude Code itself works.

  On macOS, `install.sh` v1.1.1+ auto-mirrors the `Claude Code-credentials` Keychain entry into `~/.claude/.credentials.json` on every run, so re-running the installer is usually enough. Full fix:

  1. Refresh Claude subscription login:
     ```bash
     claude auth login --claudeai
     ```
  2. Re-run the installer to re-mirror credentials (macOS) and reload the patch:
     ```bash
     ./install.sh
     ```
  3. Remove stale `ANTHROPIC_TOKEN` / `ANTHROPIC_API_KEY` values from `~/.hermes/.env` — they can override subscription auth.
  4. Reset cached credentials:
     ```bash
     hermes auth reset anthropic
     ```
  5. Retry with a smoke test:
     ```bash
     hermes chat -q 'Reply with exactly: AUTH TEST OK' --provider anthropic -m claude-sonnet-4-6 -Q
     ```

  If the auto-mirror doesn't work (e.g. your Keychain entry is under a different service name), mirror it manually:
  ```bash
  python3 - <<'PY'
  import subprocess
  from pathlib import Path

  secret = subprocess.check_output(
      ['security', 'find-generic-password', '-s', 'Claude Code-credentials', '-w'],
      text=True,
  ).strip()

  cred_path = Path.home() / '.claude' / '.credentials.json'
  cred_path.parent.mkdir(parents=True, exist_ok=True)
  cred_path.write_text(secret)
  cred_path.chmod(0o600)
  print(f'wrote {cred_path}')
  PY
  ```

  Credit: the macOS Keychain mirror approach was written up by [@DrQbz](https://github.com/DrQbz) in [issue #5](https://github.com/kristianvast/hermes-claude-auth/issues/5) and is now automated in `install.sh`.

### Billing / routing issues

- **HTTP 400: "Third-party apps now draw from your extra usage, not your plan limits"**: Anthropic's server-side validation has classified your requests as third-party and routed them to pay-per-token credits instead of your Max/Pro plan. Make sure you're on the latest version of this patch (it tracks the upstream [opencode-claude-auth](https://github.com/griffinmartin/opencode-claude-auth) fingerprint changes). Reinstall with `./install.sh` and restart `hermes-gateway`. If the error persists after update, the bypass is currently broken upstream too — track [issue #6](https://github.com/kristianvast/hermes-claude-auth/issues/6) for status.
- **HTTP 400 persists after update**: The billing salt or signature format may have been rotated by Anthropic again. Check for newer commits to this repo.

## Credits
- [griffinmartin/opencode-claude-auth](https://github.com/griffinmartin/opencode-claude-auth), the original TypeScript implementation for opencode (MIT)
- [NousResearch/hermes-agent](https://github.com/NousResearch/hermes-agent), the AI agent this patches (MIT)

## Disclaimer
This uses Claude Code subscription credentials outside the official Claude Code CLI. It works with Anthropic's current OAuth implementation but may break if Anthropic changes their validation. Use at your own risk.

## License
MIT, see [LICENSE](LICENSE).
