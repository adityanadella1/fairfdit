"""Resume and retry logic for checkpoint downloads.

Worth testing despite being a setup script: these are 400 MB transfers
over public CDNs, the failure mode is a *silently corrupt* file rather
than an error, and the corruption only surfaces much later as an
unhelpful deserialisation failure at model-load time.

The real failure this covers actually happened — a LaMa download died at
6.8% with "retrieval incomplete", and the original implementation had no
way to resume it.
"""

from __future__ import annotations

import importlib.util
import sys
import urllib.error
from pathlib import Path

import pytest

BACKEND_ROOT = Path(__file__).resolve().parent.parent


def _load_script():
    """Loads the script by path — it lives in scripts/, not in the app
    package, so there is nothing importable to reach for."""
    spec = importlib.util.spec_from_file_location(
        "download_weights", BACKEND_ROOT / "scripts" / "download_weights.py"
    )
    module = importlib.util.module_from_spec(spec)
    sys.modules["download_weights"] = module
    spec.loader.exec_module(module)
    return module


dw = _load_script()

PAYLOAD = bytes(range(256)) * 40  # 10240 bytes


class FakeResponse:
    """Minimal stand-in for the object urlopen returns."""

    def __init__(self, body: bytes, status: int = 200, *, truncate_at: int | None = None):
        self._body = body
        self.status = status
        self.headers = {"Content-Length": str(len(body))}
        self._pos = 0
        self._truncate_at = truncate_at

    def read(self, size: int) -> bytes:
        if self._truncate_at is not None and self._pos >= self._truncate_at:
            raise urllib.error.URLError("connection reset")
        chunk = self._body[self._pos : self._pos + size]
        self._pos += len(chunk)
        return chunk

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


@pytest.fixture(autouse=True)
def no_sleep(monkeypatch):
    """Retry backoff is real seconds; the tests do not need to wait."""
    monkeypatch.setattr(dw.time, "sleep", lambda _: None)


