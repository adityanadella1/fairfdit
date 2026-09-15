#!/usr/bin/env python
"""Fetch model checkpoints.

Separate from `fetch_vendor.py` because code and weights have different
lifecycles: code is baked into the container image, weights are ~4 GB and
belong on a mounted volume that survives a redeploy.

    python scripts/download_weights.py                 # all
    python scripts/download_weights.py --only lama     # one
    python scripts/download_weights.py --list          # sizes, no download
"""

from __future__ import annotations

import argparse
import logging
import shutil
import sys
import time
import urllib.error
import urllib.request
import zipfile
from dataclasses import dataclass
from pathlib import Path

BACKEND_ROOT = Path(__file__).resolve().parent.parent
WEIGHTS_DIR = BACKEND_ROOT / "weights"

log = logging.getLogger("download_weights")


@dataclass(slots=True)
class Checkpoint:
    name: str
    url: str
    filename: str
    approx_mb: int
    #: Unpack a zip and keep this directory from inside it.
    extract_dir: str | None = None
    notes: str = ""


CHECKPOINTS: dict[str, Checkpoint] = {
    "sam2": Checkpoint(
        name="sam2",
        url=(
            "https://dl.fbaipublicfiles.com/segment_anything_2/092824/"
            "sam2.1_hiera_large.pt"
        ),
        filename="sam2.1_hiera_large.pt",
        approx_mb=900,
        notes=(
            "Optional — the engine falls back to the Hugging Face id in "
            "settings, which downloads on first use. Pull it here when the "
            "container must run without network access at runtime."
        ),
    ),
    "groundingdino": Checkpoint(
        name="groundingdino",
        url=(
            "https://github.com/IDEA-Research/GroundingDINO/releases/download/"
            "v0.1.0-alpha/groundingdino_swint_ogc.pth"
        ),
        filename="groundingdino_swint_ogc.pth",
        approx_mb=690,
        notes="Swin-T backbone. Required for person, object and sky selection.",
    ),
    "lama": Checkpoint(
        name="lama",
        url="https://huggingface.co/smartywu/big-lama/resolve/main/big-lama.zip",
        filename="big-lama.zip",
        approx_mb=400,
        extract_dir="big-lama",
        notes="Required for AI Remove. Unzips to weights/big-lama/.",
    ),
}


#: Retries per file. These are hundreds of megabytes from public CDNs;
#: a dropped connection partway through is routine, not exceptional.
MAX_ATTEMPTS = 5

#: Bytes per read. Large enough that progress accounting is not the
#: bottleneck, small enough to stay responsive to a stall.
CHUNK = 1 << 16

#: Only animate progress when someone is watching. Piped to a file or a
#: CI log, a carriage-return progress bar becomes tens of thousands of
#: lines — one download produced 90 KB of log before this check existed.
INTERACTIVE = sys.stdout.isatty()


def _report(done: int, total: int, *, final: bool = False) -> None:
    if total <= 0:
        return
    percent = done / total * 100
    line = f"  {percent:5.1f}%  {done / 1024**2:7.1f} / {total / 1024**2:.1f} MB"
    if INTERACTIVE:
        print("\r" + line, end="\n" if final else "", flush=True)
    elif final:
        log.info(line.strip())


