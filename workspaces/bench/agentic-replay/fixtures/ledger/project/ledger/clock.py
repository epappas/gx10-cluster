"""Time source used by a Ledger."""

from collections.abc import Callable
from datetime import datetime, timezone

Clock = Callable[[], datetime]


def system_clock() -> datetime:
    return datetime.now(timezone.utc)
