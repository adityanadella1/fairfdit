"""Logging setup.

Plain text for a terminal, single-line JSON when `FAIREDIT_LOG_JSON=true`
so a log aggregator can index the fields instead of regex-matching them.
"""

from __future__ import annotations

import json
import logging
import sys
from datetime import datetime, timezone


class JsonFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        payload = {
            "ts": datetime.fromtimestamp(
                record.created, tz=timezone.utc
            ).isoformat(),
            "level": record.levelname,
            "logger": record.name,
            "message": record.getMessage(),
        }
        if record.exc_info:
            payload["exception"] = self.formatException(record.exc_info)
        return json.dumps(payload)


def configure_logging(level: str = "INFO", as_json: bool = False) -> None:
    handler = logging.StreamHandler(sys.stdout)
    handler.setFormatter(
        JsonFormatter()
        if as_json
        else logging.Formatter(
            "%(asctime)s %(levelname)-7s %(name)-28s %(message)s",
            datefmt="%H:%M:%S",
        )
    )

    root = logging.getLogger()
    # Replace rather than add: uvicorn installs its own handlers, and
    # leaving them attached double-prints every line.
    root.handlers.clear()
    root.addHandler(handler)
    root.setLevel(level.upper())

    # These three are extremely chatty at INFO and say nothing an operator
    # of this service needs.
    for noisy in ("PIL", "urllib3", "matplotlib", "hydra"):
        logging.getLogger(noisy).setLevel(logging.WARNING)

    # Access logs duplicate our own per-request timing lines.
    logging.getLogger("uvicorn.access").setLevel(logging.WARNING)