def _fetch_with_resume(url: str, partial: Path, expected_mb: int) -> None:
    """Downloads [url] to [partial], resuming and retrying as needed.

    Resume is the point. Without it, a drop at 90% of a 364 MB file means
    starting over, and on a connection flaky enough to drop once the
    restart is likely to drop again — the download never completes at
    all. With a Range request each attempt only has to carry the
    remainder.
    """
    for attempt in range(1, MAX_ATTEMPTS + 1):
        have = partial.stat().st_size if partial.exists() else 0
        request = urllib.request.Request(url)
        if have:
            request.add_header("Range", f"bytes={have}-")

        try:
            with urllib.request.urlopen(request, timeout=60) as response:
                # A server that ignores our Range header answers 200 with
                # the whole file; appending to what we already have would
                # silently corrupt it, so start clean in that case.
                resuming = response.status == 206
                if have and not resuming:
                    log.warning("    server ignored resume; restarting")
                    have = 0

                total = int(response.headers.get("Content-Length", 0)) + have
                mode = "ab" if resuming and have else "wb"
                with open(partial, mode) as handle:
                    while chunk := response.read(CHUNK):
                        handle.write(chunk)
                        have += len(chunk)
                        _report(have, total)

            # A connection that drops cleanly mid-stream makes read()
            # return b"" with no exception, which is indistinguishable
            # from a finished transfer unless the byte count is checked.
            # Skipping this check promotes a truncated file to the target
            # and the failure resurfaces much later as "not a zip file" —
            # or worse, as a corrupt checkpoint that loads and misbehaves.
            if total and have < total:
                raise urllib.error.URLError(
                    f"incomplete: got {have} of {total} bytes"
                )

            _report(have, total, final=True)
            return

        except (urllib.error.URLError, TimeoutError, OSError) as exc:
            got = partial.stat().st_size if partial.exists() else 0
            if attempt == MAX_ATTEMPTS:
                raise RuntimeError(
                    f"gave up after {MAX_ATTEMPTS} attempts "
                    f"({got / 1024**2:.1f} MB of ~{expected_mb} MB): {exc}"
                ) from exc
            backoff = min(2**attempt, 20)
            log.warning(
                "    attempt %d/%d failed at %.1f MB (%s); retrying in %ds",
                attempt,
                MAX_ATTEMPTS,
                got / 1024**2,
                exc,
                backoff,
            )
            time.sleep(backoff)


def download(checkpoint: Checkpoint, *, force: bool) -> None:
    WEIGHTS_DIR.mkdir(parents=True, exist_ok=True)
    target = WEIGHTS_DIR / checkpoint.filename

    final = (
        WEIGHTS_DIR / checkpoint.extract_dir if checkpoint.extract_dir else target
    )
    if final.exists() and not force:
        log.info("%-14s already present at %s", checkpoint.name, final)
        return

    log.info("%-14s downloading ~%d MB", checkpoint.name, checkpoint.approx_mb)
    # Download beside the target and rename only on success, so an
    # interrupted run never leaves a truncated checkpoint that loads and
    # then fails with an unhelpful deserialisation error. The .part file
    # is deliberately *kept* on failure — that is what the next run
    # resumes from.
    partial = target.with_suffix(target.suffix + ".part")
    _fetch_with_resume(checkpoint.url, partial, checkpoint.approx_mb)
    partial.replace(target)

    if checkpoint.extract_dir:
        log.info("%-14s extracting", checkpoint.name)
        destination = WEIGHTS_DIR / checkpoint.extract_dir
        if destination.exists():
            shutil.rmtree(destination)
        try:
            with zipfile.ZipFile(target) as archive:
                archive.extractall(WEIGHTS_DIR)
        except zipfile.BadZipFile as exc:
            # A truncated transfer that still passed the length check
            # lands here. Remove it so the next run re-downloads rather
            # than resuming into a file that will never open.
            target.unlink(missing_ok=True)
            raise RuntimeError(f"archive is corrupt, re-run to retry: {exc}") from exc
        target.unlink(missing_ok=True)

        if not destination.exists():
            raise RuntimeError(
                f"archive did not contain the expected '{checkpoint.extract_dir}/' "
                "directory — upstream may have changed its layout"
            )

    log.info("%-14s ready", checkpoint.name)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--only", choices=sorted(CHECKPOINTS), action="append",
        help="Download only these (repeatable).",
    )
    parser.add_argument(
        "--force", action="store_true", help="Re-download even if present."
    )
    parser.add_argument(
        "--list", action="store_true", help="Show what would be downloaded."
    )
    args = parser.parse_args()

    logging.basicConfig(level=logging.INFO, format="%(message)s")

    selected = args.only or list(CHECKPOINTS)

    if args.list:
        total = sum(CHECKPOINTS[n].approx_mb for n in selected)
        for name in selected:
            checkpoint = CHECKPOINTS[name]
            log.info("%-14s ~%4d MB  %s", name, checkpoint.approx_mb, checkpoint.notes)
        log.info("%-14s ~%4d MB total", "", total)
        return 0

    for name in selected:
        try:
            download(CHECKPOINTS[name], force=args.force)
        except Exception as exc:  # noqa: BLE001 - reported, not swallowed
            log.error("%s failed: %s", name, exc)
            return 1

    log.info("")
    log.info("Weights in %s", WEIGHTS_DIR)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