class TestResume:
    def test_downloads_a_whole_file(self, tmp_path, monkeypatch):
        monkeypatch.setattr(
            dw.urllib.request, "urlopen", lambda req, timeout=None: FakeResponse(PAYLOAD)
        )
        target = tmp_path / "f.bin.part"
        dw._fetch_with_resume("http://x/f.bin", target, 1)
        assert target.read_bytes() == PAYLOAD

    def test_resumes_from_a_partial_file(self, tmp_path, monkeypatch):
        """The whole point: a second attempt must carry only the
        remainder and append it, not restart."""
        target = tmp_path / "f.bin.part"
        target.write_bytes(PAYLOAD[:4000])

        seen: dict[str, str] = {}

        def fake_urlopen(req, timeout=None):
            seen["range"] = req.get_header("Range")
            # 206 Partial Content with only the tail.
            return FakeResponse(PAYLOAD[4000:], status=206)

        monkeypatch.setattr(dw.urllib.request, "urlopen", fake_urlopen)
        dw._fetch_with_resume("http://x/f.bin", target, 1)

        assert seen["range"] == "bytes=4000-"
        assert target.read_bytes() == PAYLOAD

    def test_restarts_when_the_server_ignores_range(self, tmp_path, monkeypatch):
        """A server answering 200 to a Range request is sending the whole
        file. Appending it to what we already have would silently produce
        a corrupt, oversized checkpoint."""
        target = tmp_path / "f.bin.part"
        target.write_bytes(PAYLOAD[:4000])

        monkeypatch.setattr(
            dw.urllib.request,
            "urlopen",
            lambda req, timeout=None: FakeResponse(PAYLOAD, status=200),
        )
        dw._fetch_with_resume("http://x/f.bin", target, 1)

        assert target.read_bytes() == PAYLOAD, "partial bytes were not discarded"

    def test_retries_a_dropped_connection(self, tmp_path, monkeypatch):
        """First attempt dies mid-stream; the second resumes and
        finishes — the exact shape of the real failure."""
        attempts = {"n": 0}

        def fake_urlopen(req, timeout=None):
            attempts["n"] += 1
            if attempts["n"] == 1:
                return FakeResponse(PAYLOAD, truncate_at=3000)
            start = int(req.get_header("Range").removeprefix("bytes=").rstrip("-"))
            return FakeResponse(PAYLOAD[start:], status=206)

        monkeypatch.setattr(dw.urllib.request, "urlopen", fake_urlopen)
        target = tmp_path / "f.bin.part"
        dw._fetch_with_resume("http://x/f.bin", target, 1)

        assert attempts["n"] == 2
        assert target.read_bytes() == PAYLOAD

    def test_a_clean_mid_stream_drop_is_not_mistaken_for_success(
        self, tmp_path, monkeypatch
    ):
        """A connection that ends cleanly part-way through returns b""
        with no exception — indistinguishable from a finished transfer
        unless the byte count is checked.

        Missing this check is what promoted a truncated 364 MB download
        to the target file, where it resurfaced as "not a zip file".
        """
        attempts = {"n": 0}

        def fake_urlopen(req, timeout=None):
            attempts["n"] += 1
            if attempts["n"] == 1:
                # Claims the full length, delivers half, then EOFs quietly.
                response = FakeResponse(PAYLOAD[: len(PAYLOAD) // 2])
                response.headers = {"Content-Length": str(len(PAYLOAD))}
                return response
            start = int(req.get_header("Range").removeprefix("bytes=").rstrip("-"))
            return FakeResponse(PAYLOAD[start:], status=206)

        monkeypatch.setattr(dw.urllib.request, "urlopen", fake_urlopen)
        target = tmp_path / "f.bin.part"
        dw._fetch_with_resume("http://x/f.bin", target, 1)

        assert attempts["n"] == 2, "short read was accepted as complete"
        assert target.read_bytes() == PAYLOAD

    def test_gives_up_after_max_attempts(self, tmp_path, monkeypatch):
        def always_fail(req, timeout=None):
            raise urllib.error.URLError("nope")

        monkeypatch.setattr(dw.urllib.request, "urlopen", always_fail)
        target = tmp_path / "f.bin.part"

        with pytest.raises(RuntimeError, match="gave up after"):
            dw._fetch_with_resume("http://x/f.bin", target, 1)

    def test_partial_file_survives_failure(self, tmp_path, monkeypatch):
        """The .part file is what the next run resumes from, so a failed
        attempt must leave it in place rather than clean it up."""
        calls = {"n": 0}

        def fake_urlopen(req, timeout=None):
            calls["n"] += 1
            return FakeResponse(PAYLOAD, truncate_at=2000)

        monkeypatch.setattr(dw.urllib.request, "urlopen", fake_urlopen)
        target = tmp_path / "f.bin.part"

        with pytest.raises(RuntimeError):
            dw._fetch_with_resume("http://x/f.bin", target, 1)

        assert target.exists()
        assert target.stat().st_size > 0


class TestProgressOutput:
    """A carriage-return progress bar piped to a file becomes tens of
    thousands of lines. One download produced 90 KB of log this way
    before the TTY check existed."""

    def test_silent_while_downloading_when_not_a_tty(self, monkeypatch, capsys):
        monkeypatch.setattr(dw, "INTERACTIVE", False)
        for done in range(0, 10_000, 1000):
            dw._report(done, 10_000)
        assert capsys.readouterr().out == ""

    def test_animates_when_attached_to_a_tty(self, monkeypatch, capsys):
        monkeypatch.setattr(dw, "INTERACTIVE", True)
        dw._report(5_000, 10_000)
        out = capsys.readouterr().out
        assert out.startswith("\r")
        assert "50.0%" in out

    def test_zero_length_response_does_not_divide_by_zero(self, capsys):
        dw._report(0, 0)
        assert capsys.readouterr().out == ""
