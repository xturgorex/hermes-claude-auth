"""Behavioural test for the 1.6.0 headerless-429 bail-out.

Exercises the REAL _rl_sleep_until_reset with the REAL clock; the waits are
made short via the module's own env knobs rather than by faking time, so the
test measures the shipped code path rather than a stubbed one.

Verifies:
  1. a headerless 429 (third-party detection signature) bails after N attempts
  2. a 429 WITH reset headers (real quota) still waits and retries every time
"""
import os
import sys
import time
import types

# Shrink the real waits *before* the module reads them (they are read per call
# via _rl_env_int, so this is honoured at runtime).
os.environ["HERMES_RL_AUTOWAIT_DEFAULT_S"] = "1"
os.environ["HERMES_RL_AUTOWAIT_BUFFER_S"] = "0"
os.environ["HERMES_RL_AUTOWAIT_HEADERLESS_ATTEMPTS"] = "2"

sys.path.insert(0, "/opt/hermes-claude-auth")
import anthropic_billing_bypass as bp  # noqa: E402

print("bypass version:", bp.__version__)

EMITTED = []
bp._rl_emit = lambda agent, msg: EMITTED.append(msg)
bp._rl_touch = lambda agent, desc: None
bp._rl_interrupted = lambda agent: False


class FakeResponse:
    def __init__(self, headers):
        self.headers = headers
        self.status_code = 429


class Fake429(Exception):
    """Mimics anthropic.RateLimitError enough for the header parser."""

    def __init__(self, headers, body):
        super().__init__(f"Error code: 429 - {body}")
        self.status_code = 429
        self.response = FakeResponse(headers)
        self.body = body


agent = types.SimpleNamespace()


def run(exc, attempt):
    EMITTED.clear()
    t0 = time.time()
    r = bp._rl_sleep_until_reset(agent, exc, attempt)
    return r, time.time() - t0, (EMITTED[-1][:62] if EMITTED else "")


# ── Case 1: DETECTION 429 — no reset headers at all ───────────────────
detect = Fake429(
    headers={},
    body={"type": "error",
          "error": {"type": "rate_limit_error", "message": "Error"}},
)
print("\n=== Case 1: headerless 429 (third-party detection signature) ===")
results = []
for attempt in range(1, 6):
    r, dt, msg = run(detect, attempt)
    results.append(r)
    print(f"  attempt {attempt}: retry={str(r):<5} waited={dt:>5.1f}s  {msg}")

assert results[:2] == [True, True], f"first 2 attempts should wait, got {results[:2]}"
assert all(x is False for x in results[2:]), f"attempt>2 must bail, got {results[2:]}"
print("  -> PASS: bails after 2 headerless attempts (was: infinite loop)")

# ── Case 2: REAL quota 429 — reset headers present ────────────────────
print("\n=== Case 2: 429 WITH reset headers (real quota) ===")
qres = []
for attempt in range(1, 6):
    quota = Fake429(
        headers={
            "anthropic-ratelimit-unified-5h-status": "throttled",
            # 2s in the future, refreshed each attempt against the real clock
            "anthropic-ratelimit-unified-5h-reset": str(int(time.time()) + 2),
        },
        body={"type": "error",
              "error": {"type": "rate_limit_error", "message": "quota"}},
    )
    r, dt, msg = run(quota, attempt)
    qres.append(r)
    print(f"  attempt {attempt}: retry={str(r):<5} waited={dt:>5.1f}s  {msg}")

assert all(x is True for x in qres), f"real quota must keep waiting, got {qres}"
print("  -> PASS: real quota 429 unaffected, waits and retries on every attempt")

print("\nALL ASSERTIONS PASSED")
