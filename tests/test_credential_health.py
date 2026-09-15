"""Decision-table and output-contract tests for credential_health.py.

The output contract is what the no-agent cron depends on: empty stdout is a
silent tick, and only a state a human must clear may print. An expired but
refreshable record must stay silent, or every host cries wolf daily.
"""

import importlib.util
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
_spec = importlib.util.spec_from_file_location("credential_health", REPO / "credential_health.py")
assert _spec is not None and _spec.loader is not None
ch = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(ch)

FUTURE = 4_102_444_800_000  # 2100-01-01, ms
PAST = 1_000_000_000_000  # 2001-09-09, ms
RT_FUTURE = 4_102_444_800_000


class FakeAdapter:
    """Mimics agent.anthropic_adapter's credential surface."""

    def __init__(self, creds, refresh_result=None, refreshed_creds=None):
        self.creds = creds
        self.refresh_result = refresh_result
        self.refreshed_creds = refreshed_creds
        self.refresh_calls = 0

    def read_claude_code_credentials(self):
        if self.refresh_calls and self.refreshed_creds is not None:
            return self.refreshed_creds
        return self.creds

    def is_claude_code_token_valid(self, creds):
        if not creds or not creds.get("accessToken"):
            return False
        return int(creds.get("expiresAt") or 0) > PAST + 1

    def _resolve_claude_code_token_from_credentials(self, creds):
        self.refresh_calls += 1
        return self.refresh_result


def _run(monkeypatch, capsys, tmp_path, adapter, mode):
    monkeypatch.setattr(ch, "_load_adapter", lambda: adapter)
    monkeypatch.setattr(ch, "_raw_refresh_expiry", lambda: RT_FUTURE)
    hist = tmp_path / "history.txt"
    monkeypatch.setattr(
        "sys.argv", ["credential_health.py", "--mode", mode, "--history", str(hist)]
    )
    rc = ch.main()
    return rc, capsys.readouterr().out, hist


def test_healthy_verify_is_silent(monkeypatch, capsys, tmp_path):
    adapter = FakeAdapter({"accessToken": "t", "refreshToken": "r", "expiresAt": FUTURE})
    rc, out, hist = _run(monkeypatch, capsys, tmp_path, adapter, "verify")
    assert rc == 0
    assert out == "", "a healthy credential must produce a silent tick"
    assert "result=valid" in hist.read_text()
    assert adapter.refresh_calls == 0


def test_refresh_mode_refreshes_and_stays_silent(monkeypatch, capsys, tmp_path):
    expired = {"accessToken": "old", "refreshToken": "r", "expiresAt": PAST}
    fresh = {"accessToken": "new", "refreshToken": "r2", "expiresAt": FUTURE}
    adapter = FakeAdapter(expired, refresh_result="new", refreshed_creds=fresh)
    rc, out, hist = _run(monkeypatch, capsys, tmp_path, adapter, "refresh")
    assert rc == 0
    assert out == "", "a successful refresh is a routine event, not a message"
    assert "result=refreshed" in hist.read_text()
    assert adapter.refresh_calls == 1


def test_refresh_failure_is_reported_once(monkeypatch, capsys, tmp_path):
    expired = {"accessToken": "old", "refreshToken": "r", "expiresAt": PAST}
    adapter = FakeAdapter(expired, refresh_result=None, refreshed_creds=expired)
    rc, out, hist = _run(monkeypatch, capsys, tmp_path, adapter, "refresh")
    assert rc == 0, "a dead refresh token is a human step, not a script error"
    assert out.count("\n") <= 1 and "refresh FAILED" in out
    assert "claude auth login --claudeai" in out
    assert "result=refresh-failed" in hist.read_text()


def test_no_refresh_token_is_reported(monkeypatch, capsys, tmp_path):
    adapter = FakeAdapter({"accessToken": "", "refreshToken": "", "expiresAt": 0})
    rc, out, hist = _run(monkeypatch, capsys, tmp_path, adapter, "refresh")
    assert rc == 0
    assert "no usable Claude credential" in out
    assert "claude auth login --claudeai" in out


def test_verify_mode_does_not_cry_wolf_on_expired_but_refreshable(monkeypatch, capsys, tmp_path):
    """macOS: an expired record with a refresh token is normal — stay silent."""
    adapter = FakeAdapter({"accessToken": "old", "refreshToken": "r", "expiresAt": PAST})
    rc, out, hist = _run(monkeypatch, capsys, tmp_path, adapter, "verify")
    assert rc == 0
    assert out == "", "verify mode must never refresh and must not alarm on refreshable creds"
    assert adapter.refresh_calls == 0
    assert "result=expired" in hist.read_text()


def test_verify_mode_reports_truly_dead_credential(monkeypatch, capsys, tmp_path):
    adapter = FakeAdapter({"accessToken": "", "refreshToken": "", "expiresAt": 0})
    rc, out, hist = _run(monkeypatch, capsys, tmp_path, adapter, "verify")
    assert rc == 0
    assert "no usable Claude credential" in out


def test_history_records_both_clocks(monkeypatch, capsys, tmp_path):
    """The refresh-token clock is the autonomy runway; it must be recorded."""
    adapter = FakeAdapter({"accessToken": "t", "refreshToken": "r", "expiresAt": FUTURE})
    _rc, _out, hist = _run(monkeypatch, capsys, tmp_path, adapter, "verify")
    line = hist.read_text().strip()
    assert "access_exp=" in line and "refresh_exp=" in line and "refresh_exp=none" not in line