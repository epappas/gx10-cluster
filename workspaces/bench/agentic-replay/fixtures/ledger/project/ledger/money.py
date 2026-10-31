"""Parsing, formatting and validation of amounts."""

import re

from ledger.errors import InvalidAmountError

_AMOUNT = re.compile(r"(-?)(\d+)(?:\.(\d{1,2}))?")


def require_cents(value: object) -> int:
    if isinstance(value, bool) or not isinstance(value, int):
        raise InvalidAmountError(f"bad amount: {value!r}")
    return value


def parse_amount(text: str) -> int:
    """Parse decimal text such as "12.30" or "-4"."""
    if not isinstance(text, str):
        raise InvalidAmountError(f"not text: {text!r}")
    match = _AMOUNT.fullmatch(text.strip())
    if match is None:
        raise InvalidAmountError(f"bad amount: {text!r}")
    sign, whole, fraction = match.groups()
    cents = int(whole) * 100 + int((fraction or "").ljust(2, "0"))
    return -cents if sign else cents


def format_cents(cents: int) -> str:
    """Render an amount as decimal text such as "-12.30"."""
    require_cents(cents)
    whole, fraction = divmod(abs(cents), 100)
    sign = "-" if cents < 0 else ""
    return f"{sign}{whole}.{fraction:02d}"
